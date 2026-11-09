// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:math' as math;
import 'dart:typed_data';

import 'lines.dart';
import 'print_summary.dart';
import 'mesh.dart';

/// Cómo se colorean las trayectorias.
enum ToolpathColorMode { feature, tool, height, speed, flow, flat }

/// Nombres de las categorías de movimiento (índice = valor en [Toolpath.feature]).
const kFeatureNames = [
  'Otros',
  'Pared exterior',
  'Pared interior',
  'Relleno',
  'Superficie sólida',
  'Soporte',
  'Puente / voladizo',
  'Falda / purga',
];

/// Colores por categoría (0xRRGGBB).
const kFeatureColors = [
  0x9AA7AB,
  0xFB923C,
  0xFDE047,
  0xF87171,
  0x38BDF8,
  0x5EEAD4,
  0xC4B5FD,
  0x64748B,
];

/// Paleta de reserva para herramientas / filamentos.
const kToolColors = [
  0xFB923C,
  0x5EEAD4,
  0xC4B5FD,
  0xFDE047,
  0xF472B6,
  0x38BDF8,
  0x34D399,
  0xF87171,
];

class _Snapshot {
  _Snapshot(
    this.vertices,
    this.feature,
    this.tool,
    this.feed,
    this.flow,
    this.layerFirstSeg,
  );
  final Float32List vertices;
  final Uint8List feature, tool;
  final Float32List feed, flow;
  final Int32List layerFirstSeg;
}

/// Trayectorias de G-code: movimientos con avance (`paths`) y rápidos (`travels`).
class Toolpath {
  Toolpath({
    required this.name,
    required this.paths,
    required this.travels,
    required this.feature,
    required this.tool,
    required this.feed,
    required this.flow,
    required this.layerFirstSeg,
    required this.layerFirstTravel,
    required this.layerZ,
    required this.info,
    required this.isFdm,
    required this.stats,
    this.toolColors = const [],
  });

  final String name;
  LineSet paths;
  final LineSet travels;
  Uint8List feature; // por segmento de `paths`
  Uint8List tool;
  Float32List feed;
  Float32List flow;

  /// Primer segmento de cada capa; el último elemento es el total de segmentos.
  Int32List layerFirstSeg;
  final Int32List layerFirstTravel;
  final Float32List layerZ;
  final List<String> info;
  final bool isFdm;
  final GcodeStats stats;
  PrintSummary? _summary;
  PrintSummary get summary => _summary ??= PrintSummary.of(this);

  /// Colores de filamento (0xRRGGBB) leídos del archivo, si los trae.
  final List<int> toolColors;

  ToolpathColorMode mode = ToolpathColorMode.feature;
  _Snapshot? _src;

  int get layerCount => layerFirstSeg.length - 1;
  Bounds get bounds => paths.bounds;

  /// Caja para encuadrar: ignora valores atípicos (líneas de purga, torre de limpieza lejana).
  Bounds get fitBounds {
    final v = paths.vertices;
    final n = v.length ~/ 6;
    if (n < 2000) return paths.bounds;
    final step = (n / 40000).ceil();
    final xs = <double>[], ys = <double>[], zs = <double>[];
    for (var i = 0; i < n; i += step) {
      xs.add(v[i * 6]);
      ys.add(v[i * 6 + 1]);
      zs.add(v[i * 6 + 2]);
    }
    double lo(List<double> a) => (a..sort())[(a.length * 0.004).floor()];
    double hi(List<double> a) =>
        a[(a.length * 0.996).floor().clamp(0, a.length - 1)];
    return Bounds([lo(xs), lo(ys), lo(zs)], [hi(xs), hi(ys), hi(zs)]);
  }

