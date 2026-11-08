import 'dart:typed_data';

import '../l10n/l10n.dart';
import 'cloud_info.dart';
import 'lines.dart';
import 'mesh.dart';

enum CloudColorMode { original, height, intensity, classification, returns, flat }

/// Atributos por punto, en el mismo orden que los vértices.
class CloudAttrs {
  CloudAttrs({this.intensity, this.cls, this.ret, this.nret});
  Uint16List? intensity;
  Uint8List? cls;

  /// Número de retorno y número de retornos del pulso.
  Uint8List? ret, nret;
}

/// Nube de puntos: un [LineSet] cuyos vértices se dibujan como puntos (x y z r g b).
/// Las coordenadas están restadas a [origin] para no perder precisión en coordenadas de mapa.
class PointCloud {
  PointCloud({
    required this.name,
    required this.points,
    required this.hasColor,
    this.attrs,
    CloudInfo? info,
    List<double>? origin,
  }) : info = info ?? CloudInfo(tr('Nube')),
       origin = origin ?? [0, 0, 0] {
    _full = points;
    final v = points.vertices;
    if (hasColor) {
      final o = Float32List(v.length ~/ 6 * 3);
      for (var i = 0, j = 0; i < v.length; i += 6, j += 3) {
        o[j] = v[i + 3];
        o[j + 1] = v[i + 4];
        o[j + 2] = v[i + 5];
      }
      _original = o;
    }
    mode = hasColor ? CloudColorMode.original : (hasClass ? CloudColorMode.classification : CloudColorMode.height);
    recolor(mode);
  }

  final String name;
  LineSet points;
  late final LineSet _full;

  /// Muestra de ~250 mil puntos (uno de cada k) para dibujar mientras se mueve la vista.
  LineSet lod = LineSet(vertices: Float32List(0), bounds: Bounds([0, 0, 0], [0, 0, 0]));
  static const int lodPoints = 250000;
  final bool hasColor;
  final CloudAttrs? attrs;
  final CloudInfo info;

  /// Coordenadas absolutas = vértice + origen.
  final List<double> origin;
  Float32List? _original;
  late CloudColorMode mode;

  /// Tamaño de punto en píxeles; `null` = automático según la cantidad.
  double? pointSize;

  /// Sombreado de borde (Eye-Dome Lighting): da relieve a los puntos según sus vecinos más cercanos.
  bool edl = true;
  double edlStrength = 1.0;

  /// Clases ocultas y recorte por altura (coordenadas relativas al origen).
  final Set<int> hiddenClasses = {};

  /// Recorte por un eje (0 X, 1 Y, 2 Z): sólo se ven los puntos entre [zClipLo] y [zClipHi].
  int clipAxis = 2;
  double? zClipLo, zClipHi;

  bool get hasIntensity => attrs?.intensity != null;
  bool get hasClass => attrs?.cls != null;
  bool get hasReturns => attrs?.ret != null;

  int get count => points.vertexCount;
  int get totalLoaded => _full.vertexCount;
  Bounds get bounds => _full.bounds;

  double get effectiveSize => pointSize ?? (totalLoaded > 2000000 ? 2.0 : 3.5);

  List<CloudColorMode> get availableModes => [
    if (hasColor) CloudColorMode.original,
    CloudColorMode.height,
    if (hasIntensity) CloudColorMode.intensity,
    if (hasClass) CloudColorMode.classification,
    if (hasReturns) CloudColorMode.returns,
    CloudColorMode.flat,
  ];

  /// Colorea todos los puntos cargados (no sólo los visibles).
  void recolor(CloudColorMode m) {
    mode = m;
    final v = _full.vertices;
    final zMin = _full.bounds.min[2], zMax = _full.bounds.max[2];
    final span = (zMax - zMin).abs() < 1e-9 ? 1.0 : zMax - zMin;
    final n = v.length ~/ 6;
    final a = attrs;
    switch (m) {
      case CloudColorMode.original:
        final o = _original;
        if (o == null) {
          _fill(v, n, 0.72, 0.79, 0.8);
        } else {
          for (var i = 0; i < n; i++) {
            v[i * 6 + 3] = o[i * 3];
            v[i * 6 + 4] = o[i * 3 + 1];
            v[i * 6 + 5] = o[i * 3 + 2];
          }
        }
      case CloudColorMode.height:
        // La rampa se tabula en 256 pasos: evita calcularla punto a punto.
        final lut = Float32List(256 * 3);
        for (var k = 0; k < 256; k++) {
          final c = ramp(k / 255);
          lut[k * 3] = c.$1;
          lut[k * 3 + 1] = c.$2;
          lut[k * 3 + 2] = c.$3;
        }
        for (var i = 0; i < n; i++) {
          final k = (((v[i * 6 + 2] - zMin) / span).clamp(0.0, 1.0) * 255).toInt() * 3;
          v[i * 6 + 3] = lut[k];
          v[i * 6 + 4] = lut[k + 1];
          v[i * 6 + 5] = lut[k + 2];
        }
      case CloudColorMode.intensity:
        final lo = info.intensityLo, hi = info.intensityHi;
        final iSpan = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
        final it = a?.intensity;
        for (var i = 0; i < n; i++) {
          final t = (((it?[i] ?? 0) - lo) / iSpan).clamp(0.0, 1.0);
          final k = 0.12 + 0.88 * t;
          v[i * 6 + 3] = k;
          v[i * 6 + 4] = k * 0.98;
          v[i * 6 + 5] = k * 0.94;
        }
      case CloudColorMode.classification:
        final lut = Float32List(256 * 3);
        for (var k = 0; k < 256; k++) {
          final c = asprsColor(k);
          lut[k * 3] = ((c >> 16) & 255) / 255;
          lut[k * 3 + 1] = ((c >> 8) & 255) / 255;
          lut[k * 3 + 2] = (c & 255) / 255;
        }
        final cl = a?.cls;
        for (var i = 0; i < n; i++) {
          final k = (cl?[i] ?? 0) * 3;
          v[i * 6 + 3] = lut[k];
          v[i * 6 + 4] = lut[k + 1];
          v[i * 6 + 5] = lut[k + 2];
        }
      case CloudColorMode.returns:
        final rt = a?.ret, nt = a?.nret;
        for (var i = 0; i < n; i++) {
          final rn = rt?[i] ?? 1, nr = nt?[i] ?? 1;
          double r, g, b;
          if (nr <= 1) {
            (r, g, b) = (0.86, 0.9, 0.92); // retorno único: superficie dura
          } else if (rn == 1) {
            (r, g, b) = (0.37, 0.92, 0.5); // primero de varios: copa
          } else if (rn >= nr) {
            (r, g, b) = (0.98, 0.57, 0.24); // último: lo más bajo que llegó el pulso
          } else {
            (r, g, b) = (0.38, 0.65, 0.98); // intermedios
          }
          v[i * 6 + 3] = r;
          v[i * 6 + 4] = g;
          v[i * 6 + 5] = b;
        }
      case CloudColorMode.flat:
        _fill(v, n, 0.72, 0.79, 0.8);
    }
    _full.gpu = null;
    _rebuildVisible();
  }

