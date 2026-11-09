// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../l10n/l10n.dart';
import 'iso_run.dart';
import '../model/lines.dart';
import '../model/mesh.dart';
import '../model/vector_info.dart';
import 'aci_colors.dart';

/// Resultado transportable entre isolates.
class DxfData {
  DxfData(
    this.name,
    Float32List verts,
    this.layers,
    this.min,
    this.max,
    this.texts, [
    this.insUnits = 0,
    this.truncated = false,
  ]) : _data = TransferableTypedData.fromList([verts]);
  final String name;
  final TransferableTypedData _data;
  final List<(String, int, int)>
  layers; // nombre, primer vértice, nº de vértices
  final List<double> min, max;
  final List<DrawingText> texts;

  /// Valor de `$INSUNITS` del archivo (0 = sin unidad).
  final int insUnits;

  /// El archivo termina antes de su marca final (EOF): descarga cortada o copia incompleta.
  final bool truncated;

  /// Datos propios de SVG y HPGL (origen, avisos, plumas…).
  VectorInfo? info;

  (LineSet, List<DrawingText>) build() {
    final v = _data.materialize().asFloat32List();
    return (
      LineSet(
        vertices: v,
        bounds: Bounds(min, max),
        groups: [
          for (final l in layers)
            LineGroup(l.$1, l.$2, l.$3, visible: !isTravelLayerName(l.$1)),
        ],
      ),
      texts,
    );
  }
}

/// ¿Es la capa de viajes en vacío (pluma arriba) de un HPGL? Se reconoce por el nombre en cualquier idioma.
bool isTravelLayerName(String n) => n.startsWith('Viajes') || n.startsWith(tr('Viajes (pluma arriba)'));

Future<DxfData> loadDxf(String path) => isoRun(() => parseDxf(path));

class _Pair {
  _Pair(this.code, this.value);
  final int code;
  final String value;
  double get d => double.tryParse(value.trim()) ?? 0;
  int get i => int.tryParse(value.trim()) ?? 0;
}

class _Entity {
  _Entity(this.type);
  final String type;
  final List<_Pair> data = [];
  final List<_Entity> children = []; // VERTEX de un POLYLINE
  double? first(int code) {
    for (final p in data) {
      if (p.code == code) return p.d;
    }
    return null;
  }

  int? firstInt(int code) {
    for (final p in data) {
      if (p.code == code) return p.i;
    }
    return null;
  }

  String? firstStr(int code) {
    for (final p in data) {
      if (p.code == code) return p.value.trim();
    }
    return null;
  }
}

class _Block {
  _Block(this.name);
  final String name;
  double bx = 0, by = 0;
  final List<_Entity> entities = [];
}

class _Layer {
  _Layer(this.name, this.color, this.hidden);
  final String name;
  final int color;
  final bool hidden;
}

/// Matriz afín 2D: x' = a x + c y + e ; y' = b x + d y + f
class _M {
  const _M(this.a, this.b, this.c, this.d, this.e, this.f);
  static const identity = _M(1, 0, 0, 1, 0, 0);
  final double a, b, c, d, e, f;
  _M mul(_M o) => _M(
    a * o.a + c * o.b,
    b * o.a + d * o.b,
    a * o.c + c * o.d,
    b * o.c + d * o.d,
    a * o.e + c * o.f + e,
    b * o.e + d * o.f + f,
  );
  double tx(double x, double y) => a * x + c * y + e;
  double ty(double x, double y) => b * x + d * y + f;
  double get scale => math.sqrt((a * a + b * b + c * c + d * d) / 2);
}

class _Builder {
  final Map<String, List<double>> perLayer = {};
  final List<DrawingText> texts = [];
  double tol = 0.01;

  void segment(
    String layer,
    int rgb,
    double x0,
    double y0,
    double x1,
    double y1,
  ) {
    final l = perLayer.putIfAbsent(layer, () => <double>[]);
    // Sobre fondo oscuro, los colores oscuros (azul ACI 5, rojo puro) se aclaran para que se lean.
    var r = ((rgb >> 16) & 255).toDouble();
    var g = ((rgb >> 8) & 255).toDouble();
    var b = (rgb & 255).toDouble();
    final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    final lift = ((140 - lum) / 140).clamp(0.0, 1.0) * 0.7;
    r += (255 - r) * lift;
    g += (255 - g) * lift;
    b += (255 - b) * lift;
    l.addAll([
      x0,
      y0,
      0,
      r / 255,
      g / 255,
      b / 255,
      x1,
      y1,
      0,
      r / 255,
      g / 255,
      b / 255,
    ]);
  }

