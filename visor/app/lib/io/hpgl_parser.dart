// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:io';
import 'dart:math' as math;

import '../l10n/l10n.dart';
import 'iso_run.dart';
import '../model/lines.dart';
import '../model/vector_info.dart';
import 'dxf_loader.dart';
import 'svg_loader.dart' show packVector;

/// HPGL y HPGL/2 (`.plt`, `.hpgl`, `.hgl`): plumas, PU/PD, PA/PR, PE, arcos, círculos, rectángulos,
/// modo polígono y rótulos. Unidad del plóter: 40 por mm (0,025 mm).
const double _mmPerPlu = 0.025;
/// Nombre (traducido) de la capa de viajes; `isTravelLayerName` la reconoce en cualquier idioma.
String get _travelLayer => tr('Viajes (pluma arriba)');
const int _kMaxTravelSegments = 1000000;

const _defaultPens = [
  0x000000, // 0 (blanco en papel; se muestra como la 1)
  0x000000,
  0xE53935,
  0x2E9E4B,
  0x2F6FDE,
  0xE0B000,
  0xC03CC0,
  0x00A8C8,
  0xF57C00,
];

/// Texto del archivo: quita el envoltorio PCL/PJL de los `.plt` de HPGL/2 y deja solo el HPGL.
String _hpglText(List<int> bytes, VectorInfo? info) {
  final raw = String.fromCharCodes(bytes);
  if (!raw.contains('\x1b')) return _clean(raw);
  // Entre «<Esc>%0B» (entrar en HPGL/2) y «<Esc>%0A» (volver a PCL).
  final out = StringBuffer();
  var found = false;
  for (final m in RegExp(r'\x1b%-?\d*B(.*?)(?=\x1b%-?\d*[AX]|\x1bE|$)', dotAll: true).allMatches(raw)) {
    out.write(m.group(1));
    out.write(';');
    found = true;
  }
  if (found) return _clean(out.toString());
  return _clean(raw.replaceAll(RegExp(r'\x1b[%&*(][-\d.]*[A-Za-z@]|\x1bE|@PJL[^\n]*\n?'), ''));
}

String _clean(String s) {
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    if (c >= 32 || c == 3 || c == 9 || c == 10 || c == 13) b.writeCharCode(c);
  }
  return b.toString();
}

bool _isLetter(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);

class _Plotter {
  _Plotter(this.info);
  final VectorInfo info;
  final perPen = <int, List<double>>{};
  final travel = <double>[];
  final texts = <DrawingText>[];
  final polyBuf = <List<double>>[];
  final pensByNumber = <int, VectorPen>{};
  final penColors = <int, int>{};
  final penWidths = <int, double>{};

  int pen = 1;
  bool down = false;
  bool absolute = true;
  bool polyMode = false;
  double x = 0, y = 0;
  bool lastDrew = false;

  // Escala del usuario (SC / IP).
  double p1x = 0, p1y = 0, p2x = 10000, p2y = 7000;
  bool hasIp = false;
  List<double>? sc;
  int scType = 0;
  double chordDeg = 5;
  int rotation = 0; // RO: 0, 90, 180, 270

  // Rótulos.
  double charHmm = 2.69;
  double dirRun = 1, dirRise = 0;
  int labelEnd = 3;

  VectorPen currentPen() => pensByNumber.putIfAbsent(pen, () => VectorPen(pen));

  double ux(double v) => sc == null ? v : p1x + (v - sc![0]) / (sc![1] - sc![0]) * (p2x - p1x);
  double uy(double v) => sc == null ? v : p1y + (v - sc![2]) / (sc![3] - sc![2]) * (p2y - p1y);

  int colorOf(int n) => penColors[n] ?? _defaultPens[n % _defaultPens.length];

  /// Gira un punto según RO (el sistema de coordenadas del plóter gira alrededor del origen).
  (double, double) _rot(double x, double y) => switch (rotation) {
    90 => (-y, x),
    180 => (-x, -y),
    270 => (y, -x),
    _ => (x, y),
  };

