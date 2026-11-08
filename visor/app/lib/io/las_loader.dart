import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/cloud_info.dart';
import 'mesh_data_extra.dart';
import '../l10n/l10n.dart';

/// Lectura de LAS 1.0–1.4 (formatos de punto 0–10). Los LAZ se descomprimen antes (ver
/// `laz_glue.dart`) y llegan aquí ya como registros LAS.
const int kMaxCloudPoints = 4000000;

/// Cabecera y VLR de un archivo LAS.
class LasHeader {
  late int versionMajor, versionMinor;
  late int headerSize, pointOffset, vlrCount, pointFormat, recordLength;
  late bool compressed;
  late int globalEncoding;
  late int fileSourceId;
  late String system, software;
  late int dayOfYear, year;
  late int pointCount;
  late List<double> scale, offset, minV, maxV;
  int evlrStart = 0, evlrCount = 0;
  List<int> returnsByNumber = [];
  final vlrs = <LasVlr>[];

  /// Tamaño del registro base del formato de punto.
  int get baseLength => const [20, 28, 26, 34, 57, 63, 30, 36, 38, 59, 67][pointFormat];
}

class LasVlr {
  LasVlr(this.userId, this.recordId, this.data, {this.extended = false});
  final String userId;
  final int recordId;
  final Uint8List data;
  final bool extended;
}

String _cstr(Uint8List b, int start, int len) {
  final end = start + len;
  var e = start;
  while (e < end && e < b.length && b[e] != 0) {
    e++;
  }
  return String.fromCharCodes(b.sublist(start, e)).trim();
}

LasHeader readLasHeader(RandomAccessFile f) {
  final len = f.lengthSync();
  if (len < 227) throw FormatException(tr('El archivo es demasiado corto para ser un LAS'));
  f.setPositionSync(0);
  final hb = f.readSync(math.min(375, len));
  if (hb[0] != 0x4C || hb[1] != 0x41 || hb[2] != 0x53 || hb[3] != 0x46) {
    throw FormatException(tr('No es un archivo LAS (falta la marca «LASF»)'));
  }
  final d = ByteData.sublistView(hb);
  final h = LasHeader()
    ..fileSourceId = d.getUint16(4, Endian.little)
    ..globalEncoding = d.getUint16(6, Endian.little)
    ..versionMajor = hb[24]
    ..versionMinor = hb[25]
    ..system = _cstr(hb, 26, 32)
    ..software = _cstr(hb, 58, 32)
    ..dayOfYear = d.getUint16(90, Endian.little)
    ..year = d.getUint16(92, Endian.little)
    ..headerSize = d.getUint16(94, Endian.little)
    ..pointOffset = d.getUint32(96, Endian.little)
    ..vlrCount = d.getUint32(100, Endian.little);
  final fmt = hb[104];
  h.compressed = (fmt & 0x80) != 0 || (fmt & 0x40) != 0;
  h.pointFormat = fmt & 0x3F;
  h.recordLength = d.getUint16(105, Endian.little);
  if (h.versionMajor != 1 || h.versionMinor > 4) {
    throw FormatException(tr('Versión de LAS no admitida: {v}', {'v': '${h.versionMajor}.${h.versionMinor}'}));
  }
  if (h.pointFormat > 10) throw FormatException(tr('Formato de punto LAS {f} desconocido', {'f': h.pointFormat}));
  if (h.headerSize < 227 || h.headerSize > len) throw FormatException(tr('Cabecera LAS dañada'));
  var count = d.getUint32(107, Endian.little);
  h.returnsByNumber = [for (var k = 0; k < 5; k++) d.getUint32(111 + 4 * k, Endian.little)];
  h.scale = [d.getFloat64(131, Endian.little), d.getFloat64(139, Endian.little), d.getFloat64(147, Endian.little)];
  h.offset = [d.getFloat64(155, Endian.little), d.getFloat64(163, Endian.little), d.getFloat64(171, Endian.little)];
  h.maxV = [d.getFloat64(179, Endian.little), d.getFloat64(195, Endian.little), d.getFloat64(211, Endian.little)];
  h.minV = [d.getFloat64(187, Endian.little), d.getFloat64(203, Endian.little), d.getFloat64(219, Endian.little)];
  if (h.versionMinor >= 4 && h.headerSize >= 375 && hb.length >= 375) {
    h.evlrStart = d.getUint64(235, Endian.little);
    h.evlrCount = d.getUint32(243, Endian.little);
    final c64 = d.getUint64(247, Endian.little);
    if (c64 > 0 || count == 0) count = c64;
    h.returnsByNumber = [for (var k = 0; k < 15; k++) d.getUint64(255 + 8 * k, Endian.little)];
  }
  h.pointCount = count;
  for (final s in h.scale) {
    if (!(s.isFinite && s != 0)) throw FormatException(tr('La escala del LAS no es válida'));
  }
  // VLR
  var pos = h.headerSize;
  for (var i = 0; i < h.vlrCount; i++) {
    if (pos + 54 > len) break;
    f.setPositionSync(pos);
    final vb = f.readSync(54);
    if (vb.length < 54) break;
    final recLen = ByteData.sublistView(vb).getUint16(20, Endian.little);
    if (pos + 54 + recLen > len || pos + 54 + recLen > h.pointOffset) break;
    f.setPositionSync(pos + 54);
    h.vlrs.add(LasVlr(_cstr(vb, 2, 16), ByteData.sublistView(vb).getUint16(18, Endian.little), f.readSync(recLen)));
    pos += 54 + recLen;
  }
  // EVLR (LAS 1.4: aquí suele ir el WKT)
  if (h.evlrStart > 0 && h.evlrCount > 0 && h.evlrCount < 100000) {
    var ep = h.evlrStart;
    for (var i = 0; i < h.evlrCount; i++) {
      if (ep + 60 > len) break;
      f.setPositionSync(ep);
      final eb = f.readSync(60);
      if (eb.length < 60) break;
      final ed = ByteData.sublistView(eb);
      final recLen = ed.getUint64(20, Endian.little);
      if (recLen > (8 << 20) || ep + 60 + recLen > len) break;
      f.setPositionSync(ep + 60);
      h.vlrs.add(LasVlr(_cstr(eb, 2, 16), ed.getUint16(18, Endian.little), f.readSync(recLen), extended: true));
      ep += 60 + recLen;
    }
  }
  return h;
}