  void polyline(
    String layer,
    int rgb,
    List<double> pts, {
    bool closed = false,
  }) {
    final n = pts.length ~/ 2;
    for (var i = 0; i + 1 < n; i++) {
      segment(
        layer,
        rgb,
        pts[i * 2],
        pts[i * 2 + 1],
        pts[i * 2 + 2],
        pts[i * 2 + 3],
      );
    }
    if (closed && n > 2)
      segment(
        layer,
        rgb,
        pts[(n - 1) * 2],
        pts[(n - 1) * 2 + 1],
        pts[0],
        pts[1],
      );
  }
}

int _segmentsFor(double radius, double sweep, double tol) {
  if (radius <= 0) return 4;
  final step = 2 * math.acos((1 - tol / radius).clamp(-1.0, 1.0));
  if (step.isNaN || step <= 0) return 64;
  return (sweep.abs() / step).ceil().clamp(4, 720);
}

DxfData parseDxf(String path) =>
    parseDxfBytes(File(path).readAsBytesSync(), path.split('/').last);

DxfData parseDxfBytes(Uint8List bytes, String fileName) {
  // R12 (AC1009) y anteriores: ANSI. R2007+ (AC1021+): UTF-8.
  final head = latin1.decode(bytes.sublist(0, math.min(4000, bytes.length)));
  final isOld =
      head.contains('AC1009') ||
      head.contains('AC1006') ||
      head.contains('AC1012') ||
      head.contains('AC1014');
  if (bytes.isEmpty) throw Exception(tr('El archivo está vacío.'));
  final binary = head.startsWith('AutoCAD Binary DXF');
  // Un fragmento de entidades sin secciones (p. ej. copiado de un editor) también se abre.
  final fragment = RegExp(
    r'^\s*0\s*\n\s*(ENTITIES|LINE|LWPOLYLINE|POLYLINE|CIRCLE|ARC|SPLINE|ELLIPSE)\b',
    multiLine: true,
  ).hasMatch(head);
  if (!binary && !head.contains('SECTION') && !fragment) {
    throw Exception(
      '${tr('Este archivo no parece un DXF (no tiene secciones).')} '
      '${tr('Comprueba que no sea otro formato con la extensión cambiada.')}',
    );
  }
  final List<_Pair> pairs;
  if (binary) {
    pairs = _binaryPairs(bytes);
  } else {
    final text = isOld
        ? latin1.decode(bytes)
        : utf8.decode(bytes, allowMalformed: true);
    final lines = const LineSplitter().convert(text);
    pairs = <_Pair>[];
    for (var i = 0; i + 1 < lines.length; i += 2) {
      final c = int.tryParse(lines[i].trim());
      if (c == null) {
        i -= 1; // desalineado: reintenta una línea después
        continue;
      }
      pairs.add(_Pair(c, lines[i + 1]));
    }
  }

  final layers = <String, _Layer>{};
  final blocks = <String, _Block>{};
  final modelEntities = <_Entity>[];
  var insUnits = 0;

  var i = 0;
  String? section = fragment ? 'ENTITIES' : null;
  _Block? curBlock;
  _Entity? polyline; // POLYLINE abierto esperando VERTEX/SEQEND
  _Entity? cur;
  String? tableName;

  void flush(List<_Entity> into) {
    if (cur == null) return;
    final e = cur!;
    cur = null;
    if (e.type == 'POLYLINE') {
      polyline = e;
      into.add(e);
    } else if (e.type == 'VERTEX' && polyline != null) {
      polyline!.children.add(e);
    } else if (e.type == 'SEQEND') {
      polyline = null;
    } else {
      into.add(e);
    }
  }

  while (i < pairs.length) {
    final p = pairs[i];
    if (p.code == 0) {
      final v = p.value.trim();
      if (v == 'SECTION') {
        i++;
        if (i < pairs.length && pairs[i].code == 2)
          section = pairs[i].value.trim();
        i++;
        continue;
      }
      if (v == 'ENDSEC') {
        if (section == 'ENTITIES') flush(modelEntities);
        if (section == 'BLOCKS' && curBlock != null) {
          flush(curBlock!.entities);
          curBlock = null;
        }
        section = null;
        i++;
        continue;
      }
      if (section == 'TABLES') {
        if (v == 'TABLE') {
          i++;
          if (i < pairs.length && pairs[i].code == 2)
            tableName = pairs[i].value.trim();
          continue;
        }
        if (v == 'LAYER') {
          String name = '0';
          var color = 7, flags = 0;
          i++;
          while (i < pairs.length && pairs[i].code != 0) {
            final q = pairs[i];
            if (q.code == 2) name = q.value.trim();
            if (q.code == 62) color = q.i;
            if (q.code == 70) flags = q.i;
            i++;
          }
          layers[name] = _Layer(
            name,
            color.abs(),
            color < 0 || (flags & 1) != 0,
          );
          continue;
        }
        i++;
        continue;
      }
      if (section == 'BLOCKS') {
        if (v == 'BLOCK') {
          if (curBlock != null) flush(curBlock!.entities);
          final b = _Block('');
          i++;
          while (i < pairs.length && pairs[i].code != 0) {
            final q = pairs[i];
            if (q.code == 2 && b.name.isEmpty) {
              curBlock = _Block(q.value.trim());
              curBlock!
                ..bx = 0
                ..by = 0;
            }
            if (q.code == 10 && curBlock != null) curBlock!.bx = q.d;
            if (q.code == 20 && curBlock != null) curBlock!.by = q.d;
            i++;
          }
          if (curBlock != null) blocks[curBlock!.name] = curBlock!;
          polyline = null;
          continue;
        }
        if (v == 'ENDBLK') {
          if (curBlock != null) flush(curBlock!.entities);
          curBlock = null;
          i++;
          continue;
        }
        if (curBlock != null) {
          flush(curBlock!.entities);
          cur = _Entity(v);
        }
        i++;
        continue;
      }
      if (section == 'ENTITIES') {
        flush(modelEntities);
        cur = _Entity(v);
        i++;
        continue;
      }
      i++;
      continue;
    }
    if (section == 'HEADER') {
      if (p.code == 9 && p.value.trim() == r'$INSUNITS' && i + 1 < pairs.length)
        insUnits = pairs[i + 1].i;
      i++;
      continue;
    }
    if ((section == 'ENTITIES' || section == 'BLOCKS') && cur != null)
      cur!.data.add(p);
    i++;
  }
  tableName; // sin uso: solo para legibilidad del recorrido

  // ---------- Generación de geometría ----------
  final b = _Builder();
  // Tolerancia de teselado: relativa al tamaño del dibujo (se afina tras una primera pasada barata).
  var mnx = double.infinity,
      mny = double.infinity,
      mxx = -double.infinity,
      mxy = -double.infinity;
  void scanBounds(List<_Entity> es) {
    for (final e in es) {
      for (final q in e.data) {
        if (q.code == 10 || q.code == 11) {
          // x
        }
      }
      final x = e.first(10), y = e.first(20);
      if (x != null && y != null && e.type != 'INSERT') {
        mnx = math.min(mnx, x);
        mxx = math.max(mxx, x);
        mny = math.min(mny, y);
        mxy = math.max(mxy, y);
      }
    }
  }

  scanBounds(modelEntities);
  final diag = mnx.isInfinite
      ? 1000.0
      : math.sqrt(math.pow(mxx - mnx, 2) + math.pow(mxy - mny, 2));
  b.tol = math.max(diag * 1e-4, 1e-6);

  int colorOf(_Entity e, String layerName, int blockColor) {
    final tc = e.firstInt(420);
    if (tc != null) return tc & 0xFFFFFF;
    var c = e.firstInt(62);
    if (c == null || c == 256) {
      final l = layers[layerName];
      return aciColor(l?.color ?? 7);
    }
    if (c == 0) return blockColor; // POR BLOQUE
    return aciColor(c.abs());
  }

  void arcPoints(
    List<double> out,
    double cx,
    double cy,
    double r,
    double a0,
    double a1,
    _M m,
  ) {
    var sweep = a1 - a0;
    if (sweep <= 0) sweep += 2 * math.pi;
    final n = _segmentsFor(r * m.scale, sweep, b.tol);
    for (var k = 0; k <= n; k++) {
      final a = a0 + sweep * k / n;
      final x = cx + r * math.cos(a), y = cy + r * math.sin(a);
      out
        ..add(m.tx(x, y))
        ..add(m.ty(x, y));
    }
  }

  void bulgeSegment(
    List<double> out,
    double x0,
    double y0,
    double x1,
    double y1,
    double bulge,
    _M m,
  ) {
    if (bulge.abs() < 1e-9) {
      out
        ..add(m.tx(x1, y1))
        ..add(m.ty(x1, y1));
      return;
    }
    final theta = 4 * math.atan(bulge); // ángulo incluido con signo
    final dx = x1 - x0, dy = y1 - y0;
    final chord = math.sqrt(dx * dx + dy * dy);
    if (chord < 1e-12) return;
    final r = chord / (2 * math.sin(theta.abs() / 2));
    final mx = (x0 + x1) / 2, my = (y0 + y1) / 2;
    final h =
        r * math.cos(theta / 2); // distancia del centro a la cuerda (con signo)
    final nx = -dy / chord, ny = dx / chord;
    final cx =
        mx +
        nx *
            h *
            (theta > 0 ? 1 : 1) *
            (bulge > 0 ? 1 : -1) *
            (bulge > 0 ? 1 : 1);
    final cy = my + ny * h * (bulge > 0 ? 1 : -1);
    final a0 = math.atan2(y0 - cy, x0 - cx);
    final n = _segmentsFor(r * m.scale, theta, b.tol);
    for (var k = 1; k <= n; k++) {
      final a = a0 + theta * k / n;
      final x = cx + r.abs() * math.cos(a), y = cy + r.abs() * math.sin(a);
      out
        ..add(m.tx(x, y))
        ..add(m.ty(x, y));
    }
  }

  void spline(_Entity e, String layer, int rgb, _M m) {
    final deg = e.firstInt(71) ?? 3;
    final knots = <double>[];
    final ctrl = <List<double>>[];
    final fit = <List<double>>[];
    final weights = <double>[];
    double? px;
    var mode = 0;
    for (final q in e.data) {
      switch (q.code) {
        case 40:
          knots.add(q.d);
        case 41:
          weights.add(q.d);
        case 10:
          px = q.d;
          mode = 10;
        case 20:
          if (px != null && mode == 10) ctrl.add([px, q.d]);
          px = null;
        case 11:
          px = q.d;
          mode = 11;
        case 21:
          if (px != null && mode == 11) fit.add([px, q.d]);
          px = null;
      }
    }
    final out = <double>[];
    final sampled = _bsplinePoints(deg, knots, ctrl, weights);
    if (sampled != null) {
      for (var q = 0; q + 1 < sampled.length; q += 2) {
        out
          ..add(m.tx(sampled[q], sampled[q + 1]))
          ..add(m.ty(sampled[q], sampled[q + 1]));
      }
    } else {
      final pts = fit.isNotEmpty ? fit : ctrl;
      for (final p in pts) {
        out
          ..add(m.tx(p[0], p[1]))
          ..add(m.ty(p[0], p[1]));
      }
    }
    b.polyline(layer, rgb, out);
  }

  void emit(_Entity e, _M m, String blockLayer, int blockColor, int depth) {
    if (depth > 12) return;
    var layer = e.firstStr(8) ?? '0';
    if (layer == '0' && blockLayer != '0') layer = blockLayer;
    final lay = layers[layer];
    if (lay != null && lay.hidden) return;
    final rgb = colorOf(e, layer, blockColor);
    switch (e.type) {
      case 'LINE':
        final x0 = e.first(10) ?? 0,
            y0 = e.first(20) ?? 0,
            x1 = e.first(11) ?? 0,
            y1 = e.first(21) ?? 0;
        b.segment(
          layer,
          rgb,
          m.tx(x0, y0),
          m.ty(x0, y0),
          m.tx(x1, y1),
          m.ty(x1, y1),
        );
      case 'CIRCLE':
        final out = <double>[];
        arcPoints(
          out,
          e.first(10) ?? 0,
          e.first(20) ?? 0,
          e.first(40) ?? 0,
          0,
          2 * math.pi,
          m,
        );
        b.polyline(layer, rgb, out);
      case 'ARC':
        final out = <double>[];
        arcPoints(
          out,
          e.first(10) ?? 0,
          e.first(20) ?? 0,
          e.first(40) ?? 0,
          (e.first(50) ?? 0) * math.pi / 180,
          (e.first(51) ?? 360) * math.pi / 180,
          m,
        );
        b.polyline(layer, rgb, out);
      case 'ELLIPSE':
        final cx = e.first(10) ?? 0, cy = e.first(20) ?? 0;
        final ax = e.first(11) ?? 1, ay = e.first(21) ?? 0;
        final ratio = e.first(40) ?? 1;
        final t0 = e.first(41) ?? 0, t1 = e.first(42) ?? 2 * math.pi;
        var sweep = t1 - t0;
        if (sweep <= 0) sweep += 2 * math.pi;
        final rMaj = math.sqrt(ax * ax + ay * ay);
        final n = _segmentsFor(rMaj * m.scale, sweep, b.tol);
        final out = <double>[];
        for (var k = 0; k <= n; k++) {
          final t = t0 + sweep * k / n;
          final x = cx + ax * math.cos(t) - ay * ratio * math.sin(t);
          final y = cy + ay * math.cos(t) + ax * ratio * math.sin(t);
          out
            ..add(m.tx(x, y))
            ..add(m.ty(x, y));
        }
        b.polyline(layer, rgb, out);
      case 'LWPOLYLINE':
        final closed = ((e.firstInt(70) ?? 0) & 1) != 0;
        final xs = <double>[], ys = <double>[], bulges = <double>[];
        double? cx;
        for (final q in e.data) {
          if (q.code == 10) {
            cx = q.d;
          } else if (q.code == 20 && cx != null) {
            xs.add(cx);
            ys.add(q.d);
            bulges.add(0);
            cx = null;
          } else if (q.code == 42 && bulges.isNotEmpty) {
            bulges[bulges.length - 1] = q.d;
          }
        }
        _vertexPath(b, layer, rgb, xs, ys, bulges, closed, m, bulgeSegment);
      case 'POLYLINE':
        final flags = e.firstInt(70) ?? 0;
        if ((flags & 16) != 0 || (flags & 64) != 0)
          return; // malla 3D: no se dibuja en 2D
        final closed = (flags & 1) != 0;
        final xs = <double>[], ys = <double>[], bulges = <double>[];
        for (final v in e.children) {
          if (((v.firstInt(70) ?? 0) & 16) != 0)
            continue; // vértice de ajuste de spline
          xs.add(v.first(10) ?? 0);
          ys.add(v.first(20) ?? 0);
          bulges.add(v.first(42) ?? 0);
        }
        _vertexPath(b, layer, rgb, xs, ys, bulges, closed, m, bulgeSegment);
      case 'SPLINE':
        spline(e, layer, rgb, m);
      case 'SOLID' || 'TRACE' || '3DFACE':
        final pts = <double>[];
        for (final (cx, cy) in [(10, 20), (11, 21), (12, 22), (13, 23)]) {
          final x = e.first(cx), y = e.first(cy);
          if (x != null && y != null)
            pts
              ..add(m.tx(x, y))
              ..add(m.ty(x, y));
        }
        if (e.type == 'SOLID' && pts.length >= 8) {
          // SOLID guarda el orden 1,2,4,3
          final t = [
            pts[0],
            pts[1],
            pts[2],
            pts[3],
            pts[6],
            pts[7],
            pts[4],
            pts[5],
          ];
          b.polyline(layer, rgb, t, closed: true);
        } else {
          b.polyline(layer, rgb, pts, closed: true);
        }
      case 'DIMENSION':
        // La cota guarda su dibujo en un bloque anónimo (*D1…).
        final bn = e.firstStr(2);
        final blk = bn == null ? null : blocks[bn];
        if (blk != null) {
          for (final be in blk.entities) {
            emit(be, m, layer, rgb, depth + 1);
          }
        }
      case 'HATCH':
        // Se dibuja el contorno de cada trayecto del relleno (líneas, arcos y polilíneas).
        // Los contornos del relleno van a una capa propia para no contarlos dos veces al cortar.
        final hl = tr('{l} (relleno)', {'l': layer});
        final d = e.data;
        var i = 0;
        while (i < d.length && d[i].code != 91) {
          i++;
        }
        if (i >= d.length) return;
        final paths = d[i].i;
        i++;
        double num(int code) {
          // Siguiente valor con ese código, sin pasar de un código de borde (72/92/97).
          while (i < d.length) {
            final q = d[i++];
            if (q.code == code) return q.d;
          }
          return 0;
        }

        for (var pth = 0; pth < paths && i < d.length; pth++) {
          while (i < d.length && d[i].code != 92) {
            i++;
          }
          if (i >= d.length) break;
          final flags = d[i].i;
          i++;
          if ((flags & 2) != 0) {
            final hasBulge = num(72) != 0;
            final closed = num(73) != 0;
            final n = num(93).round();
            final xs = <double>[], ys = <double>[], bulges = <double>[];
            for (var k = 0; k < n && i < d.length; k++) {
              final x = num(10);
              final y = num(20);
              var bu = 0.0;
              if (hasBulge && i < d.length && d[i].code == 42) bu = d[i++].d;
              xs.add(x);
              ys.add(y);
              bulges.add(bu);
            }
            _vertexPath(b, hl, rgb, xs, ys, bulges, closed, m, bulgeSegment);
          } else {
            final edges = num(93).round();
            for (var k = 0; k < edges && i < d.length; k++) {
              final type = num(72).round();
              if (type == 1) {
                final x0 = num(10), y0 = num(20), x1 = num(11), y1 = num(21);
                b.segment(
                  hl,
                  rgb,
                  m.tx(x0, y0),
                  m.ty(x0, y0),
                  m.tx(x1, y1),
                  m.ty(x1, y1),
                );
              } else if (type == 2) {
                final cx = num(10), cy = num(20), r = num(40);
                final a0 = num(50) * math.pi / 180,
                    a1 = num(51) * math.pi / 180;
                final ccw = num(73) != 0;
                final out = <double>[];
                if (ccw) {
                  arcPoints(out, cx, cy, r, a0, a1, m);
                } else {
                  arcPoints(out, cx, cy, r, a1, a0, m);
                }
                b.polyline(hl, rgb, out);
              } else if (type == 3) {
                final cx = num(10), cy = num(20), ax = num(11), ay = num(21);
                final ratio = num(40);
                final t0 = num(50) * math.pi / 180,
                    t1 = num(51) * math.pi / 180;
                num(73);
                var sweep = t1 - t0;
                if (sweep <= 0) sweep += 2 * math.pi;
                final rMaj = math.sqrt(ax * ax + ay * ay);
                final nn = _segmentsFor(rMaj * m.scale, sweep, b.tol);
                final out = <double>[];
                for (var kk = 0; kk <= nn; kk++) {
                  final t = t0 + sweep * kk / nn;
                  final x = cx + ax * math.cos(t) - ay * ratio * math.sin(t);
                  final y = cy + ay * math.cos(t) + ax * ratio * math.sin(t);
                  out
                    ..add(m.tx(x, y))
                    ..add(m.ty(x, y));
                }
                b.polyline(hl, rgb, out);
              } else if (type == 4) {
                // Spline: grado, racional, periódico, nudos, puntos de control (y pesos).
                final deg = num(94).round();
                final rational = num(73) != 0;
                num(74);
                final nk = num(95).round(), nc = num(96).round();
                final knots = <double>[
                  for (var q = 0; q < nk && i < d.length; q++) num(40),
                ];
                final ctrl = <List<double>>[];
                final weights = <double>[];
                for (var q = 0; q < nc && i < d.length; q++) {
                  final x = num(10), y = num(20);
                  ctrl.add([x, y]);
                  if (rational && i < d.length && d[i].code == 42) {
                    weights.add(d[i++].d);
                  }
                }
                final pts = _bsplinePoints(deg, knots, ctrl, weights);
                final out = <double>[];
                if (pts != null) {
                  for (var q = 0; q + 1 < pts.length; q += 2) {
                    out
                      ..add(m.tx(pts[q], pts[q + 1]))
                      ..add(m.ty(pts[q], pts[q + 1]));
                  }
                } else {
                  for (final c in ctrl) {
                    out
                      ..add(m.tx(c[0], c[1]))
                      ..add(m.ty(c[0], c[1]));
                  }
                }
                // Datos de ajuste opcionales (97 + puntos): se saltan.
                while (i < d.length &&
                    d[i].code != 72 &&
                    d[i].code != 97 &&
                    d[i].code != 92) {
                  i++;
                }
                b.polyline(hl, rgb, out);
              } else {
                // Tipo desconocido: se salta hasta el siguiente borde.
                while (i < d.length &&
                    d[i].code != 72 &&
                    d[i].code != 97 &&
                    d[i].code != 92) {
                  i++;
                }
              }
            }
          }
          // Objetos de origen del contorno (97 + 330…).
          while (i < d.length && d[i].code != 92 && d[i].code != 75) {
            i++;
          }
        }
      case 'TEXT' || 'MTEXT':
        final x = e.first(10), y = e.first(20);
        final t = e.firstStr(1);
        if (x != null && y != null && t != null && t.isNotEmpty) {
          b.texts.add(
            DrawingText(
              m.tx(x, y),
              m.ty(x, y),
              (e.first(40) ?? 2.5) * m.scale,
              (e.first(50) ?? 0),
              t,
            ),
          );
        }
      case 'INSERT':
        final name = e.firstStr(2) ?? '';
        final blk = blocks[name];
        if (blk == null) return;
        final ix = e.first(10) ?? 0, iy = e.first(20) ?? 0;
        final sx = e.first(41) ?? 1, sy = e.first(42) ?? 1;
        final rot = (e.first(50) ?? 0) * math.pi / 180;
        final cols = math.max(1, e.firstInt(70) ?? 1),
            rows = math.max(1, e.firstInt(71) ?? 1);
        final dx = e.first(44) ?? 0, dy = e.first(45) ?? 0;
        final cr = math.cos(rot), sr = math.sin(rot);
        for (var r = 0; r < rows; r++) {
          for (var c = 0; c < cols; c++) {
            // x' = R·S·(p - base) + ins + R·(c·dx, r·dy)
            final ox = ix + cr * (c * dx) - sr * (r * dy);
            final oy = iy + sr * (c * dx) + cr * (r * dy);
            final local = _M(
              cr * sx,
              sr * sx,
              -sr * sy,
              cr * sy,
              ox - (cr * sx * blk.bx - sr * sy * blk.by),
              oy - (sr * sx * blk.bx + cr * sy * blk.by),
            );
            final mm = m.mul(local);
            for (final be in blk.entities) {
              emit(be, mm, layer, rgb, depth + 1);
            }
          }
        }
    }
  }

  final inPaper = [
    for (final e in modelEntities)
      if (e.firstInt(67) == 1) e,
  ];
  for (final e in modelEntities) {
    if (e.firstInt(67) != 1) emit(e, _M.identity, '0', 0xFFFFFF, 0);
  }
  // Sin nada en el espacio modelo (planos que solo viven en el espacio papel): se muestra ese.
  if (b.perLayer.isEmpty && b.texts.isEmpty) {
    for (final e in inPaper) {
      emit(e, _M.identity, '0', 0xFFFFFF, 0);
    }
  }
  // Solo textos: una marca diminuta en cada uno mantiene el encuadre y la carga.
  if (b.perLayer.isEmpty && b.texts.isNotEmpty) {
    for (final t in b.texts) {
      b.segment('0', 0x808080, t.x, t.y, t.x + t.height * 0.02, t.y);
    }
  }

  // Une las capas en un solo buffer.
  final names = b.perLayer.keys.toList()..sort();
  final total = b.perLayer.values.fold<int>(0, (a, l) => a + l.length);
  final verts = Float32List(total);
  final groups = <(String, int, int)>[];
  var off = 0;
  final mn = [double.infinity, double.infinity, 0.0],
      mx = [-double.infinity, -double.infinity, 0.0];
  for (final n in names) {
    final l = b.perLayer[n]!;
    verts.setAll(off, l);
    groups.add((n, off ~/ 6, l.length ~/ 6));
    off += l.length;
    for (var k = 0; k < l.length; k += 6) {
      if (l[k] < mn[0]) mn[0] = l[k];
      if (l[k] > mx[0]) mx[0] = l[k];
      if (l[k + 1] < mn[1]) mn[1] = l[k + 1];
      if (l[k + 1] > mx[1]) mx[1] = l[k + 1];
    }
  }
  if (mn[0].isInfinite) {
    throw Exception(
      '${tr('El DXF no tiene dibujo en el espacio modelo ni en el papel')} '
      '${tr('(solo define bloques, capas o tablas).')}',
    );
  }
  insUnits; // unidades: se muestran más adelante
  return DxfData(
    fileName,
    verts,
    groups,
    mn,
    mx,
    b.texts,
    insUnits,
    !latin1
        .decode(bytes.sublist(math.max(0, bytes.length - 120)))
        .contains('EOF'),
  );
}