  /// Anchura real de extrusión estimada por categoría (mm): caudal ÷ (velocidad × altura de capa), con la
  /// corrección del perfil redondeado de los laminadores.
  /// `null` si hay pocas muestras. Útil para ver si el laminador ensancha las líneas respecto a la boquilla.
  List<double?> extrusionWidths() {
    final n = kFeatureNames.length;
    final sum = List<double>.filled(n, 0);
    final cnt = List<int>.filled(n, 0);
    final segs = feature.length;
    if (segs == 0 || layerZ.isEmpty) return List<double?>.filled(n, null);
    final step = math.max(1, segs ~/ 300000);
    for (var l = 0; l < layerCount && l < layerZ.length; l++) {
      final lh = l == 0 ? layerZ[0] : layerZ[l] - layerZ[l - 1];
      if (!(lh > 0.02 && lh < 2)) continue;
      final a = layerFirstSeg[l], b = math.min(layerFirstSeg[l + 1], segs);
      for (var i = a; i < b; i += step) {
        final f = feed[i], q = flow[i];
        if (!(f > 0 && q > 0)) continue;
        // los laminadores modelan la sección como un rectángulo con los extremos redondeados:
        // área = (ancho − altura·(1 − π/4)) · altura
        final w = q / (f / 60 * lh) + lh * (1 - math.pi / 4);
        if (w < 0.1 || w > 3) continue;
        final k = feature[i].clamp(0, n - 1);
        sum[k] += w;
        cnt[k]++;
      }
    }
    return [for (var k = 0; k < n; k++) cnt[k] >= 20 ? sum[k] / cnt[k] : null];
  }

  /// Número de segmentos de cada categoría (en el archivo completo).
  List<int> featureCounts() {
    final f = _src?.feature ?? feature;
    final c = List<int>.filled(kFeatureNames.length, 0);
    for (final v in f) {
      c[v.clamp(0, c.length - 1)]++;
    }
    return c;
  }

  /// Caudal volumétrico máximo razonable (percentil 98, mm³/s).
  double get flowMax {
    final src = flow;
    if (src.isEmpty) return 0;
    final step = math.max(1, src.length ~/ 20000);
    final a = <double>[for (var i = 0; i < src.length; i += step) src[i]]
      ..sort();
    return a[(a.length * 0.98).floor().clamp(0, a.length - 1)];
  }

  LineSet? _lod;
  Int32List? lodLayerFirst;

  /// Versión aligerada (≈200 mil segmentos) para girar y reproducir con trayectorias enormes:
  /// conserva paredes exteriores, superficies, soportes y puentes, y reparte el resto.
  LineSet get lod {
    final cached = _lod;
    if (cached != null) return cached;
    const target = 200000;
    final n = feature.length;
    // Cupo por categoría (paredes exteriores y superficies pesan más que relleno o torre de purga).
    const weight = [1, 4, 2, 1, 3, 1, 2, 1];
    final counts = featureCounts();
    final typed = counts.where((c) => c > 0).length >= 2;
    final stride = List<int>.filled(kFeatureNames.length, 1);
    if (typed) {
      var wsum = 0;
      for (var c = 0; c < counts.length; c++) {
        if (counts[c] > 0) wsum += weight[c];
      }
      for (var c = 0; c < counts.length; c++) {
        if (counts[c] == 0) continue;
        final quota = math.max(1, target * weight[c] ~/ wsum);
        stride[c] = math.max(1, (counts[c] / quota).ceil());
      }
    } else {
      stride[0] = math.max(1, (n / target).ceil());
    }
    final seen = List<int>.filled(kFeatureNames.length, 0);
    final keep = <int>[];
    final first = Int32List(layerFirstSeg.length);
    for (var l = 0; l < layerCount; l++) {
      first[l] = keep.length;
      for (var i = layerFirstSeg[l]; i < layerFirstSeg[l + 1]; i++) {
        final c = typed ? feature[i].clamp(0, stride.length - 1) : 0;
        if (seen[c]++ % stride[c] == 0) keep.add(i);
      }
    }
    first[layerCount] = keep.length;
    final v = Float32List(keep.length * 12);
    for (var o = 0; o < keep.length; o++) {
      v.setRange(o * 12, o * 12 + 12, paths.vertices, keep[o] * 12);
    }
    lodLayerFirst = first;
    return _lod = LineSet(vertices: v, bounds: paths.bounds);
  }

  LineSet? _guides;

  /// Ejes del origen de la pieza (X rojo, Y verde, Z azul) y caja de límites del corte (CNC).
  LineSet get guides => _guides ??= _buildGuides();