/// Sistema de coordenadas a partir de GeoKeys (34735) o WKT (2112/2111).
void readCrs(LasHeader h, CloudInfo info) {
  int? epsg;
  int? projected, geogKey, modelType;
  int? unitCode;
  var geographic = false;
  String? wkt;
  for (final v in h.vlrs) {
    if (v.userId != 'LASF_Projection') continue;
    if (v.recordId == 34735 && v.data.length >= 8) {
      final d = ByteData.sublistView(v.data);
      final n = d.getUint16(6, Endian.little);
      for (var k = 0; k < n && 8 + 8 * k + 8 <= v.data.length; k++) {
        final o = 8 + 8 * k;
        final key = d.getUint16(o, Endian.little), loc = d.getUint16(o + 2, Endian.little);
        final value = d.getUint16(o + 6, Endian.little);
        if (loc != 0) continue;
        if (key == 3072 && value != 32767 && value != 0) projected = value;
        if (key == 2048 && value != 32767 && value != 0) geogKey = value;
        if (key == 1024) modelType = value;
        if (key == 3076) unitCode = value;
      }
      epsg = projected ?? geogKey;
      geographic = projected == null && (geogKey != null || modelType == 2);
    } else if (v.recordId == 2112 || (v.recordId == 2111 && wkt == null)) {
      wkt = String.fromCharCodes(v.data.where((b) => b != 0)).trim();
    }
  }
  if (wkt != null && wkt.isNotEmpty) {
    final m = RegExp(r'^(?:COMPD_CS|COMPOUNDCRS|PROJCS|PROJCRS|GEOGCS|GEOGCRS|GEODCRS|PROJECTEDCRS)\["([^"]+)"').firstMatch(wkt);
    info.crs = m?.group(1);
    geographic = wkt.startsWith('GEOGCS') || wkt.startsWith('GEOGCRS') || wkt.startsWith('GEODCRS');
    final au = RegExp(r'AUTHORITY\["EPSG","(\d+)"\]\s*\]\s*$').firstMatch(wkt) ??
        RegExp(r'ID\["EPSG",(\d+)\]\s*\]\s*$').firstMatch(wkt);
    if (au != null) epsg = int.tryParse(au.group(1)!);
    final u = RegExp(r'(?:UNIT|LENGTHUNIT)\["([^"]+)",\s*([\d.eE+-]+)').allMatches(wkt).toList();
    if (u.isNotEmpty && !geographic) {
      final f = double.tryParse(u.last.group(2)!);
      if (f != null) {
        info.mmPerUnit = f * 1000;
        info.unit = (f - 1).abs() < 1e-9
            ? 'm'
            : ((f - 0.3048).abs() < 1e-7
                  ? 'ft'
                  : ((f - 1200 / 3937).abs() < 1e-7 ? tr('ft EE. UU.') : '×${f.toStringAsFixed(4)} m'));
      }
    }
  }
  info.epsg = epsg;
  info.geographic = geographic;
  if (epsg != null && info.crs == null) info.crs = epsgName(epsg);
  if (geographic) {
    info.unit = '°';
    info.mmPerUnit = null;
  } else if (info.mmPerUnit == null) {
    switch (unitCode) {
      case 9001:
        info.unit = 'm';
        info.mmPerUnit = 1000;
      case 9002:
        info.unit = 'ft';
        info.mmPerUnit = 304.8;
      case 9003:
        info.unit = tr('ft EE. UU.');
        info.mmPerUnit = 1000 * 1200 / 3937;
      default:
        if (epsg != null && _metricEpsg(epsg)) {
          info.unit = 'm';
          info.mmPerUnit = 1000;
        }
    }
  }
}