  void bezier(List<double> pts, bool relative) {
    for (var i = 0; i + 5 < pts.length; i += 6) {
      final x0 = x, y0 = y;
      final b = relative ? [x0, y0, x0, y0, x0, y0] : [0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
      final x1 = pts[i] + b[0], y1 = pts[i + 1] + b[1], x2 = pts[i + 2] + b[2], y2 = pts[i + 3] + b[3], x3 = pts[i + 4] + b[4], y3 = pts[i + 5] + b[5];
      const n = 24;
      for (var k = 1; k <= n; k++) {
        final s = k / n, u = 1 - s;
        moveTo(
          u * u * u * x0 + 3 * u * u * s * x1 + 3 * u * s * s * x2 + s * s * s * x3,
          u * u * u * y0 + 3 * u * u * s * y1 + 3 * u * s * s * y2 + s * s * s * y3,
          penDown: true,
        );
      }
    }
  }

  void _line(double x0, double y0, double x1, double y1) {
    final l = perPen.putIfAbsent(pen, () => <double>[]);
    var rgb = colorOf(pen);
    var r = ((rgb >> 16) & 255).toDouble(), g = ((rgb >> 8) & 255).toDouble(), b = (rgb & 255).toDouble();
    final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    final lift = ((140 - lum) / 140).clamp(0.0, 1.0) * 0.7;
    r += (255 - r) * lift;
    g += (255 - g) * lift;
    b += (255 - b) * lift;
    const u = _mmPerPlu;
    final (ax, ay) = _rot(x0, y0);
    final (bx, by) = _rot(x1, y1);
    l.addAll([ax * u, ay * u, 0, r / 255, g / 255, b / 255, bx * u, by * u, 0, r / 255, g / 255, b / 255]);
    final d = math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)) * u;
    info.drawMm += d;
    final p = currentPen();
    p.drawMm += d;
  }

  void _travel(double x0, double y0, double x1, double y1) {
    final d = math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)) * _mmPerPlu;
    info.travelMm += d;
    if (travel.length ~/ 12 < _kMaxTravelSegments) {
      const u = _mmPerPlu;
      final (ax, ay) = _rot(x0, y0);
    final (bx, by) = _rot(x1, y1);
      travel.addAll([ax * u, ay * u, 0, 0.55, 0.58, 0.62, bx * u, by * u, 0, 0.55, 0.58, 0.62]);
    }
  }

  /// Mueve la pluma. `forceDown` dibuja aunque la pluma esté arriba (círculos, rectángulos).
  void moveTo(double nx, double ny, {bool? penDown}) {
    if (!nx.isFinite || !ny.isFinite) return;
    final d = penDown ?? down;
    if (polyMode) {
      if (!d) {
        polyBuf.add([nx, ny]);
      } else {
        if (polyBuf.isEmpty) polyBuf.add([x, y]);
        polyBuf.last
          ..add(nx)
          ..add(ny);
      }
      x = nx;
      y = ny;
      return;
    }
    if (nx != x || ny != y) {
      if (d) {
        if (!lastDrew) currentPen().strokes++;
        _line(x, y, nx, ny);
        lastDrew = true;
      } else {
        _travel(x, y, nx, ny);
        info.lifts++;
        lastDrew = false;
      }
    }
    x = nx;
    y = ny;
  }

  void arcAround(double cx, double cy, double sweepDeg, {double? chord}) {
    final r = math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
    if (r == 0 || !r.isFinite || !sweepDeg.isFinite) return;
    final a0 = math.atan2(y - cy, x - cx);
    final sweep = sweepDeg * math.pi / 180;
    final step = math.max((chord ?? chordDeg).abs(), 1) * math.pi / 180;
    final n = (sweep.abs() / step).ceil().clamp(2, 720);
    for (var k = 1; k <= n; k++) {
      final a = a0 + sweep * k / n;
      moveTo(cx + r * math.cos(a), cy + r * math.sin(a), penDown: true);
    }
  }

  void circle(double r, {double? chord}) {
    if (r <= 0 || !r.isFinite) return;
    final cx = x, cy = y;
    final wasX = x, wasY = y;
    x = cx + r;
    y = cy;
    final save = down;
    arcAround(cx, cy, 360, chord: chord);
    down = save;
    x = wasX;
    y = wasY;
  }

  void rect(double x1, double y1) {
    final x0 = x, y0 = y;
    moveTo(x1, y0, penDown: true);
    moveTo(x1, y1, penDown: true);
    moveTo(x0, y1, penDown: true);
    moveTo(x0, y0, penDown: true);
  }

  void threePointArc(double mx, double my, double ex, double ey, {double? chord}) {
    final ax = x, ay = y;
    final d = 2 * (ax * (my - ey) + mx * (ey - ay) + ex * (ay - my));
    if (d.abs() < 1e-9) {
      moveTo(mx, my, penDown: true);
      moveTo(ex, ey, penDown: true);
      return;
    }
    final a2 = ax * ax + ay * ay, b2 = mx * mx + my * my, c2 = ex * ex + ey * ey;
    final cx = (a2 * (my - ey) + b2 * (ey - ay) + c2 * (ay - my)) / d;
    final cy = (a2 * (ex - mx) + b2 * (ax - ex) + c2 * (mx - ax)) / d;
    final a0 = math.atan2(ay - cy, ax - cx);
    final am = math.atan2(my - cy, mx - cx);
    final ae = math.atan2(ey - cy, ex - cx);
    double norm(double a) => ((a % (2 * math.pi)) + 2 * math.pi) % (2 * math.pi);
    final ccw = norm(am - a0) < norm(ae - a0);
    var sweep = ccw ? norm(ae - a0) : -norm(a0 - ae);
    if (sweep == 0) sweep = ccw ? 2 * math.pi : -2 * math.pi;
    arcAround(cx, cy, sweep * 180 / math.pi, chord: chord);
  }

  void label(String text) {
    final t = text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (t.isEmpty) return;
    info.labels++;
    texts.add(
      DrawingText(
        _rot(x, y).$1 * _mmPerPlu,
        _rot(x, y).$2 * _mmPerPlu,
        charHmm,
        math.atan2(dirRise, dirRun) * 180 / math.pi + rotation,
        t,
      ),
    );
  }

  void endPolygon() {
    final subs = polyBuf.toList();
    polyBuf.clear();
    final save = down;
    final sx = x, sy = y;
    polyMode = false;
    for (final s in subs) {
      if (s.length < 4) continue;
      x = s[0];
      y = s[1];
      down = false;
      for (var i = 2; i + 1 < s.length; i += 2) {
        moveTo(s[i], s[i + 1], penDown: true);
      }
      // Cierra el polígono.
      if (s.length > 4) moveTo(s[0], s[1], penDown: true);
    }
    x = sx;
    y = sy;
    down = save;
  }

  // ---- PE (polilínea codificada)
  void pe(String data) {
    var pos = 0;
    var base32 = false;
    var frac = 0;
    var abs = false, upNext = false;
    final saveDown = down;
    down = true;
    info.encodedPolylines = true;
    int? number() {
      var val = 0, shift = 0;
      while (pos < data.length) {
        final c = data.codeUnitAt(pos);
        bool last;
        int v;
        if (base32) {
          if (c >= 95 && c <= 126) {
            v = c - 95;
            last = true;
          } else if (c >= 63 && c <= 94) {
            v = c - 63;
            last = false;
          } else {
            return null;
          }
          val |= v << shift;
          shift += 5;
        } else {
          if (c >= 63 && c <= 126) {
            v = c - 63;
            last = true;
          } else if (c >= 191 && c <= 254) {
            v = c - 191;
            last = false;
          } else {
            return null;
          }
          val |= v << shift;
          shift += 6;
        }
        pos++;
        if (shift > 60) return null;
        if (last) {
          final mag = val >> 1;
          return (val & 1) == 1 ? -mag : mag;
        }
      }
      return null;
    }

    final scale = 1.0;
    while (pos < data.length) {
      final c = data[pos];
      if (c == ':') {
        pos++;
        final n = number();
        if (n == null) break;
        pen = n;
      } else if (c == '<') {
        pos++;
        upNext = true;
      } else if (c == '>') {
        pos++;
        final n = number();
        if (n == null) break;
        frac = n.clamp(0, 30);
      } else if (c == '=') {
        pos++;
        abs = true;
      } else if (c == '7') {
        pos++;
        base32 = true;
      } else if (c == ' ' || c == '\n' || c == '\r' || c == ',') {
        pos++;
      } else {
        final a = number(), b = number();
        if (a == null || b == null) break;
        final div = (1 << frac) / scale;
        final nx = abs ? a / div : x + a / div, ny = abs ? b / div : y + b / div;
        moveTo(nx, ny, penDown: !upNext);
        upNext = false;
        abs = false;
      }
    }
    down = saveDown;
  }
}