  LineSet _buildGuides() {
    final mn = bounds.min, mx = bounds.max; // solo movimientos de corte
    final size = math.max(
      1.0,
      math.max(mx[0] - mn[0], math.max(mx[1] - mn[1], mx[2] - mn[2])),
    );
    final L = size * 0.12;
    final v = <double>[];
    void line(List<double> a, List<double> b, int rgb) {
      final r = ((rgb >> 16) & 255) / 255,
          g = ((rgb >> 8) & 255) / 255,
          bl = (rgb & 255) / 255;
      v.addAll([a[0], a[1], a[2], r, g, bl, b[0], b[1], b[2], r, g, bl]);
    }

    line([0, 0, 0], [L, 0, 0], 0xF87171);
    line([0, 0, 0], [0, L, 0], 0x4ADE80);
    line([0, 0, 0], [0, 0, L], 0x60A5FA);
    const box = 0x475569;
    for (final z in [mn[2], mx[2]]) {
      line([mn[0], mn[1], z], [mx[0], mn[1], z], box);
      line([mx[0], mn[1], z], [mx[0], mx[1], z], box);
      line([mx[0], mx[1], z], [mn[0], mx[1], z], box);
      line([mn[0], mx[1], z], [mn[0], mn[1], z], box);
    }
    for (final x in [mn[0], mx[0]]) {
      for (final y in [mn[1], mx[1]]) {
        line([x, y, mn[2]], [x, y, mx[2]], box);
      }
    }
    return LineSet(vertices: Float32List.fromList(v), bounds: bounds);
  }

  /// Avance mínimo y máximo (mm/s) de los movimientos de trabajo.
  (double, double) get speedRange {
    var lo = double.infinity, hi = 0.0;
    for (final f in feed) {
      if (f > 0 && f < lo) lo = f;
      if (f > hi) hi = f;
    }
    return (lo.isInfinite ? 0 : lo / 60, hi / 60);
  }