void _vertexPath(
  _Builder b,
  String layer,
  int rgb,
  List<double> xs,
  List<double> ys,
  List<double> bulges,
  bool closed,
  _M m,
  void Function(List<double>, double, double, double, double, double, _M)
  bulgeSegment,
) {
  final n = xs.length;
  if (n < 2) return;
  final out = <double>[m.tx(xs[0], ys[0]), m.ty(xs[0], ys[0])];
  final last = closed ? n : n - 1;
  for (var i = 0; i < last; i++) {
    final j = (i + 1) % n;
    bulgeSegment(out, xs[i], ys[i], xs[j], ys[j], bulges[i], m);
  }
  b.polyline(layer, rgb, out);
}

/// DXF binario: cabecera «AutoCAD Binary DXF\r\n\x1a\0» y grupos (código + valor tipado).
List<_Pair> _binaryPairs(Uint8List b) {
  final out = <_Pair>[];
  if (b.length < 25) return out;
  final bd = ByteData.sublistView(b);
  // R13+ usa códigos de 2 bytes; R12 y anteriores, 1 byte (y 255 + 2 bytes si es extendido).
  final wide = b[23] != 0x53;
  var p = 22;
  String cstr() {
    final st = p;
    while (p < b.length && b[p] != 0) {
      p++;
    }
    final v = utf8.decode(b.sublist(st, p), allowMalformed: true);
    p++;
    return v;
  }

  bool inR(int c, int a, int z) => c >= a && c <= z;
  while (p < b.length) {
    int code;
    if (wide) {
      if (p + 2 > b.length) break;
      code = bd.getUint16(p, Endian.little);
      p += 2;
    } else {
      code = b[p++];
      if (code == 255) {
        if (p + 2 > b.length) break;
        code = bd.getUint16(p, Endian.little);
        p += 2;
      }
    }
    if (p >= b.length + 1) break;
    if (inR(code, 10, 59) ||
        inR(code, 110, 149) ||
        inR(code, 210, 239) ||
        inR(code, 460, 469) ||
        inR(code, 1010, 1059)) {
      if (p + 8 > b.length) break;
      out.add(_Pair(code, bd.getFloat64(p, Endian.little).toString()));
      p += 8;
    } else if (inR(code, 60, 79) ||
        inR(code, 170, 179) ||
        inR(code, 270, 289) ||
        inR(code, 370, 389) ||
        inR(code, 400, 409) ||
        inR(code, 1060, 1070)) {
      if (p + 2 > b.length) break;
      out.add(_Pair(code, bd.getInt16(p, Endian.little).toString()));
      p += 2;
    } else if (inR(code, 90, 99) ||
        inR(code, 420, 429) ||
        inR(code, 440, 459) ||
        code == 1071) {
      if (p + 4 > b.length) break;
      out.add(_Pair(code, bd.getInt32(p, Endian.little).toString()));
      p += 4;
    } else if (inR(code, 160, 169)) {
      if (p + 8 > b.length) break;
      out.add(_Pair(code, bd.getInt64(p, Endian.little).toString()));
      p += 8;
    } else if (inR(code, 290, 299)) {
      if (p + 1 > b.length) break;
      out.add(_Pair(code, b[p].toString()));
      p += 1;
    } else if (inR(code, 310, 319)) {
      if (p + 1 > b.length) break;
      final n = b[p++];
      p += n;
    } else {
      out.add(_Pair(code, cstr()));
    }
  }
  return out;
}

