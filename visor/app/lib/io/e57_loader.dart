// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../model/cloud_info.dart';
import 'las_loader.dart' show kMaxCloudPoints;
import 'mesh_data_extra.dart';
import '../l10n/l10n.dart';

/// Lector de E57 (ASTM E2807): nubes de escáneres terrestres. Lee el XML, recorre los paquetes de
/// datos de cada `CompressedVector` y decodifica los campos empaquetados por bits.
///
/// Admite coordenadas cartesianas o esféricas, intensidad y color, estado de validez de los puntos,
/// varios escaneos con su pose y el códec estándar (bitpack).

final List<int> _crcTable = () {
  final t = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0x82F63B78 : c >> 1;
    }
    t[i] = c;
  }
  return t;
}();

int _crc32c(Uint8List b, int start, int end) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ b[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// Acceso a la parte «lógica» del archivo: páginas de [pageSize] bytes cuyos últimos 4 son su CRC.
class _Paged {
  _Paged(this.f, this.pageSize) : fileLength = f.lengthSync();
  final RandomAccessFile f;
  final int pageSize;
  final int fileLength;
  int badPages = 0;
  final _cache = <int, Uint8List>{};

  Uint8List _page(int index, bool verify) {
    final cached = _cache[index];
    if (cached != null) return cached;
    final start = index * pageSize;
    if (start + pageSize > fileLength) throw FormatException(tr('El E57 está cortado (falta una página)'));
    f.setPositionSync(start);
    final p = f.readSync(pageSize);
    if (p.length < pageSize) throw FormatException(tr('El E57 está cortado (falta una página)'));
    if (verify) {
      final crc = _crc32c(p, 0, pageSize - 4);
      final be = (p[pageSize - 4] << 24) | (p[pageSize - 3] << 16) | (p[pageSize - 2] << 8) | p[pageSize - 1];
      final le = (p[pageSize - 1] << 24) | (p[pageSize - 2] << 16) | (p[pageSize - 3] << 8) | p[pageSize - 4];
      if (crc != be && crc != le) badPages++;
    }
    if (_cache.length > 64) _cache.clear();
    _cache[index] = p;
    return p;
  }

  /// Lee [n] bytes lógicos desde un desplazamiento físico (se saltan los CRC de cada página).
  Uint8List read(int physical, int n, {bool verify = false}) {
    final out = Uint8List(n);
    var pos = physical, got = 0;
    final payload = pageSize - 4;
    while (got < n) {
      final index = pos ~/ pageSize;
      final inPage = pos % pageSize;
      if (inPage >= payload) {
        pos = (index + 1) * pageSize;
        continue;
      }
      final page = _page(index, verify);
      final take = math.min(n - got, payload - inPage);
      out.setRange(got, got + take, page, inPage);
      got += take;
      pos += take;
      if (pos % pageSize >= payload) pos = (index + 1) * pageSize;
    }
    return out;
  }
}

/// Un campo del prototipo de un `CompressedVector`.
class _Field {
  _Field(this.name, this.kind);
  final String name;
  final String kind; // Float, Integer, ScaledInteger
  bool single = false;
  double min = 0, max = 0, scale = 1, offset = 0;
  int bits = 0;
  bool hasRange = false;

  Uint8List _carry = Uint8List(0);
  int _bitPos = 0;
  Float64List vals = Float64List(0);
  int start = 0, end = 0;

  int get available => end - start;

  void _push(double v) {
    if (end == vals.length) {
      if (start > 0 && start >= vals.length ~/ 2) {
        vals.setRange(0, end - start, vals, start);
        end -= start;
        start = 0;
      } else {
        final n = Float64List(math.max(256, vals.length * 2));
        n.setRange(0, end - start, vals, start);
        end -= start;
        start = 0;
        vals = n;
      }
    }
    vals[end++] = v;
  }

  void prepare() {
    if (kind == 'Float') {
      bits = single ? 32 : 64;
    } else {
      final range = max - min;
      if (!(range >= 0) || range > 9.2e18) throw FormatException(tr('Rango del campo {name} no válido', {'name': name}));
      var r = range.toInt();
      var b = 0;
      while (r > 0) {
        b++;
        r >>= 1;
      }
      bits = b;
    }
  }

  /// Añade los bytes de un paquete y decodifica todos los valores completos.
  void feed(Uint8List chunk) {
    Uint8List data;
    var bitStart = 0;
    if (_carry.isEmpty) {
      data = chunk;
    } else {
      data = Uint8List(_carry.length + chunk.length)
        ..setAll(0, _carry)
        ..setAll(_carry.length, chunk);
      bitStart = _bitPos;
    }
    final totalBits = data.length * 8;
    var bp = bitStart;
    if (kind == 'Float') {
      final bytes = bits ~/ 8;
      final d = ByteData.sublistView(data);
      var o = bp ~/ 8;
      while (o + bytes <= data.length) {
        _push(single ? d.getFloat32(o, Endian.little) : d.getFloat64(o, Endian.little));
        o += bytes;
      }
      bp = o * 8;
    } else if (bits == 0) {
      // sin bits: el valor es siempre el mínimo; lo reparte [fillConstant]
    } else {
      while (bp + bits <= totalBits) {
        _push(((_readBits(data, bp, bits)) + min) * (kind == 'ScaledInteger' ? scale : 1) + (kind == 'ScaledInteger' ? offset : 0));
        bp += bits;
      }
    }
    // Resto de bits sin consumir para el paquete siguiente.
    final keepFrom = bp ~/ 8;
    _carry = Uint8List.fromList(data.sublist(keepFrom));
    _bitPos = bp - keepFrom * 8;
  }

  void fillConstant(int n) {
    final v = (min) * (kind == 'ScaledInteger' ? scale : 1) + (kind == 'ScaledInteger' ? offset : 0);
    for (var i = 0; i < n; i++) {
      _push(v);
    }
  }

  static double _readBits(Uint8List d, int bitPos, int w) {
    var byte = bitPos >> 3;
    final shift = bitPos & 7;
    if (w + shift <= 56) {
      var x = 0;
      final need = (w + shift + 7) >> 3;
      for (var i = 0; i < need; i++) {
        x |= d[byte + i] << (8 * i);
      }
      return ((x >> shift) & ((1 << w) - 1)).toDouble();
    }
    var x = BigInt.zero;
    final need = (w + shift + 7) >> 3;
    for (var i = 0; i < need && byte + i < d.length; i++) {
      x |= BigInt.from(d[byte + i]) << (8 * i);
    }
    return ((x >> shift) & ((BigInt.one << w) - BigInt.one)).toDouble();
  }
}

class _Scan {
  _Scan(this.name);
  final String name;
  int fileOffset = 0, records = 0;
  final fields = <_Field>[];
  double? iLo, iHi;
  final colorLo = [0.0, 0.0, 0.0], colorHi = [255.0, 255.0, 255.0];
  List<double>? q; // w x y z
  List<double>? t; // x y z
  bool unsupportedCodec = false;
}

double? _num(XmlElement? e) {
  if (e == null) return null;
  final t = e.innerText.trim();
  if (t.isEmpty) return 0;
  return double.tryParse(t);
}

double? _attr(XmlElement e, String n) {
  final a = e.getAttribute(n);
  if (a == null) return null;
  return double.tryParse(a.trim());
}

XmlElement? _child(XmlElement e, String name) {
  for (final c in e.childElements) {
    if (c.name.local == name) return c;
  }
  return null;
}

PointData parseE57(String path, {int maxPoints = kMaxCloudPoints}) {
  try {
    return _parseE57(path, maxPoints);
  } on FormatException {
    rethrow;
  } on Error catch (e) {
    throw FormatException(tr('El E57 no se puede interpretar ({t})', {'t': e.runtimeType}));
  }
}

PointData _parseE57(String path, int maxPoints) {
  final name = path.split('/').last;
  final f = File(path).openSync();
  try {
    final len = f.lengthSync();
    if (len < 48) throw FormatException(tr('El archivo es demasiado corto para ser un E57'));
    f.setPositionSync(0);
    final hb = f.readSync(48);
    if (String.fromCharCodes(hb.sublist(0, 8)) != 'ASTM-E57') {
      throw FormatException(tr('No es un archivo E57 (falta la marca «ASTM-E57»)'));
    }
    final hd = ByteData.sublistView(hb);
    final major = hd.getUint32(8, Endian.little);
    final fileLength = hd.getUint64(16, Endian.little);
    final xmlOffset = hd.getUint64(24, Endian.little);
    final xmlLength = hd.getUint64(32, Endian.little);
    final pageSize = hd.getUint64(40, Endian.little);
    if (major != 1) throw FormatException(tr('Versión de E57 no admitida: {v}', {'v': major}));
    if (pageSize < 64 || pageSize > (1 << 20)) throw FormatException(tr('Tamaño de página del E57 no válido'));
    if (fileLength != len) {
      throw FormatException(tr('El E57 está incompleto o alterado: debería medir {a} bytes y mide {b}', {'a': fileLength, 'b': len}));
    }
    if (xmlLength == 0 || xmlLength > (64 << 20) || xmlOffset + xmlLength > len) {
      throw FormatException(tr('La sección XML del E57 no es válida'));
    }
    final pg = _Paged(f, pageSize);
    final xml = utf8.decode(pg.read(xmlOffset, xmlLength, verify: true), allowMalformed: true);
    final xmlBad = pg.badPages;
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } on XmlException catch (e) {
      throw FormatException(tr('El XML del E57 está mal formado: {m}', {'m': e.message}));
    }
    final root = doc.rootElement;
    final info = CloudInfo('E57 1.0')
      ..unit = 'm'
      ..mmPerUnit = 1000
      ..hasGps = false;
    info.software = _child(root, 'e57LibraryVersion')?.innerText.trim();
    final cm = _child(root, 'coordinateMetadata')?.innerText.trim() ?? '';
    info.crs = cm.isEmpty ? tr('Sistema local del escáner (metros)') : cm;
    if (xmlBad > 0) info.warn(tr('Hay {n} páginas con la suma de control (CRC) incorrecta: el archivo puede estar dañado.', {'n': xmlBad}));

    final scans = <_Scan>[];
    final data3d = _child(root, 'data3D');
    if (data3d == null) throw FormatException(tr('El E57 no contiene escaneos 3D (falta data3D)'));
    final images = _child(root, 'images2D')?.childElements.length ?? 0;
    for (final sc in data3d.childElements) {
      final points = _child(sc, 'points');
      if (points == null || points.getAttribute('type') != 'CompressedVector') continue;
      final s = _Scan(_child(sc, 'name')?.innerText.trim() ?? '');
      s.fileOffset = int.tryParse(points.getAttribute('fileOffset') ?? '') ?? 0;
      s.records = int.tryParse(points.getAttribute('recordCount') ?? '') ?? 0;
      final proto = _child(points, 'prototype');
      if (proto == null) continue;
      final codecs = _child(points, 'codecs');
      if (codecs != null && codecs.childElements.isNotEmpty) s.unsupportedCodec = true;
      for (final fe in proto.childElements) {
        final kind = fe.getAttribute('type') ?? '';
        if (kind != 'Float' && kind != 'Integer' && kind != 'ScaledInteger') {
          throw FormatException(tr('Tipo de campo E57 no admitido: {k}', {'k': kind}));
        }
        final fld = _Field(fe.name.local, kind);
        if (kind == 'Float') {
          fld.single = fe.getAttribute('precision') == 'single';
        } else {
          fld.min = _attr(fe, 'minimum') ?? -9.223372036854775807e18;
          fld.max = _attr(fe, 'maximum') ?? 9.223372036854775807e18;
          fld.hasRange = fe.getAttribute('minimum') != null && fe.getAttribute('maximum') != null;
          if (kind == 'ScaledInteger') {
            fld.scale = _attr(fe, 'scale') ?? 1;
            fld.offset = _attr(fe, 'offset') ?? 0;
          }
        }
        fld.prepare();
        s.fields.add(fld);
      }
      final il = _child(sc, 'intensityLimits');
      if (il != null) {
        s.iLo = _num(_child(il, 'intensityMinimum'));
        s.iHi = _num(_child(il, 'intensityMaximum'));
      }
      final cl = _child(sc, 'colorLimits');
      if (cl != null) {
        const ch = ['Red', 'Green', 'Blue'];
        for (var k = 0; k < 3; k++) {
          s.colorLo[k] = _num(_child(cl, 'color${ch[k]}Minimum')) ?? 0;
          s.colorHi[k] = _num(_child(cl, 'color${ch[k]}Maximum')) ?? 255;
        }
      }
      final pose = _child(sc, 'pose');
      if (pose != null) {
        final r = _child(pose, 'rotation'), trn = _child(pose, 'translation');
        if (r != null) {
          s.q = [
            _num(_child(r, 'w')) ?? 1,
            _num(_child(r, 'x')) ?? 0,
            _num(_child(r, 'y')) ?? 0,
            _num(_child(r, 'z')) ?? 0,
          ];
        }
        if (trn != null) s.t = [_num(_child(trn, 'x')) ?? 0, _num(_child(trn, 'y')) ?? 0, _num(_child(trn, 'z')) ?? 0];
      }
      if (info.system == null) info.system = _child(sc, 'sensorModel')?.innerText.trim();
      scans.add(s);
    }
    if (scans.isEmpty) {
      if (xmlBad > 0) throw FormatException(tr('El E57 está dañado: la suma de control (CRC) del XML no coincide'));
      throw FormatException(tr('El E57 no contiene ningún escaneo con puntos'));
    }
    final totalRecords = scans.fold<int>(0, (a, s) => a + s.records);
    if (totalRecords == 0) throw FormatException(tr('El E57 no contiene puntos'));
    if (scans.any((s) => s.unsupportedCodec)) {
      throw FormatException(tr('El E57 usa un códec de compresión que no está admitido'));
    }
    info.totalPoints = totalRecords;
    if (scans.length > 1) info.warn(tr('El archivo tiene {n} escaneos: se muestran todos juntos, cada uno con su posición.', {'n': scans.length}));
    if (images > 0) info.warn(tr('El archivo contiene {n} imágenes 2D que no se muestran.', {'n': images}));

    final stride = math.max(1, (totalRecords / maxPoints).ceil());
    final cap = (totalRecords + stride - 1) ~/ stride + scans.length;
    final v = Float32List(cap * 6);
    final inten = Uint16List(cap);
    var n = 0;
    var hasColor = false, hasInt = false;
    final mn = [double.infinity, double.infinity, double.infinity];
    final mx = [-double.infinity, -double.infinity, -double.infinity];
    final off = [0.0, 0.0, 0.0];
    var offSet = false;
    var invalid = 0;
    var globalIndex = 0;

    for (final s in scans) {
      final idx = {for (var i = 0; i < s.fields.length; i++) s.fields[i].name: i};
      final cart = idx.containsKey('cartesianX') && idx.containsKey('cartesianY') && idx.containsKey('cartesianZ');
      final sph = idx.containsKey('sphericalRange') && idx.containsKey('sphericalAzimuth') && idx.containsKey('sphericalElevation');
      if (!cart && !sph) {
        info.warn(tr('Un escaneo no trae coordenadas cartesianas ni esféricas y se ha omitido.'));
        continue;
      }
      final fx = cart ? s.fields[idx['cartesianX']!] : s.fields[idx['sphericalRange']!];
      final fy = cart ? s.fields[idx['cartesianY']!] : s.fields[idx['sphericalAzimuth']!];
      final fz = cart ? s.fields[idx['cartesianZ']!] : s.fields[idx['sphericalElevation']!];
      final fi = idx.containsKey('intensity') ? s.fields[idx['intensity']!] : null;
      final fr = idx.containsKey('colorRed') ? s.fields[idx['colorRed']!] : null;
      final fg = idx.containsKey('colorGreen') ? s.fields[idx['colorGreen']!] : null;
      final fb = idx.containsKey('colorBlue') ? s.fields[idx['colorBlue']!] : null;
      final fv = idx.containsKey('cartesianInvalidState')
          ? s.fields[idx['cartesianInvalidState']!]
          : (idx.containsKey('sphericalInvalidState') ? s.fields[idx['sphericalInvalidState']!] : null);
      final useColor = fr != null && fg != null && fb != null;
      final iLo = s.iLo ?? (fi != null && fi.hasRange ? fi.min : 0);
      final iHi = s.iHi ?? (fi != null && fi.hasRange ? fi.max : 1);

      // Sección binaria: cabecera de 32 bytes y paquetes.
      final sh = pg.read(s.fileOffset, 32);
      if (sh[0] != 1) throw FormatException(tr('Sección binaria de E57 no válida'));
      final shd = ByteData.sublistView(sh);
      final sectionLength = shd.getUint64(8, Endian.little);
      final dataOffset = shd.getUint64(16, Endian.little);
      var consumed = 0;
      var phys = dataOffset;
      var done = 0; // registros ya procesados de este escaneo
      final sectionEnd = s.fileOffset + sectionLength;
      // Se recorre el espacio físico paquete a paquete.
      int advance(int physical, int logical) {
        // Avanza `logical` bytes desde `physical` saltando los CRC.
        final payload = pageSize - 4;
        var pos = physical, left = logical;
        while (left > 0) {
          final inPage = pos % pageSize;
          if (inPage >= payload) {
            pos = (pos ~/ pageSize + 1) * pageSize;
            continue;
          }
          final take = math.min(left, payload - inPage);
          pos += take;
          left -= take;
          if (pos % pageSize >= payload) pos = (pos ~/ pageSize + 1) * pageSize;
        }
        return pos;
      }

      final zero = s.fields.where((e) => e.bits == 0 && e.kind != 'Float').toList();
      while (done < s.records) {
        if (phys >= pg.fileLength) break;
        final ph = pg.read(phys, 4);
        final type = ph[0];
        final plen = (ph[2] | (ph[3] << 8)) + 1;
        if (plen < 4 || plen > 65536) throw FormatException(tr('Paquete de E57 dañado'));
        if (type != 1) {
          phys = advance(phys, plen);
          if (type != 0 && type != 2) throw FormatException(tr('Tipo de paquete de E57 desconocido'));
          continue;
        }
        final body = pg.read(phys, plen);
        final bd = ByteData.sublistView(body);
        final count = bd.getUint16(4, Endian.little);
        if (count != s.fields.length) throw FormatException(tr('El número de flujos del paquete no coincide con el prototipo'));
        var bufPos = 6 + 2 * count;
        for (var k = 0; k < count; k++) {
          final blen = bd.getUint16(6 + 2 * k, Endian.little);
          if (bufPos + blen > body.length) throw FormatException(tr('Paquete de E57 dañado'));
          s.fields[k].feed(Uint8List.sublistView(body, bufPos, bufPos + blen));
          bufPos += blen;
        }
        phys = advance(phys, plen);
        consumed += plen;
        // Registros completos disponibles (los campos de 0 bits no limitan).
        var m = 1 << 30;
        for (final fld in s.fields) {
          if (fld.bits == 0 && fld.kind != 'Float') continue;
          m = math.min(m, fld.available);
        }
        if (m == 1 << 30) m = s.records - done;
        m = math.min(m, s.records - done);
        for (final z in zero) {
          z.fillConstant(m - z.available);
        }
        for (var r = 0; r < m; r++, globalIndex++) {
          if (globalIndex % stride != 0 || n >= cap) {
            continue;
          }
          final a = fx.vals[fx.start + r], b = fy.vals[fy.start + r], c = fz.vals[fz.start + r];
          if (fv != null && fv.vals[fv.start + r] != 0) {
            invalid++;
            continue;
          }
          double x, y, z;
          if (cart) {
            x = a;
            y = b;
            z = c;
          } else {
            x = a * math.cos(c) * math.cos(b);
            y = a * math.cos(c) * math.sin(b);
            z = a * math.sin(c);
          }
          if (!(x.isFinite && y.isFinite && z.isFinite)) {
            invalid++;
            continue;
          }
          final q = s.q, t = s.t;
          if (q != null) {
            final w = q[0], qx = q[1], qy = q[2], qz = q[3];
            final nrm = math.sqrt(w * w + qx * qx + qy * qy + qz * qz);
            if (nrm > 0) {
              final ww = w / nrm, xx = qx / nrm, yy = qy / nrm, zz = qz / nrm;
              final rx = (1 - 2 * (yy * yy + zz * zz)) * x + 2 * (xx * yy - zz * ww) * y + 2 * (xx * zz + yy * ww) * z;
              final ry = 2 * (xx * yy + zz * ww) * x + (1 - 2 * (xx * xx + zz * zz)) * y + 2 * (yy * zz - xx * ww) * z;
              final rz = 2 * (xx * zz - yy * ww) * x + 2 * (yy * zz + xx * ww) * y + (1 - 2 * (xx * xx + yy * yy)) * z;
              x = rx;
              y = ry;
              z = rz;
            }
          }
          if (t != null) {
            x += t[0];
            y += t[1];
            z += t[2];
          }
          if (!offSet) {
            offSet = true;
            if (x.abs() > 1e5) off[0] = x;
            if (y.abs() > 1e5) off[1] = y;
            if (z.abs() > 1e5) off[2] = z;
          }
          final o = n * 6;
          v[o] = x - off[0];
          v[o + 1] = y - off[1];
          v[o + 2] = z - off[2];
          if (x < mn[0]) mn[0] = x;
          if (x > mx[0]) mx[0] = x;
          if (y < mn[1]) mn[1] = y;
          if (y > mx[1]) mx[1] = y;
          if (z < mn[2]) mn[2] = z;
          if (z > mx[2]) mx[2] = z;
          if (useColor) {
            hasColor = true;
            double ch(_Field fl, int k) {
              final span = s.colorHi[k] - s.colorLo[k];
              return ((fl.vals[fl.start + r] - s.colorLo[k]) / (span == 0 ? 1 : span)).clamp(0.0, 1.0);
            }

            v[o + 3] = ch(fr, 0);
            v[o + 4] = ch(fg, 1);
            v[o + 5] = ch(fb, 2);
          } else {
            v[o + 3] = 0.72;
            v[o + 4] = 0.79;
            v[o + 5] = 0.8;
          }
          if (fi != null) {
            hasInt = true;
            final span = iHi - iLo;
            inten[n] = (((fi.vals[fi.start + r] - iLo) / (span == 0 ? 1 : span)).clamp(0.0, 1.0) * 65535).round();
          }
          n++;
        }
        for (final fld in s.fields) {
          if (fld.bits == 0 && fld.kind != 'Float') {
            fld.start = fld.end = 0;
          } else {
            fld.start += m;
          }
        }
        done += m;
        if (consumed > sectionLength + 65536 && phys > sectionEnd + pageSize) break;
      }
      if (done < s.records) {
        info.warn(tr('Un escaneo declara {n} puntos pero sólo se han podido leer {done}: el archivo puede estar cortado.', {'n': s.records, 'done': done}));
      }
    }
    if (n == 0) throw FormatException(tr('El E57 no contiene puntos válidos'));
    if (invalid > 0) info.warn(tr('{n} puntos marcados como no válidos por el escáner se han omitido.', {'n': invalid}));
    if (stride > 1) info.warn(tr('Se muestra una de cada {n} puntos (muestra uniforme) para que la vista sea fluida.', {'n': stride}));
    info
      ..shownPoints = n
      ..hasRgb = hasColor
      ..hasIntensity = hasInt
      ..minAbs = mn
      ..maxAbs = mx;
    final v2 = Float32List.sublistView(v, 0, n * 6);
    final i2 = Uint16List.sublistView(inten, 0, n);
    if (hasInt) {
      var m = 0;
      for (var i = 0; i < n; i++) {
        if (i2[i] > m) m = i2[i];
      }
      info.intensityMax = m;
      stretchIntensity(info, i2);
    }
    return PointData(
      name,
      v2,
      [for (var k = 0; k < 3; k++) mn[k] - off[k]],
      [for (var k = 0; k < 3; k++) mx[k] - off[k]],
      hasColor,
      intensity: hasInt ? i2 : null,
      info: info,
      origin: off,
    );
  } finally {
    f.closeSync();
  }
}