  /// Capa a la que pertenece el segmento [seg].
  int layerOfSegment(int seg) {
    var lo = 0, hi = layerCount - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (layerFirstSeg[mid] <= seg) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Oculta categorías de movimiento reconstruyendo el buffer (las capas se conservan).
  void applyFilter(Set<int> hidden) {
    _lod = null;
    _src ??= _Snapshot(
      paths.vertices,
      feature,
      tool,
      feed,
      flow,
      layerFirstSeg,
    );
    final s = _src!;
    if (hidden.isEmpty) {
      paths = LineSet(
        vertices: s.vertices,
        bounds: _boundsOf(s.vertices, paths.bounds),
      );
      feature = s.feature;
      tool = s.tool;
      feed = s.feed;
      flow = s.flow;
      layerFirstSeg = s.layerFirstSeg;
      recolor(mode);
      return;
    }
    var keep = 0;
    for (final f in s.feature) {
      if (!hidden.contains(f)) keep++;
    }
    final v = Float32List(keep * 12);
    final nf = Uint8List(keep), nt = Uint8List(keep);
    final nfeed = Float32List(keep), nflow = Float32List(keep);
    final layers = Int32List(s.layerFirstSeg.length);
    var o = 0;
    final layerTotal = s.layerFirstSeg.length - 1;
    for (var l = 0; l < layerTotal; l++) {
      layers[l] = o;
      for (var i = s.layerFirstSeg[l]; i < s.layerFirstSeg[l + 1]; i++) {
        if (hidden.contains(s.feature[i])) continue;
        v.setRange(o * 12, o * 12 + 12, s.vertices, i * 12);
        nf[o] = s.feature[i];
        nt[o] = s.tool[i];
        nfeed[o] = s.feed[i];
        nflow[o] = s.flow[i];
        o++;
      }
    }
    layers[layerTotal] = o;
    paths = LineSet(vertices: v, bounds: _boundsOf(v, paths.bounds));
    feature = nf;
    tool = nt;
    feed = nfeed;
    flow = nflow;
    layerFirstSeg = layers;
    recolor(mode);
  }

  static Bounds _boundsOf(Float32List v, Bounds fallback) {
    if (v.isEmpty) return fallback;
    final mn = [double.infinity, double.infinity, double.infinity];
    final mx = [-double.infinity, -double.infinity, -double.infinity];
    for (var i = 0; i < v.length; i += 6) {
      for (var k = 0; k < 3; k++) {
        final x = v[i + k];
        if (x < mn[k]) mn[k] = x;
        if (x > mx[k]) mx[k] = x;
      }
    }
    return Bounds(mn, mx);
  }

  static int _lift(int rgb) {
    // Aclara los colores muy oscuros (p. ej. filamento negro) para que se vean sobre el fondo.
    var r = ((rgb >> 16) & 255).toDouble(),
        g = ((rgb >> 8) & 255).toDouble(),
        b = (rgb & 255).toDouble();
    final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    final lift = ((120 - lum) / 120).clamp(0.0, 1.0) * 0.75;
    r += (255 - r) * lift;
    g += (255 - g) * lift;
    b += (255 - b) * lift;
    return (r.round() << 16) | (g.round() << 8) | b.round();
  }

  static int _mix(int a, int b, double t) {
    int ch(int shift) =>
        (((a >> shift) & 255) * (1 - t) + ((b >> shift) & 255) * t).round();
    return (ch(16) << 16) | (ch(8) << 8) | ch(0);
  }

  /// Reescribe los colores de los vértices según el modo elegido.
  void recolor(ToolpathColorMode newMode) {
    mode = newMode;
    _lod = null;
    final v = paths.vertices;
    var fMin = double.infinity, fMax = 0.0;
    if (mode == ToolpathColorMode.speed) {
      for (final f in feed) {
        if (f > 0 && f < fMin) fMin = f;
        if (f > fMax) fMax = f;
      }
      if (fMin.isInfinite) fMin = 0;
    }
    final flMax = mode == ToolpathColorMode.flow ? flowMax : 0.0;
    final zLo = bounds.min[2], zSpan = bounds.max[2] - bounds.min[2];
    for (var s = 0; s < feature.length; s++) {
      int rgb;
      switch (mode) {
        case ToolpathColorMode.feature:
          rgb = kFeatureColors[feature[s].clamp(0, kFeatureColors.length - 1)];
        case ToolpathColorMode.tool:
          final pal = toolColors.isNotEmpty ? toolColors : kToolColors;
          rgb = _lift(pal[tool[s] % pal.length]);
        case ToolpathColorMode.height:
          final zMid = (v[s * 12 + 2] + v[s * 12 + 8]) / 2;
          final t = zSpan > 1e-9 ? ((zMid - zLo) / zSpan).clamp(0.0, 1.0) : 0.0;
          rgb = _mix(0xFB923C, 0x5EEAD4, t);
        case ToolpathColorMode.speed:
          final t = fMax > fMin
              ? ((feed[s] - fMin) / (fMax - fMin)).clamp(0.0, 1.0)
              : 0.5;
          // azul (lento) → verde → rojo (rápido)
          final r = (t < 0.5 ? 0.0 : (t - 0.5) * 2),
              g = t < 0.5 ? t * 2 : 1 - (t - 0.5) * 1.0,
              b = t < 0.5 ? 1 - t * 2 : 0.0;
          rgb =
              ((r * 255).round() << 16) |
              ((g * 255).round() << 8) |
              (b * 255).round();
        case ToolpathColorMode.flow:
          final t = flMax > 0 ? (flow[s] / flMax).clamp(0.0, 1.0) : 0.0;
          rgb = flow[s] <= 0 ? 0x64748B : _mix(0x38BDF8, 0xF43F5E, t);
        case ToolpathColorMode.flat:
          rgb = 0xB7CACD;
      }
      final r = ((rgb >> 16) & 255) / 255,
          g = ((rgb >> 8) & 255) / 255,
          b = (rgb & 255) / 255;
      final o = s * 12;
      v[o + 3] = r;
      v[o + 4] = g;
      v[o + 5] = b;
      v[o + 9] = r;
      v[o + 10] = g;
      v[o + 11] = b;
    }
    paths.gpu = null; // fuerza la subida del buffer actualizado
  }
}
