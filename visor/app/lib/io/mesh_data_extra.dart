import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/cloud_info.dart';
import '../l10n/l10n.dart';

/// Nube de puntos transportable entre isolates: x y z r g b por punto, restados a [origin],
/// más atributos opcionales (intensidad, clase, retornos) en el mismo orden.
class PointData {
  PointData(
    this.name,
    Float32List verts,
    this.min,
    this.max,
    this.hasColor, {
    Uint16List? intensity,
    Uint8List? cls,
    Uint8List? ret,
    Uint8List? nret,
    CloudInfo? info,
    List<double>? origin,
  }) : _data = TransferableTypedData.fromList([verts]),
       _i = intensity == null ? null : TransferableTypedData.fromList([intensity]),
       _c = cls == null ? null : TransferableTypedData.fromList([cls]),
       _r = ret == null ? null : TransferableTypedData.fromList([ret]),
       _n = nret == null ? null : TransferableTypedData.fromList([nret]),
       info = info ?? CloudInfo(tr('Nube')),
       origin = origin ?? [0, 0, 0];
  final String name;
  final TransferableTypedData _data;
  final TransferableTypedData? _i, _c, _r, _n;
  final List<double> min, max;
  final bool hasColor;
  final CloudInfo info;
  final List<double> origin;

  Float32List get verts => _data.materialize().asFloat32List();
  Uint16List? get intensity => _i?.materialize().asUint16List();
  Uint8List? get cls => _c?.materialize().asUint8List();
  Uint8List? get ret => _r?.materialize().asUint8List();
  Uint8List? get nret => _n?.materialize().asUint8List();
}

/// Acumulador de puntos con límite (diezma si el archivo trae demasiados).
class PointBuilder {
  PointBuilder({this.maxPoints = 6000000});
  final int maxPoints;
  Float32List _a = Float32List(6 * 1024);
  Uint16List? _i;
  int _n = 0;
  bool hasColor = false;
  final min = [double.infinity, double.infinity, double.infinity];
  final max = [-double.infinity, -double.infinity, -double.infinity];
  int skipped = 0;
  final _off = [0.0, 0.0, 0.0];

  int get count => _n;

  void add(
    double x,
    double y,
    double z, [
    double r = 0.72,
    double g = 0.79,
    double b = 0.8,
    int? intensity,
  ]) {
    if (!(x.isFinite && y.isFinite && z.isFinite)) return;
    if (_n >= maxPoints) {
      skipped++;
      return;
    }
    if ((_n + 1) * 6 > _a.length) {
      final nb = Float32List(_a.length * 2);
      nb.setAll(0, _a);
      _a = nb;
      final oi = _i;
      if (oi != null) {
        final ni = Uint16List(_a.length ~/ 6);
        ni.setAll(0, oi);
        _i = ni;
      }
    }
    if (intensity != null) _i ??= Uint16List(_a.length ~/ 6);
    if (_n == 0) {
      // Coordenadas de mapa (UTM, etc.): se guardan relativas al primer punto para conservar precisión.
      if (x.abs() > 1e5) _off[0] = x;
      if (y.abs() > 1e5) _off[1] = y;
      if (z.abs() > 1e5) _off[2] = z;
    }
    final o = _n * 6;
    _a[o] = x - _off[0];
    _a[o + 1] = y - _off[1];
    _a[o + 2] = z - _off[2];
    _a[o + 3] = r;
    _a[o + 4] = g;
    _a[o + 5] = b;
    if (intensity != null) _i![_n] = intensity.clamp(0, 65535);
    _n++;
    if (x < min[0]) min[0] = x;
    if (x > max[0]) max[0] = x;
    if (y < min[1]) min[1] = y;
    if (y > max[1]) max[1] = y;
    if (z < min[2]) min[2] = z;
    if (z > max[2]) max[2] = z;
  }

  /// Termina la nube: resta el origen (para no perder precisión en coordenadas de mapa), baraja y
  /// calcula el intervalo de intensidad.
  PointData build(String name, {String? format, int? totalInFile}) {
    if (_n == 0) throw FormatException(tr('El archivo no contiene puntos'));
    final off = _off;
    final v = Float32List.sublistView(_a, 0, _n * 6);
    final inten = _i == null ? null : Uint16List.sublistView(_i!, 0, _n);
    final info = CloudInfo(format ?? tr('Nube'))
      ..totalPoints = (totalInFile ?? _n + skipped)
      ..shownPoints = _n
      ..hasRgb = hasColor
      ..minAbs = [min[0], min[1], min[2]]
      ..maxAbs = [max[0], max[1], max[2]];
    if (inten != null) {
      info.hasIntensity = true;
      _stretch(info, inten);
    }
    if (skipped > 0) info.warn(tr('El archivo tiene más puntos de los que se muestran: se ha tomado una muestra uniforme.'));
    return PointData(
      name,
      v,
      [for (var k = 0; k < 3; k++) min[k] - off[k]],
      [for (var k = 0; k < 3; k++) max[k] - off[k]],
      hasColor,
      intensity: inten,
      info: info,
      origin: off,
    );
  }
}

/// Fija el intervalo de intensidad entre los percentiles 2 y 98 de una muestra.
void _stretch(CloudInfo info, Uint16List inten) {
  final n = inten.length;
  final step = math.max(1, n ~/ 50000);
  final sample = <int>[for (var i = 0; i < n; i += step) inten[i]]..sort();
  var mn = 65535, mx = 0;
  for (var i = 0; i < n; i++) {
    if (inten[i] < mn) mn = inten[i];
    if (inten[i] > mx) mx = inten[i];
  }
  info.intensityMin = mn;
  info.intensityMax = mx;
  info.intensityLo = sample[(sample.length * 0.02).floor()].toDouble();
  info.intensityHi = sample[math.min(sample.length - 1, (sample.length * 0.98).floor())].toDouble();
  if (info.intensityHi <= info.intensityLo) info.intensityHi = info.intensityLo + 1;
}

/// Calcula el intervalo de intensidad de una nube ya construida (lo usan los lectores propios).
void stretchIntensity(CloudInfo info, Uint16List inten) => _stretch(info, inten);