/// Divide el flujo en sentencias (`mnemónico`, `parámetros`). Respeta rótulos (`LB`) y PE.
Iterable<(String, String)> _statements(String t, _Plotter p) sync* {
  var i = 0;
  final n = t.length;
  while (i < n) {
    var c = t.codeUnitAt(i);
    if (!_isLetter(c)) {
      i++;
      continue;
    }
    if (i + 1 >= n || !_isLetter(t.codeUnitAt(i + 1))) {
      i++;
      continue;
    }
    final mn = t.substring(i, i + 2).toUpperCase();
    i += 2;
    var j = i;
    if (mn == 'LB') {
      // El rótulo acaba en ETX (o en el carácter de DT) y puede ocupar varias líneas; si no hay
      // terminador cerca, acaba en el fin de línea.
      final etx = t.indexOf(String.fromCharCode(p.labelEnd), i);
      if (etx >= 0 && etx - i < 4000) {
        j = etx;
      } else {
        while (j < n) {
          final cj = t.codeUnitAt(j);
          if (cj == 10 || cj == 13) break;
          j++;
        }
      }
      yield (mn, t.substring(i, j));
      i = j < n ? j + 1 : n;
      continue;
    }
    if (mn == 'DT') {
      if (i < n) {
        yield (mn, t.substring(i, i + 1));
        i++;
        if (i < n && t[i] == ';') i++;
      }
      continue;
    }
    if (mn == 'CO') {
      // Comentario: «CO "texto";»
      var q = t.indexOf('"', i);
      if (q >= 0) {
        q = t.indexOf('"', q + 1);
        j = q >= 0 ? q + 1 : n;
      }
      while (j < n && t[j] != ';') {
        j++;
      }
      i = j < n ? j + 1 : n;
      continue;
    }
    if (mn == 'PE') {
      while (j < n && t[j] != ';') {
        j++;
      }
      yield (mn, t.substring(i, j));
      i = j < n ? j + 1 : n;
      continue;
    }
    while (j < n) {
      c = t.codeUnitAt(j);
      if (c == 59 /* ; */ || _isLetter(c)) break;
      j++;
    }
    yield (mn, t.substring(i, j));
    i = j < n && t[j] == ';' ? j + 1 : j;
  }
}