bool _metricEpsg(int e) =>
    (e >= 32601 && e <= 32760) ||
    (e >= 25828 && e <= 25838) ||
    (e >= 26901 && e <= 26923) ||
    (e >= 23028 && e <= 23038) ||
    (e >= 6339 && e <= 6355) ||
    e == 3857 ||
    e == 2154 ||
    e == 27700 ||
    e == 28992 ||
    e == 3035 ||
    e == 3067;

/// Nombre de los EPSG más corrientes (UTM y algunos nacionales).
String epsgName(int e) {
  if (e >= 32601 && e <= 32660) return tr('WGS 84 / UTM zona {z} N', {'z': e - 32600});
  if (e >= 32701 && e <= 32760) return tr('WGS 84 / UTM zona {z} S', {'z': e - 32700});
  if (e >= 26901 && e <= 26923) return tr('NAD83 / UTM zona {z} N', {'z': e - 26900});
  if (e >= 25828 && e <= 25838) return tr('ETRS89 / UTM zona {z} N', {'z': e - 25800});
  if (e >= 23028 && e <= 23038) return tr('ED50 / UTM zona {z} N', {'z': e - 23000});
  if (e >= 6339 && e <= 6350) return tr('NAD83(2011) / UTM zona {z} N', {'z': e - 6330});
  return switch (e) {
    4326 => tr('WGS 84 (geográfico)'),
    4258 => tr('ETRS89 (geográfico)'),
    4269 => tr('NAD83 (geográfico)'),
    3857 => 'WGS 84 / Pseudo-Mercator',
    2154 => 'RGF93 / Lambert-93',
    27700 => tr('OSGB36 / Red Nacional Británica'),
    28992 => 'Amersfoort / RD New',
    3035 => tr('ETRS89 / LAEA Europa'),
    3067 => 'ETRS89 / TM35FIN',
    2263 => tr('NAD83 / Nueva York Long Island (ft EE. UU.)'),
    _ => 'EPSG:$e',
  };
}

String _formatName(int f) => switch (f) {
  0 => tr('formato 0 (posición e intensidad)'),
  1 => tr('formato 1 (con tiempo GPS)'),
  2 => tr('formato 2 (con color)'),
  3 => tr('formato 3 (tiempo GPS y color)'),
  4 => tr('formato 4 (tiempo GPS y onda)'),
  5 => tr('formato 5 (tiempo GPS, color y onda)'),
  6 => tr('formato 6 (LAS 1.4, tiempo GPS)'),
  7 => tr('formato 7 (LAS 1.4, tiempo GPS y color)'),
  8 => tr('formato 8 (LAS 1.4, color e infrarrojo)'),
  9 => tr('formato 9 (LAS 1.4, onda)'),
  _ => tr('formato 10 (LAS 1.4, color, infrarrojo y onda)'),
};

/// Lee un LAS y devuelve una muestra uniforme de hasta [maxPoints] puntos.
PointData parseLas(String path, {int maxPoints = kMaxCloudPoints}) {
  try {
    return _parseLas(path, maxPoints);
  } on FormatException {
    rethrow;
  } on Error catch (e) {
    throw FormatException(tr('El LAS está dañado o cortado ({t})', {'t': e.runtimeType}));
  }
}

