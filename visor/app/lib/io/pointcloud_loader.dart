import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../l10n/l10n.dart';
import 'mesh_data_extra.dart';

/// Lee nubes de puntos de texto: XYZ, PTS (Leica) y las variantes con color o intensidad.
PointData parseXyz(String path) {
  try {
    return _parseXyz(path);
  } on FormatException {
    rethrow;
  } on Error catch (e) {
    throw FormatException(tr('El archivo de nube está dañado o no tiene el formato esperado ({t})', {'t': e.runtimeType}));
  }
}

PointData _parseXyz(String path) {
  final name = path.split('/').last;
  final pb = PointBuilder();
  final text = utf8.decode(File(path).readAsBytesSync(), allowMalformed: true);
  final isPts = name.toLowerCase().endsWith('.pts');
  var first = true;
  var layout =
      -1; // 0: xyz, 1: xyz+color, 2: xyz+intensidad, 3: xyz+intensidad+color
  var sampleChecked = 0;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) continue;
    final p = line.split(RegExp(r'[\s,;]+'));
    if (first) {
      first = false;
      // PTS: la primera línea suele ser el número de puntos.
      if (isPts && p.length == 1 && int.tryParse(p[0]) != null) continue;
    }
    if (p.length < 3) continue;
    final x = double.tryParse(p[0]),
        y = double.tryParse(p[1]),
        z = double.tryParse(p[2]);
    if (x == null || y == null || z == null) continue;
    if (layout < 0) {
      final c = p.length;
      if (isPts) {
        layout = c >= 7 ? 3 : (c == 6 ? 1 : (c >= 4 ? 2 : 0));
      } else {
        // XYZ: con 6 columnas puede ser color (0–255) o normales (−1…1).
        if (c >= 6) {
          final a = double.tryParse(p[3]) ?? 0,
              b = double.tryParse(p[4]) ?? 0,
              d = double.tryParse(p[5]) ?? 0;
          layout =
              (a.abs() > 1.0001 || b.abs() > 1.0001 || d.abs() > 1.0001) &&
                  a >= 0 &&
                  b >= 0 &&
                  d >= 0
              ? 1
              : 0;
        } else {
          layout = 0;
        }
      }
      sampleChecked++;
    }
    switch (layout) {
      case 1:
        final r = (double.tryParse(p[3]) ?? 180) / 255,
            g = (double.tryParse(p[4]) ?? 180) / 255,
            b = (double.tryParse(p[5]) ?? 180) / 255;
        pb.hasColor = true;
        pb.add(
          x,
          y,
          z,
          r.clamp(0.0, 1.0),
          g.clamp(0.0, 1.0),
          b.clamp(0.0, 1.0),
        );
      case 2:
        final i = ((double.tryParse(p[3]) ?? 0) / (isPts ? 2048 : 255))
            .abs()
            .clamp(0.0, 1.0)
            .toDouble();
        pb.hasColor = true;
        final v = 0.15 + 0.85 * i;
        pb.add(x, y, z, v, v, v);
      case 3:
        final r = (double.tryParse(p[4]) ?? 180) / 255,
            g = (double.tryParse(p[5]) ?? 180) / 255,
            b = (double.tryParse(p[6]) ?? 180) / 255;
        pb.hasColor = true;
        pb.add(
          x,
          y,
          z,
          r.clamp(0.0, 1.0),
          g.clamp(0.0, 1.0),
          b.clamp(0.0, 1.0),
        );
      default:
        pb.add(x, y, z);
    }
  }
  sampleChecked;
  return pb.build(name, format: isPts ? 'PTS' : 'XYZ');
}

/// Descomprime LZF (libLZF) a un búfer de `outLen` bytes.
Uint8List _lzfDecompress(Uint8List src, int start, int end, int outLen) {
  final out = Uint8List(outLen);
  var i = start, o = 0;
  while (i < end && o < outLen) {
    final ctrl = src[i++];
    if (ctrl < 32) {
      final n = ctrl + 1;
      if (i + n > end || o + n > outLen) throw Exception(tr('LZF corrupto'));
      out.setRange(o, o + n, src, i);
      i += n;
      o += n;
    } else {
      var len = ctrl >> 5;
      if (len == 7) len += src[i++];
      final ref = o - ((ctrl & 0x1f) << 8) - 1 - src[i++];
      len += 2;
      if (ref < 0 || o + len > outLen) throw Exception(tr('LZF corrupto'));
      for (var k = 0; k < len; k++) {
        out[o++] = out[ref + k];
      }
    }
  }
  if (o != outLen) throw Exception(tr('LZF: tamaño inesperado'));
  return out;
}

/// binary_compressed: LZF y datos por columnas -> filas intercaladas.
Uint8List _pcdUnpack(
  Uint8List bytes,
  int pos,
  List<int> sizes,
  List<int> counts,
  int points,
) {
  final hd = ByteData.sublistView(bytes, pos, pos + 8);
  final csize = hd.getUint32(0, Endian.little);
  final usize = hd.getUint32(4, Endian.little);
  final cols = _lzfDecompress(bytes, pos + 8, pos + 8 + csize, usize);
  final stride = [
    for (var i = 0; i < sizes.length; i++) sizes[i] * counts[i],
  ].fold<int>(0, (a, b) => a + b);
  final rows = Uint8List(stride * points);
  var src = 0, fieldOff = 0;
  for (var f = 0; f < sizes.length; f++) {
    final w = sizes[f] * counts[f];
    for (var p = 0; p < points; p++) {
      rows.setRange(
        p * stride + fieldOff,
        p * stride + fieldOff + w,
        cols,
        src,
      );
      src += w;
    }
    fieldOff += w;
  }
  return rows;
}