List<double> _args(String s) {
  final out = <double>[];
  for (final m in RegExp(r'[-+]?(?:\d+\.?\d*|\.\d+)').allMatches(s)) {
    final v = double.tryParse(m.group(0)!);
    if (v != null && v.isFinite) out.add(v);
  }
  return out;
}

const _ignored = {
  'DF', 'VS', 'FS', 'PG', 'NR', 'AF', 'AH', 'OP', 'OI', 'OE', 'OS', 'OA', 'OC', 'OD', 'OF', 'OH', 'OW', 'OT',
  'ES', 'LT', 'RF', 'SM', 'SA', 'SS', 'CS', 'CC', 'IM', 'IW', 'KY', 'LO', 'SL', 'TL', 'XT', 'YT', 'TR', 'TD',
  'MC', 'MG', 'MT', 'PP', 'PS', 'QL', 'SG', 'SC_', 'UL', 'UF', 'WU', 'ST', 'FT', 'BP', 'DL', 'DR', 'DC',
  'DP', 'EC', 'FR', 'GM', 'IR', 'IV', 'OG', 'OK', 'OL', 'OO', 'OR', 'OV', 'PM_', 'RP', 'SB', 'SI_', 'TP',
  'TA', 'NP', 'PW_', 'GC', 'LA', 'PL', 'SD', 'CF', 'WD', 'SV', 'EF', 'RO_', 'WG_', 'FI', 'FN', 'LM',
};

DxfData parseHpgl(String path) {
  try {
    return _parseHpgl(path);
  } on FormatException {
    rethrow;
  } on Error catch (e) {
    throw FormatException(tr('El HPGL no se puede interpretar ({t})', {'t': e.runtimeType}));
  }
}