  static void _fill(Float32List v, int n, double r, double g, double b) {
    for (var i = 0; i < n; i++) {
      v[i * 6 + 3] = r;
      v[i * 6 + 4] = g;
      v[i * 6 + 5] = b;
    }
  }

  static (double, double, double) ramp(double t) {
    // azul → menta → amarillo → naranja
    const stops = [
      (0.0, 0.23, 0.40, 0.85),
      (0.35, 0.22, 0.83, 0.72),
      (0.68, 0.96, 0.88, 0.32),
      (1.0, 0.98, 0.50, 0.22),
    ];
    for (var k = 0; k + 1 < stops.length; k++) {
      if (t <= stops[k + 1].$1) {
        final s = (t - stops[k].$1) / (stops[k + 1].$1 - stops[k].$1);
        return (
          stops[k].$2 + (stops[k + 1].$2 - stops[k].$2) * s,
          stops[k].$3 + (stops[k + 1].$3 - stops[k].$3) * s,
          stops[k].$4 + (stops[k + 1].$4 - stops[k].$4) * s,
        );
      }
    }
    return (stops.last.$2, stops.last.$3, stops.last.$4);
  }

  void toggleClass(int c) {
    hiddenClasses.contains(c) ? hiddenClasses.remove(c) : hiddenClasses.add(c);
    _rebuildVisible();
  }

  void setClip(double? lo, double? hi, {int? axis}) {
    if (axis != null && axis != clipAxis) {
      clipAxis = axis;
      zClipLo = zClipHi = null;
      if (lo == null && hi == null) {
        _rebuildVisible();
        return;
      }
    }
    zClipLo = lo;
    zClipHi = hi;
    _rebuildVisible();
  }

  void showAll() {
    hiddenClasses.clear();
    zClipLo = zClipHi = null;
    _rebuildVisible();
  }

  bool get filtered => hiddenClasses.isNotEmpty || zClipLo != null || zClipHi != null;

  /// Copia a un nuevo [LineSet] sólo los puntos que pasan los filtros. Como la nube está barajada,
  /// el resultado también es una muestra uniforme.
  void _rebuildVisible() {
    _edlSet = null;
    if (!filtered) {
      points = _full;
      lod = _sample(_full);
      return;
    }
    final v = _full.vertices;
    final n = v.length ~/ 6;
    final cls = attrs?.cls;
    final lo = zClipLo ?? double.negativeInfinity, hi = zClipHi ?? double.infinity;
    final keep = Float32List(v.length);
    var k = 0;
    for (var i = 0; i < n; i++) {
      final z = v[i * 6 + clipAxis];
      if (z < lo || z > hi) continue;
      if (cls != null && hiddenClasses.contains(cls[i])) continue;
      keep.setRange(k * 6, k * 6 + 6, v, i * 6);
      k++;
    }
    points = LineSet(vertices: Float32List.sublistView(keep, 0, k * 6), bounds: _full.bounds);
    lod = _sample(points);
  }

  /// Muestra de ~1,5 M de puntos para las dos pasadas del sombreado de borde en nubes grandes.
  static const int edlPoints = 1500000;
  LineSet? _edlSet;
  LineSet get edlSet => _edlSet ??= _sample(points, edlPoints);

  /// Un punto de cada k, hasta [lodPoints]: como el archivo se lee con muestreo uniforme, vale como vista previa.
  static LineSet _sample(LineSet src, [int target = lodPoints]) {
    final n = src.vertices.length ~/ 6;
    if (n <= target) return src;
    final stride = (n / target).ceil();
    final m = (n + stride - 1) ~/ stride;
    final out = Float32List(m * 6);
    final v = src.vertices;
    for (var i = 0, j = 0; i < n; i += stride, j += 6) {
      final o = i * 6;
      out[j] = v[o];
      out[j + 1] = v[o + 1];
      out[j + 2] = v[o + 2];
      out[j + 3] = v[o + 3];
      out[j + 4] = v[o + 4];
      out[j + 5] = v[o + 5];
    }
    return LineSet(vertices: out, bounds: src.bounds);
  }
}