/// PCD (Point Cloud Library): ASCII, binario y binary_compressed (LZF).
PointData parsePcd(String path) {
  try {
    return _parsePcd(path);
  } on FormatException {
    rethrow;
  } on Error catch (e) {
    throw FormatException(tr('El PCD está dañado o cortado ({t})', {'t': e.runtimeType}));
  }
}

PointData _parsePcd(String path) {
  final name = path.split('/').last;
  final bytes = File(path).readAsBytesSync();
  // Cabecera hasta la línea DATA.
  var pos = 0;
  final header = <String>[];
  while (pos < bytes.length) {
    var e = pos;
    while (e < bytes.length && bytes[e] != 10) {
      e++;
    }
    final line = String.fromCharCodes(bytes, pos, e).trim();
    pos = e + 1;
    header.add(line);
    if (line.startsWith('DATA')) break;
  }
  String? val(String key) {
    for (final h in header) {
      if (h.startsWith('$key ')) return h.substring(key.length + 1).trim();
    }
    return null;
  }

  final fields = val('FIELDS')?.split(RegExp(r'\s+')) ?? [];
  final sizes = (val('SIZE')?.split(RegExp(r'\s+')) ?? [])
      .map(int.parse)
      .toList();
  final types = val('TYPE')?.split(RegExp(r'\s+')) ?? [];
  final counts =
      (val('COUNT')?.split(RegExp(r'\s+')) ?? List.filled(fields.length, '1'))
          .map(int.parse)
          .toList();
  final points = int.parse(val('POINTS') ?? val('WIDTH') ?? '0');
  final data = (val('DATA') ?? 'ascii').toLowerCase();
  if (fields.isEmpty || fields.length != sizes.length)
    throw FormatException(tr('Cabecera PCD no válida'));
  Uint8List? unpacked;
  if (data == 'binary_compressed') {
    unpacked = _pcdUnpack(bytes, pos, sizes, counts, points);
  } else if (data.contains('compressed')) {
    throw Exception(tr('Variante de PCD comprimido no reconocida: {d}', {'d': data}));
  }
  final pb = PointBuilder();
  final ix = fields.indexOf('x'),
      iy = fields.indexOf('y'),
      iz = fields.indexOf('z');
  if (ix < 0 || iy < 0 || iz < 0)
    throw FormatException(tr('El PCD no tiene campos x, y, z'));
  final irgb = fields.contains('rgb')
      ? fields.indexOf('rgb')
      : (fields.contains('rgba') ? fields.indexOf('rgba') : -1);

  if (data == 'ascii') {
    final text = utf8.decode(bytes.sublist(pos), allowMalformed: true);
    // columnas por campo
    final col = <int>[];
    var c = 0;
    for (var i = 0; i < fields.length; i++) {
      col.add(c);
      c += counts[i];
    }
    for (final line in const LineSplitter().convert(text)) {
      final p = line.trim().split(RegExp(r'\s+'));
      if (p.length < c) continue;
      final x = double.tryParse(p[col[ix]]),
          y = double.tryParse(p[col[iy]]),
          z = double.tryParse(p[col[iz]]);
      if (x == null || y == null || z == null) continue;
      if (irgb >= 0) {
        final raw = p[col[irgb]];
        final u = raw.contains('.') || raw.contains('e')
            ? (ByteData(4)..setFloat32(0, double.parse(raw))).getUint32(0)
            : int.parse(raw);
        pb.hasColor = true;
        pb.add(
          x,
          y,
          z,
          ((u >> 16) & 255) / 255,
          ((u >> 8) & 255) / 255,
          (u & 255) / 255,
        );
      } else {
        pb.add(x, y, z);
      }
    }
  } else {
    final stride = [
      for (var i = 0; i < fields.length; i++) sizes[i] * counts[i],
    ].fold<int>(0, (a, b) => a + b);
    final offs = <int>[];
    var o = 0;
    for (var i = 0; i < fields.length; i++) {
      offs.add(o);
      o += sizes[i] * counts[i];
    }
    final bd = unpacked != null
        ? ByteData.sublistView(unpacked)
        : ByteData.sublistView(bytes, pos);
    final n = (bd.lengthInBytes ~/ stride) < points || points == 0
        ? bd.lengthInBytes ~/ stride
        : points;
    double read(int base, int field) {
      final off = base + offs[field];
      switch ('${types[field]}${sizes[field]}') {
        case 'F4':
          return bd.getFloat32(off, Endian.little);
        case 'F8':
          return bd.getFloat64(off, Endian.little);
        case 'U1':
          return bd.getUint8(off).toDouble();
        case 'U2':
          return bd.getUint16(off, Endian.little).toDouble();
        case 'U4':
          return bd.getUint32(off, Endian.little).toDouble();
        case 'I2':
          return bd.getInt16(off, Endian.little).toDouble();
        case 'I4':
          return bd.getInt32(off, Endian.little).toDouble();
      }
      return 0;
    }

    for (var i = 0; i < n; i++) {
      final base = i * stride;
      final x = read(base, ix), y = read(base, iy), z = read(base, iz);
      if (irgb >= 0) {
        final u = bd.getUint32(base + offs[irgb], Endian.little);
        pb.hasColor = true;
        pb.add(
          x,
          y,
          z,
          ((u >> 16) & 255) / 255,
          ((u >> 8) & 255) / 255,
          (u & 255) / 255,
        );
      } else {
        pb.add(x, y, z);
      }
    }
  }
  return pb.build(name, format: 'PCD');
}