DxfData _parseHpgl(String path) {
  final name = path.split('/').last;
  final bytes = File(path).readAsBytesSync();
  final hpgl2Wrapper = bytes.contains(0x1b);
  final text = _hpglText(bytes, null);
  var start = text.indexOf(RegExp(r'IN\s*;|IN\b'));
  final body = start > 0 ? text.substring(start) : text;

  final info = VectorInfo('HPGL')..unitNote = tr('Unidades del plóter: 40 por milímetro ({d} mm).', {'d': '0.025'.ldec});
  final p = _Plotter(info);
  var any = false;
  var usedSc = false, hpgl2 = hpgl2Wrapper;

  for (final (mn, raw) in _statements(body, p)) {
    final a = _args(raw);
    switch (mn) {
      case 'IN':
        p.down = false;
        p.absolute = true;
        p.polyMode = false;
        p.sc = null;
      case 'IP':
        if (a.length >= 4) {
          p.p1x = a[0];
          p.p1y = a[1];
          p.p2x = a[2];
          p.p2y = a[3];
          p.hasIp = true;
        } else if (a.length >= 2) {
          final w = p.p2x - p.p1x, h = p.p2y - p.p1y;
          p.p1x = a[0];
          p.p1y = a[1];
          p.p2x = p.p1x + w;
          p.p2y = p.p1y + h;
          p.hasIp = true;
        }
      case 'SC':
        if (a.length >= 4 && a[1] != a[0] && a[3] != a[2]) {
          p.sc = a.sublist(0, 4);
          p.scType = a.length > 4 ? a[4].toInt() : 0;
          usedSc = true;
          if (p.scType == 1) {
            // Isótropa: se conserva la proporción dentro del rectángulo P1-P2.
            final sx = (p.p2x - p.p1x).abs() / (a[1] - a[0]).abs();
            final sy = (p.p2y - p.p1y).abs() / (a[3] - a[2]).abs();
            final s = math.min(sx, sy);
            final cx = (p.p1x + p.p2x) / 2, cy = (p.p1y + p.p2y) / 2;
            final hw = (a[1] - a[0]).abs() * s / 2, hh = (a[3] - a[2]).abs() * s / 2;
            p.p1x = cx - hw;
            p.p2x = cx + hw;
            p.p1y = cy - hh;
            p.p2y = cy + hh;
          }
        } else {
          p.sc = null;
        }
      case 'SP':
        if (a.isNotEmpty) p.pen = a[0].toInt();
      case 'PW':
        if (a.isNotEmpty) {
          hpgl2 = true;
          final pn = a.length > 1 ? a[1].toInt() : p.pen;
          p.penWidths[pn] = a[0];
        }
      case 'PC':
        if (a.length >= 4) {
          hpgl2 = true;
          p.penColors[a[0].toInt()] = (a[1].clamp(0, 255).toInt() << 16) | (a[2].clamp(0, 255).toInt() << 8) | a[3].clamp(0, 255).toInt();
        }
      case 'PU' || 'PD':
        final dn = mn == 'PD';
        p.down = dn;
        for (var i = 0; i + 1 < a.length; i += 2) {
          final nx = p.absolute ? p.ux(a[i]) : p.x + a[i], ny = p.absolute ? p.uy(a[i + 1]) : p.y + a[i + 1];
          p.moveTo(nx, ny);
        }
        any = true;
      case 'PA':
        p.absolute = true;
        for (var i = 0; i + 1 < a.length; i += 2) {
          p.moveTo(p.ux(a[i]), p.uy(a[i + 1]));
        }
        any = true;
      case 'PR':
        p.absolute = false;
        for (var i = 0; i + 1 < a.length; i += 2) {
          p.moveTo(p.x + a[i], p.y + a[i + 1]);
        }
        any = true;
      case 'PE':
        p.pe(raw);
        any = true;
      case 'BZ' || 'BR':
        hpgl2 = true;
        p.bezier(a, mn == 'BR');
        any = true;
      case 'RO':
        final deg = a.isEmpty ? 0 : a[0].toInt();
        p.rotation = (deg == 90 || deg == 180 || deg == 270) ? deg : 0;
      case 'CP' || 'LO' || 'SL' || 'XT' || 'YT' || 'ES' || 'PS' || 'CA' || 'CR' || 'IW' || 'WI':
        break;
      case 'CI':
        if (a.isNotEmpty) {
          p.circle(a[0], chord: a.length > 1 ? a[1] : null);
          any = true;
        }
      case 'AA' when a.length >= 3:
        p.arcAround(p.ux(a[0]), p.uy(a[1]), a[2], chord: a.length > 3 ? a[3] : null);
        any = true;
      case 'AR' when a.length >= 3:
        p.arcAround(p.x + a[0], p.y + a[1], a[2], chord: a.length > 3 ? a[3] : null);
        any = true;
      case 'AT' when a.length >= 4:
        p.threePointArc(p.ux(a[0]), p.uy(a[1]), p.ux(a[2]), p.uy(a[3]), chord: a.length > 4 ? a[4] : null);
        any = true;
      case 'RT' when a.length >= 4:
        p.threePointArc(p.x + a[0], p.y + a[1], p.x + a[0] + a[2], p.y + a[1] + a[3], chord: a.length > 4 ? a[4] : null);
        any = true;
      case 'EA' || 'RA':
        if (a.length >= 2) {
          p.rect(p.ux(a[0]), p.uy(a[1]));
          any = true;
        }
      case 'ER' || 'RR':
        if (a.length >= 2) {
          p.rect(p.x + a[0], p.y + a[1]);
          any = true;
        }
      case 'EW' || 'WG':
        if (a.length >= 3) {
          final cx = p.x, cy = p.y, r = a[0], s0 = a[1] * math.pi / 180;
          p.moveTo(cx + r * math.cos(s0), cy + r * math.sin(s0), penDown: true);
          p.arcAround(cx, cy, a[2], chord: a.length > 3 ? a[3] : null);
          p.moveTo(cx, cy, penDown: true);
          any = true;
        }
      case 'PM':
        final k = a.isEmpty ? 0 : a[0].toInt();
        if (k == 0) {
          p.polyMode = true;
          p.polyBuf.clear();
          p.polyBuf.add([p.x, p.y]);
        } else if (k == 1) {
          if (p.polyMode) p.polyBuf.add([p.x, p.y]);
        } else if (k == 2) {
          p.polyMode = false;
        }
      case 'EP' || 'FP':
        p.endPolygon();
        any = true;
      case 'SI':
        if (a.length >= 2) p.charHmm = (a[1] * 10).clamp(0.5, 200);
      case 'SR':
        if (a.length >= 2) p.charHmm = ((p.p2y - p.p1y).abs() * a[1] / 100 * _mmPerPlu).clamp(0.5, 200);
      case 'DI':
        if (a.length >= 2 && (a[0] != 0 || a[1] != 0)) {
          p.dirRun = a[0];
          p.dirRise = a[1];
        }
      case 'DR':
        break;
      case 'DT':
        if (raw.isNotEmpty) p.labelEnd = raw.codeUnitAt(0);
      case 'LB':
        p.label(raw);
      case 'XXX_':
        break;
      default:
        if (!_ignored.contains(mn)) {
          if (info.unknownCommands.length < 24) info.unknownCommands.add(mn);
        }
    }
  }
  if (p.perPen.isEmpty && p.texts.isEmpty) {
    throw FormatException(tr('El HPGL no dibuja ningún trazo (solo coloca la pluma)'));
  }

  // ---- Información
  final i2 = VectorInfo(hpgl2 || p.penWidths.isNotEmpty || p.penColors.isNotEmpty ? 'HPGL/2' : 'HPGL');
  i2
    ..unitNote = info.unitNote
    ..drawMm = info.drawMm
    ..travelMm = info.travelMm
    ..lifts = info.lifts
    ..labels = info.labels
    ..encodedPolylines = info.encodedPolylines
    ..unknownCommands.addAll(info.unknownCommands);
  final penNums = p.pensByNumber.keys.toList()..sort();
  for (final k in penNums) {
    final v = p.pensByNumber[k]!;
    v.widthMm = p.penWidths[k];
    v.rgb = p.penColors[k];
    i2.pens.add(v);
  }
  if (usedSc && !p.hasIp) {
    i2.warn(tr('El archivo usa SC sin IP: la escala del plóter se ha supuesto, el tamaño puede no ser el real.'));
  }
  if (info.labels > 0) {
    i2.warn(info.labels == 1
        ? tr('{n} rótulo (LB): el plóter los traza con su tipo de letra interno; aquí se muestran como texto, sin trazos que cortar.', {'n': info.labels})
        : tr('{n} rótulos (LB): el plóter los traza con su tipo de letra interno; aquí se muestran como texto, sin trazos que cortar.', {'n': info.labels}));
  }
  if (i2.travelShare > 0.3 && i2.travelMm > 200) {
    i2.warn(tr('El {p} % del recorrido es con la pluma levantada: ordenar los trazos acortaría el trabajo.', {'p': (i2.travelShare * 100).round()}));
  }
  if (info.unknownCommands.isNotEmpty) {
    i2.warn(tr('Instrucciones sin interpretar: {c}.', {'c': info.unknownCommands.take(8).join(', ')}));
  }

  final layers = <String, List<double>>{};
  final order = p.perPen.keys.toList()..sort();
  for (final k in order) {
    layers[tr('Pluma {n}', {'n': k})] = p.perPen[k]!;
  }
  if (p.travel.isNotEmpty) layers[_travelLayer] = p.travel;
  if (!any && layers.isEmpty && p.texts.isEmpty) throw FormatException(tr('El HPGL no dibuja ningún trazo (solo coloca la pluma)'));
  return packVector(name, layers, p.texts, i2, 4);
}

Future<DxfData> loadHpgl(String path) => isoRun(() => parseHpgl(path));