/// Puntos (x, y, x, y…) de una B-spline racional; null si los nudos no cuadran con los puntos de control.
List<double>? _bsplinePoints(
  int deg,
  List<double> knots,
  List<List<double>> ctrl,
  List<double> weights,
) {
  if (!(ctrl.length > deg && knots.length == ctrl.length + deg + 1))
    return null;
  final out = <double>[];
  final tMin = knots[deg], tMax = knots[ctrl.length];
  final n = math.max(32, ctrl.length * 12);
  for (var s = 0; s <= n; s++) {
    final t = s == n
        ? tMax - (tMax - tMin) * 1e-12
        : tMin + (tMax - tMin) * s / n;
    var span = deg;
    while (span < ctrl.length - 1 && t >= knots[span + 1]) {
      span++;
    }
    final d = <List<double>>[
      for (var j = 0; j <= deg; j++)
        () {
          final idx = span - deg + j;
          final w = idx < weights.length ? weights[idx] : 1.0;
          return [ctrl[idx][0] * w, ctrl[idx][1] * w, w];
        }(),
    ];
    for (var r = 1; r <= deg; r++) {
      for (var j = deg; j >= r; j--) {
        final i = span - deg + j;
        final den = knots[i + deg - r + 1] - knots[i];
        final alpha = den == 0 ? 0.0 : (t - knots[i]) / den;
        for (var k = 0; k < 3; k++) {
          d[j][k] = (1 - alpha) * d[j - 1][k] + alpha * d[j][k];
        }
      }
    }
    final w = d[deg][2] == 0 ? 1.0 : d[deg][2];
    out
      ..add(d[deg][0] / w)
      ..add(d[deg][1] / w);
  }
  return out;
}