PointData _parseLas(String path, int maxPoints) {
  final name = path.split('/').last;
  final f = File(path).openSync();
  try {
    final h = readLasHeader(f);
    if (h.compressed) {
      throw FormatException(tr('LAZ: este archivo está comprimido y necesita el descompresor'));
    }
    return _readPoints(f, h, name, 'LAS', maxPoints, null);
  } finally {
    f.closeSync();
  }
}

/// Núcleo común: lee registros desde [f] (LAS) o desde [source] (LAZ ya descomprimido).
PointData readLasRecords(
  LasHeader h,
  String name,
  String format,
  int maxPoints,
  int Function(Uint8List buf, int maxRecords) source,
) =>
    _readPoints(null, h, name, format, maxPoints, source);

PointData _readPoints(
  RandomAccessFile? f,
  LasHeader h,
  String name,
  String format,
  int maxPoints,
  int Function(Uint8List buf, int maxRecords)? source,
) {
  final len = f?.lengthSync() ?? 0;
  final rl = h.recordLength;
  final base = h.baseLength;
  if (rl < base) throw FormatException(tr('La longitud de registro ({rl}) es menor que la del formato {f}', {'rl': rl, 'f': h.pointFormat}));
  var total = h.pointCount;
  if (f != null) {
    final avail = (len - h.pointOffset) ~/ rl;
    if (total == 0 || total > avail) total = avail; // cabecera mentirosa o archivo cortado
  }
  if (total <= 0) throw FormatException(tr('El archivo no contiene puntos'));
  final stride = math.max(1, (total / maxPoints).ceil());
  final cap = (total + stride - 1) ~/ stride;
  final fmt = h.pointFormat;
  final legacy = fmt <= 5;
  final hasGps = fmt != 0 && fmt != 2;
  final gpsOff = legacy ? 20 : 22;
  final rgbOff = switch (fmt) {
    2 => 20,
    3 || 5 => 28,
    7 || 8 || 10 => 30,
    _ => -1,
  };

  final v = Float32List(cap * 6);
  final inten = Uint16List(cap);
  final cls = Uint8List(cap);
  final ret = Uint8List(cap);
  final nret = Uint8List(cap);
  final rr = rgbOff >= 0 ? Uint16List(cap) : null;
  final gg = rgbOff >= 0 ? Uint16List(cap) : null;
  final bb = rgbOff >= 0 ? Uint16List(cap) : null;

  final sx = h.scale[0], sy = h.scale[1], sz = h.scale[2];
  final ox = h.offset[0], oy = h.offset[1], oz = h.offset[2];
  final off = Float64List(3);
  var n = 0;
  var index = 0;
  final mn = Float64List(3)..fillRange(0, 3, double.infinity);
  final mx = Float64List(3)..fillRange(0, 3, -double.infinity);
  var gpsMin = double.infinity, gpsMax = -double.infinity;
  final classHist = Int32List(256);
  final returnHist = Int32List(16);
  var imin = 65535, imax = 0;
  var badCoords = 0;
  final perChunk = math.max(1, (4 << 20) ~/ rl);
  final buf = Uint8List(perChunk * rl);
  if (f != null) f.setPositionSync(h.pointOffset);
  var remaining = total;
  // Con muestreo en un LAS sin comprimir sólo se leen tandas cortas (de [run] registros) cada
  // [stride] × [run]: el resultado es casi tan uniforme y se lee una fracción del archivo.
  final run = (f != null && stride > 1) ? 64 : 0;
  var nextRun = 0; // primer registro de la siguiente tanda
  while (remaining > 0 && n < cap) {
    final want = math.min(perChunk, remaining);
    int got;
    if (run > 0) {
      if (nextRun >= total) break;
      f!.setPositionSync(h.pointOffset + nextRun * rl);
      final take = math.min(run, total - nextRun);
      got = f.readIntoSync(buf, 0, take * rl) ~/ rl;
      nextRun += run * stride;
      remaining = total - nextRun;
    } else if (f != null) {
      got = f.readIntoSync(buf, 0, want * rl) ~/ rl;
    } else {
      got = source!(buf, want);
    }
    if (got <= 0) break;
    final d = ByteData.sublistView(buf);
    for (var k = 0; k < got && n < cap; k++, index++) {
      if (run == 0 && index % stride != 0) continue;
      final o = k * rl;
      final xi = d.getInt32(o, Endian.little), yi = d.getInt32(o + 4, Endian.little), zi = d.getInt32(o + 8, Endian.little);
      final x = xi * sx + ox, y = yi * sy + oy, z = zi * sz + oz;
      if (!(x.isFinite && y.isFinite && z.isFinite)) {
        badCoords++;
        continue;
      }
      if (n == 0) {
        if (x.abs() > 1e5) off[0] = x;
        if (y.abs() > 1e5) off[1] = y;
        if (z.abs() > 1e5) off[2] = z;
      }
      final vo = n * 6;
      v[vo] = x - off[0];
      v[vo + 1] = y - off[1];
      v[vo + 2] = z - off[2];
      if (x < mn[0]) mn[0] = x;
      if (x > mx[0]) mx[0] = x;
      if (y < mn[1]) mn[1] = y;
      if (y > mx[1]) mx[1] = y;
      if (z < mn[2]) mn[2] = z;
      if (z > mx[2]) mx[2] = z;
      final it = d.getUint16(o + 12, Endian.little);
      inten[n] = it;
      if (it < imin) imin = it;
      if (it > imax) imax = it;
      int rn, nr, c;
      if (legacy) {
        final b = buf[o + 14];
        rn = b & 7;
        nr = (b >> 3) & 7;
        c = buf[o + 15] & 31;
      } else {
        final b = buf[o + 14];
        rn = b & 15;
        nr = b >> 4;
        c = buf[o + 16];
      }
      ret[n] = rn;
      nret[n] = nr;
      cls[n] = c;
      classHist[c]++;
      returnHist[rn & 15]++;
      if (hasGps) {
        final t = d.getFloat64(o + gpsOff, Endian.little);
        if (t.isFinite) {
          if (t < gpsMin) gpsMin = t;
          if (t > gpsMax) gpsMax = t;
        }
      }
      if (rgbOff >= 0) {
        rr![n] = d.getUint16(o + rgbOff, Endian.little);
        gg![n] = d.getUint16(o + rgbOff + 2, Endian.little);
        bb![n] = d.getUint16(o + rgbOff + 4, Endian.little);
      }
      n++;
    }
    if (run == 0) remaining -= got;
  }
  if (n == 0) throw FormatException(tr('El archivo no contiene puntos válidos'));

  // Color: muchos escáneres guardan 8 bits dentro de un campo de 16.
  var hasRgb = false;
  if (rr != null) {
    var m = 0;
    for (var i = 0; i < n; i++) {
      m = math.max(m, math.max(rr[i], math.max(gg![i], bb![i])));
    }
    hasRgb = m > 0;
    final div = m <= 255 ? 255.0 : 65535.0;
    if (hasRgb) {
      for (var i = 0; i < n; i++) {
        v[i * 6 + 3] = rr[i] / div;
        v[i * 6 + 4] = gg![i] / div;
        v[i * 6 + 5] = bb![i] / div;
      }
    }
  }
  if (!hasRgb) {
    for (var i = 0; i < n; i++) {
      v[i * 6 + 3] = 0.72;
      v[i * 6 + 4] = 0.79;
      v[i * 6 + 5] = 0.8;
    }
  }

  final isCopc = h.vlrs.any((e) => e.userId == 'copc' && e.recordId == 1);
  final info = CloudInfo('${isCopc ? 'COPC' : format} ${h.versionMajor}.${h.versionMinor}')
    ..totalPoints = total
    ..shownPoints = n
    ..pointFormat = _formatName(fmt)
    ..scale = h.scale
    ..software = h.software.isEmpty ? null : h.software
    ..system = h.system.isEmpty ? null : h.system
    ..hasRgb = hasRgb
    ..hasGps = hasGps
    ..vlrCount = h.vlrs.where((e) => !e.extended).length
    ..extraBytes = rl - base;
  if (h.year > 1980 && h.year < 2200 && h.dayOfYear >= 1 && h.dayOfYear <= 366) {
    final dt = DateTime.utc(h.year).add(Duration(days: h.dayOfYear - 1));
    info.date = '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }
  final classCounts = <int, int>{
    for (var k = 0; k < 256; k++)
      if (classHist[k] > 0) k: classHist[k],
  };
  final returnCounts = <int, int>{
    for (var k = 0; k < 16; k++)
      if (returnHist[k] > 0) k: returnHist[k],
  };
  info.classCounts.addAll(classCounts);
  info.returnCounts.addAll(returnCounts);
  info.hasIntensity = imax > 0;
  info.hasClass = classCounts.keys.any((c) => c != 0) || classCounts.length > 1;
  info.hasReturns = returnCounts.keys.any((r) => r > 1) || returnHist.isNotEmpty && nret.take(n).any((r) => r > 1);
  info.gpsMin = gpsMin.isFinite ? gpsMin : null;
  info.gpsMax = gpsMax.isFinite ? gpsMax : null;
  info.intensityMin = imin;
  info.intensityMax = imax;
  final inten2 = Uint16List.sublistView(inten, 0, n);
  if (info.hasIntensity) stretchIntensity(info, inten2);
  info.minAbs = mn.toList();
  info.maxAbs = mx.toList();
  readCrs(h, info);
  if (info.mmPerUnit == null && !info.geographic) {
    info.warn(info.crs == null
        ? tr('El archivo no indica su sistema de coordenadas ni sus unidades: se suponen metros.')
        : tr('El archivo no indica la unidad de longitud de su sistema de coordenadas: se suponen metros.'));
    info.unit = 'm';
    info.mmPerUnit = 1000;
  }
  if (info.geographic) {
    info.warn(tr('Las coordenadas están en grados (sistema geográfico): las distancias en metros no son fiables hasta proyectarlas.'));
  }
  if (total != h.pointCount) {
    info.warn(tr('La cabecera dice {n} puntos pero el archivo sólo contiene {total}: puede estar cortado.', {'n': h.pointCount, 'total': total}));
  }
  if (badCoords > 0) info.warn(tr('{n} puntos con coordenadas no válidas se han descartado.', {'n': badCoords}));
  if (h.minV[0] > h.maxV[0] || (h.minV[0] == 0 && h.maxV[0] == 0)) {
    info.warn(tr('La caja de la cabecera no es válida; se ha calculado de los puntos.'));
  } else {
    // La caja de la cabecera debe contener los puntos (con holgura de una unidad de escala).
    final tol = [sx, sy, sz].reduce(math.max) * 2 + 1e-9;
    var bad = false;
    for (var k = 0; k < 3; k++) {
      if (mn[k] < h.minV[k] - tol || mx[k] > h.maxV[k] + tol) bad = true;
    }
    if (bad) info.warn(tr('La caja de la cabecera no coincide con los puntos (cabecera desactualizada).'));
  }
  if (stride > 1) {
    info.warn(tr('Se muestra una de cada {n} puntos (muestra uniforme) para que la vista sea fluida.', {'n': stride}));
  }
  info.density = _density(mn.toList(), mx.toList(), v, n, total, off.toList(), info);

  final v2 = Float32List.sublistView(v, 0, n * 6);
  final cls2 = Uint8List.sublistView(cls, 0, n), ret2 = Uint8List.sublistView(ret, 0, n), nret2 = Uint8List.sublistView(nret, 0, n);
  return PointData(
    name,
    v2,
    [for (var k = 0; k < 3; k++) mn[k] - off[k]],
    [for (var k = 0; k < 3; k++) mx[k] - off[k]],
    hasRgb,
    intensity: info.hasIntensity ? inten2 : null,
    cls: info.hasClass ? cls2 : null,
    ret: info.hasReturns ? ret2 : null,
    nret: info.hasReturns ? nret2 : null,
    info: info,
    origin: off.toList(),
  );
}

/// Densidad media en puntos por m² sobre las celdas ocupadas (sólo si se conoce la unidad).
double? _density(List<double> mn, List<double> mx, Float32List v, int n, int total, List<double> off, CloudInfo info) {
  final u = info.mmPerUnit;
  if (u == null || info.geographic) return null;
  final w = mx[0] - mn[0], h = mx[1] - mn[1];
  if (!(w > 0 && h > 0 && w.isFinite && h.isFinite)) return null;
  const g = 160;
  final cell = math.max(w, h) / g;
  final cols = (w / cell).ceil() + 1, rows = (h / cell).ceil() + 1;
  final seen = Uint8List(cols * rows);
  var occ = 0;
  for (var i = 0; i < n; i++) {
    final cx = ((v[i * 6] + off[0] - mn[0]) / cell).floor().clamp(0, cols - 1);
    final cy = ((v[i * 6 + 1] + off[1] - mn[1]) / cell).floor().clamp(0, rows - 1);
    final k = cy * cols + cx;
    if (seen[k] == 0) {
      seen[k] = 1;
      occ++;
    }
  }
  if (occ == 0) return null;
  final cellM = cell * u / 1000;
  return total / (occ * cellM * cellM);
}
