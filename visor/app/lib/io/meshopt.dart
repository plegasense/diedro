// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:math' as math;
import 'dart:typed_data';
import '../l10n/l10n.dart';

// Descodificador de EXT_meshopt_compression (el formato abierto de meshoptimizer, licencia MIT):
// atributos de vértice con deltas por bloques, índices de triángulos con colas de aristas y
// vértices, y filtros octaédrico, de cuaternión y exponencial. Implementación propia a partir
// de la especificación del formato y del descodificador de referencia.

const _kBitsV0 = [0, 2, 4, 8];
const _kBitsV1 = [0, 1, 2, 4, 8];

/// Descomprime una vista de glTF: [mode] ATTRIBUTES, TRIANGLES o INDICES; [filter] NONE,
/// OCTAHEDRAL, QUATERNION o EXPONENTIAL. Devuelve `count * stride` bytes.
Uint8List decodeMeshopt(Uint8List src, int count, int stride, String mode, String filter) {
  switch (mode) {
    case 'ATTRIBUTES':
      final out = _decodeVertices(src, count, stride);
      _applyFilter(out, count, stride, filter);
      return out;
    case 'TRIANGLES':
      return _decodeTriangles(src, count, stride);
    case 'INDICES':
      return _decodeSequence(src, count, stride);
  }
  throw FormatException(tr('Modo meshopt desconocido: {mode}', {'mode': mode}));
}

// ---------------------------------------------------------------- vértices

Uint8List _decodeVertices(Uint8List src, int count, int vsize) {
  if (vsize <= 0 || vsize > 256 || vsize % 4 != 0) {
    throw FormatException(tr('Tamaño de vértice meshopt no válido'));
  }
  if (src.isEmpty) throw FormatException(tr('Datos meshopt vacíos'));
  final header = src[0];
  if ((header & 0xF0) != 0xA0) throw FormatException(tr('Cabecera meshopt de vértices no válida'));
  final version = header & 0x0F;
  if (version > 1) throw FormatException(tr('Versión meshopt de vértices no soportada'));
  final tailSize = vsize + (version == 0 ? 0 : vsize ~/ 4);
  final tailMin = version == 0 ? 32 : 24;
  final tailPad = tailSize < tailMin ? tailMin : tailSize;
  if (src.length - 1 < tailPad) throw FormatException(tr('Datos meshopt truncados'));
  final tail = src.length - tailSize;
  final last = Uint8List.fromList(Uint8List.sublistView(src, tail, tail + vsize));
  final channels = version == 0 ? null : Uint8List.sublistView(src, tail + vsize, tail + tailSize);
  final blockSize = math.min((8192 ~/ vsize) & ~15, 256);
  final out = Uint8List(count * vsize);
  var data = 1;
  var off = 0;
  final buffer = Uint8List(256 * 4 + 32);
  final transposed = Uint8List(8192 + 256);
  while (off < count) {
    final n = off + blockSize < count ? blockSize : count - off;
    data = _vertexBlock(src, data, out, off, n, vsize, last, channels, version, buffer, transposed);
    off += n;
  }
  if (src.length - data != tailPad) throw FormatException(tr('Datos meshopt dañados'));
  return out;
}

int _vertexBlock(
  Uint8List src,
  int data0,
  Uint8List out,
  int off,
  int n,
  int vsize,
  Uint8List last,
  Uint8List? channels,
  int version,
  Uint8List buffer,
  Uint8List transposed,
) {
  var data = data0;
  final end = src.length;
  final aligned = (n + 15) & ~15;
  final controlSize = version == 0 ? 0 : vsize ~/ 4;
  if (end - data < controlSize) throw FormatException(tr('Datos meshopt truncados'));
  final control = data;
  data += controlSize;
  for (var k = 0; k < vsize; k += 4) {
    final ctrlByte = version == 0 ? 0 : src[control + k ~/ 4];
    for (var j = 0; j < 4; j++) {
      final ctrl = (ctrlByte >> (j * 2)) & 3;
      if (ctrl == 3) {
        if (end - data < n) throw FormatException(tr('Datos meshopt truncados'));
        buffer.setRange(j * n, j * n + n, src, data);
        data += n;
      } else if (ctrl == 2) {
        for (var i = 0; i < n; i++) {
          buffer[j * n + i] = 0;
        }
      } else {
        data = _decodeBytes(src, data, end, buffer, j * n, aligned, version == 0 ? _kBitsV0 : _kBitsV1.sublist(ctrl, ctrl + 4));
      }
    }
    final channel = version == 0 ? 0 : channels![k ~/ 4];
    switch (channel & 3) {
      case 0:
        _deltas(buffer, transposed, k, n, vsize, last, k, 1, false, 0);
      case 1:
        _deltas(buffer, transposed, k, n, vsize, last, k, 2, false, 0);
      case 2:
        _deltas(buffer, transposed, k, n, vsize, last, k, 4, true, (32 - (channel >> 4)) & 31);
      default:
        throw FormatException(tr('Canal meshopt no válido'));
    }
  }
  out.setRange(off * vsize, (off + n) * vsize, transposed);
  last.setRange(0, vsize, transposed, vsize * (n - 1));
  return data;
}

int _decodeBytes(Uint8List src, int data0, int end, Uint8List buf, int bufOff, int size, List<int> bits) {
  var data = data0;
  final headerSize = (size ~/ 16 + 3) ~/ 4;
  if (end - data < headerSize) throw FormatException(tr('Datos meshopt truncados'));
  final header = data;
  data += headerSize;
  for (var i = 0; i < size; i += 16) {
    if (end - data < 24) throw FormatException(tr('Datos meshopt truncados'));
    final ho = i ~/ 16;
    final bk = (src[header + ho ~/ 4] >> ((ho % 4) * 2)) & 3;
    data = _group(src, data, buf, bufOff + i, bits[bk]);
  }
  return data;
}

int _group(Uint8List src, int data, Uint8List buf, int o, int bits) {
  switch (bits) {
    case 0:
      for (var i = 0; i < 16; i++) {
        buf[o + i] = 0;
      }
      return data;
    case 8:
      buf.setRange(o, o + 16, src, data);
      return data + 16;
  }
  final perByte = 8 ~/ bits;
  final headerBytes = 16 ~/ perByte;
  var dv = data + headerBytes; // datos variables tras los bytes de cabecera
  final mask = (1 << bits) - 1;
  var w = o;
  for (var h = 0; h < headerBytes; h++) {
    var byte = src[data + h];
    if (bits == 1) {
      // en el grupo de 1 bit el orden de los bits va invertido
      var r = 0;
      for (var b = 0; b < 8; b++) {
        r |= ((byte >> b) & 1) << (7 - b);
      }
      byte = r;
    }
    for (var q = 0; q < perByte; q++) {
      final enc = (byte >> (8 - bits)) & mask;
      byte = (byte << bits) & 0xFF;
      if (enc == mask) {
        buf[w++] = src[dv++];
      } else {
        buf[w++] = enc;
      }
    }
  }
  return dv;
}

void _deltas(
  Uint8List buffer,
  Uint8List transposed,
  int k,
  int n,
  int vsize,
  Uint8List last,
  int lastOff,
  int tsize,
  bool xor,
  int rot,
) {
  var bufOff = 0;
  for (var kk = 0; kk < 4; kk += tsize) {
    var vertexOffset = k + kk;
    var p = 0;
    for (var j = 0; j < tsize; j++) {
      p |= last[lastOff + kk + j] << (8 * j);
    }
    final bits = 8 * tsize;
    final mask = bits == 32 ? 0xFFFFFFFF : (1 << bits) - 1;
    for (var i = 0; i < n; i++) {
      var v = buffer[bufOff + i];
      for (var j = 1; j < tsize; j++) {
        v |= buffer[bufOff + i + n * j] << (8 * j);
      }
      if (xor) {
        final r = rot;
        v = (((v << r) | (v >> ((32 - r) & 31))) & 0xFFFFFFFF) ^ p;
      } else {
        v = ((((0 - (v & 1)) & mask) ^ (v >> 1)) + p) & mask;
      }
      for (var j = 0; j < tsize; j++) {
        transposed[vertexOffset + j] = (v >> (j * 8)) & 0xFF;
      }
      p = v;
      vertexOffset += vsize;
    }
    bufOff += n * tsize;
  }
}

// ---------------------------------------------------------------- filtros

void _applyFilter(Uint8List d, int count, int stride, String filter) {
  if (filter == 'NONE' || filter.isEmpty) return;
  final bd = ByteData.sublistView(d);
  switch (filter) {
    case 'OCTAHEDRAL':
      if (stride == 4) {
        _oct(count, (i, c) => bd.getInt8(i * 4 + c).toDouble(), (i, c, v) => bd.setInt8(i * 4 + c, v), 127);
      } else if (stride == 8) {
        _oct(count, (i, c) => bd.getInt16(i * 8 + c * 2, Endian.little).toDouble(),
            (i, c, v) => bd.setInt16(i * 8 + c * 2, v, Endian.little), 32767);
      } else {
        throw FormatException(tr('Filtro octaédrico con tamaño no válido'));
      }
    case 'QUATERNION':
      if (stride != 8) throw FormatException(tr('Filtro de cuaternión con tamaño no válido'));
      _quat(count, bd);
    case 'EXPONENTIAL':
      for (var i = 0; i < count * stride ~/ 4; i++) {
        final v = bd.getUint32(i * 4, Endian.little);
        final m = (v << 8) & 0xFFFFFFFF;
        final mm = (m & 0x80000000) != 0 ? m - 0x100000000 : m;
        final mant = mm >> 8;
        final e = (v >> 24) & 0xFF;
        final exp = e >= 128 ? e - 256 : e;
        bd.setFloat32(i * 4, mant * math.pow(2, exp).toDouble(), Endian.little);
      }
    case 'COLOR':
      if (stride == 4) {
        _color(count, 1, (i, c) => bd.getUint8(i * 4 + c), (i, c, v) => bd.setUint8(i * 4 + c, v & 0xFF), 255);
      } else if (stride == 8) {
        _color(count, 2, (i, c) => bd.getUint16(i * 8 + c * 2, Endian.little),
            (i, c, v) => bd.setUint16(i * 8 + c * 2, v & 0xFFFF, Endian.little), 65535);
      } else {
        throw FormatException(tr('Filtro de color con tamaño no válido'));
      }
    default:
      throw FormatException(tr('Filtro meshopt no soportado: {filter}', {'filter': filter}));
  }
}

void _color(int count, int bytes, int Function(int, int) get, void Function(int, int, int) set, int max) {
  for (var i = 0; i < count; i++) {
    var as = get(i, 3);
    as |= as >> 1;
    as |= as >> 2;
    as |= as >> 4;
    as |= as >> 8;
    int sx(int v) => bytes == 1 ? (v >= 128 ? v - 256 : v) : (v >= 32768 ? v - 65536 : v);
    final y = get(i, 0), co = sx(get(i, 1)), cg = sx(get(i, 2));
    final r = y + co - cg, g = y + cg, b = y - co - cg;
    var a = get(i, 3);
    a = ((a << 1) & as) | (a & 1);
    final ss = max / as;
    int rf(int v) => (v * ss + 0.5).truncate();
    set(i, 0, rf(r));
    set(i, 1, rf(g));
    set(i, 2, rf(b));
    set(i, 3, rf(a));
  }
}

void _oct(int count, double Function(int, int) get, void Function(int, int, int) set, int max) {
  for (var i = 0; i < count; i++) {
    var x = get(i, 0), y = get(i, 1);
    var z = get(i, 2) - x.abs() - y.abs();
    final t = z >= 0 ? 0.0 : z;
    x += x >= 0 ? t : -t;
    y += y >= 0 ? t : -t;
    final l = math.sqrt(x * x + y * y + z * z);
    final s = l == 0 ? 0.0 : max / l;
    int r(double v) => (v * s + (v >= 0 ? 0.5 : -0.5)).truncate();
    set(i, 0, r(x));
    set(i, 1, r(y));
    set(i, 2, r(z));
  }
}

void _quat(int count, ByteData bd) {
  final scale = 32767.0 / math.sqrt(2.0);
  for (var i = 0; i < count; i++) {
    final o = i * 8;
    final w3 = bd.getInt16(o + 6, Endian.little);
    final sf = w3 | 3;
    final s = sf.toDouble();
    final x = bd.getInt16(o, Endian.little).toDouble();
    final y = bd.getInt16(o + 2, Endian.little).toDouble();
    final z = bd.getInt16(o + 4, Endian.little).toDouble();
    final ww = s * s * 2.0 - x * x - y * y - z * z;
    final w = math.sqrt(ww >= 0 ? ww : 0);
    final ss = scale / s;
    int r(double v) => (v * ss + (v >= 0 ? 0.5 : -0.5)).truncate();
    final xf = r(x), yf = r(y), zf = r(z), wf = (w * ss + 0.5).truncate();
    final qc = w3 & 3;
    bd.setInt16(o + ((qc + 1) & 3) * 2, xf, Endian.little);
    bd.setInt16(o + ((qc + 2) & 3) * 2, yf, Endian.little);
    bd.setInt16(o + ((qc + 3) & 3) * 2, zf, Endian.little);
    bd.setInt16(o + ((qc + 0) & 3) * 2, wf, Endian.little);
  }
}

// ---------------------------------------------------------------- índices

int _vbyte(Uint8List d, List<int> pos) {
  var p = pos[0];
  final lead = d[p++];
  if (lead < 128) {
    pos[0] = p;
    return lead;
  }
  var result = lead & 127;
  var shift = 7;
  for (var i = 0; i < 4; i++) {
    final g = d[p++];
    result |= (g & 127) << shift;
    shift += 7;
    if (g < 128) break;
  }
  pos[0] = p;
  return result & 0xFFFFFFFF;
}

int _decodeIndex(Uint8List d, List<int> pos, int last) {
  final v = _vbyte(d, pos);
  final delta = (v >> 1) ^ (-(v & 1));
  return (last + delta) & 0xFFFFFFFF;
}

Uint8List _decodeTriangles(Uint8List buf, int indexCount, int indexSize) {
  if (indexCount % 3 != 0 || (indexSize != 2 && indexSize != 4)) {
    throw FormatException(tr('Índices meshopt no válidos'));
  }
  if (buf.length < 1 + indexCount ~/ 3 + 16) throw FormatException(tr('Datos meshopt truncados'));
  if ((buf[0] & 0xF0) != 0xE0) throw FormatException(tr('Cabecera meshopt de índices no válida'));
  final version = buf[0] & 0x0F;
  if (version > 1) throw FormatException(tr('Versión meshopt de índices no soportada'));
  final out = Uint8List(indexCount * indexSize);
  final bd = ByteData.sublistView(out);
  var wp = 0;
  void write(int a, int b, int c) {
    if (indexSize == 2) {
      bd.setUint16(wp, a, Endian.little);
      bd.setUint16(wp + 2, b, Endian.little);
      bd.setUint16(wp + 4, c, Endian.little);
    } else {
      bd.setUint32(wp, a, Endian.little);
      bd.setUint32(wp + 4, b, Endian.little);
      bd.setUint32(wp + 8, c, Endian.little);
    }
    wp += 3 * indexSize;
  }

  final edge = Int32List(32)..fillRange(0, 32, -1);
  final vfifo = Int32List(16)..fillRange(0, 16, -1);
  var eo = 0, vo = 0;
  var next = 0, last = 0;
  final fecMax = version >= 1 ? 13 : 15;
  var code = 1;
  final codeEnd = code + indexCount ~/ 3;
  final dataPos = [codeEnd];
  final safeEnd = buf.length - 16;
  final aux = safeEnd;

  void pushEdge(int a, int b) {
    edge[eo * 2] = a;
    edge[eo * 2 + 1] = b;
    eo = (eo + 1) & 15;
  }

  void pushV(int v, [bool cond = true]) {
    vfifo[vo] = v;
    if (cond) vo = (vo + 1) & 15;
  }

  while (code < codeEnd) {
    final codetri = buf[code++];
    if (codetri < 0xF0) {
      final fe = codetri >> 4;
      final ei = (eo - 1 - fe) & 15;
      final a = edge[ei * 2], b = edge[ei * 2 + 1];
      int c;
      final fec = codetri & 15;
      if (fec < fecMax) {
        final cf = vfifo[(vo - 1 - fec) & 15];
        c = fec == 0 ? next : cf;
        final fec0 = fec == 0;
        if (fec0) next++;
        pushV(c, fec0);
      } else {
        if (dataPos[0] > safeEnd) throw FormatException(tr('Datos meshopt truncados'));
        last = c = fec != 15 ? (last + (fec * 2 - 27)) & 0xFFFFFFFF : _decodeIndex(buf, dataPos, last);
        pushV(c);
      }
      pushEdge(c, b);
      pushEdge(a, c);
      write(a & 0xFFFFFFFF, b & 0xFFFFFFFF, c);
    } else {
      if (codetri < 0xFE) {
        final codeaux = buf[aux + (codetri & 15)];
        final feb = codeaux >> 4, fec = codeaux & 15;
        final a = next++;
        final bf = vfifo[(vo - feb) & 15];
        int b;
        if (feb == 0) {
          b = next;
        } else {
          b = bf;
        }
        final feb0 = feb == 0;
        if (feb0) next++;
        final cf = vfifo[(vo - fec) & 15];
        int c = fec == 0 ? next : cf;
        final fec0 = fec == 0;
        if (fec0) next++;
        write(a, b, c);
        pushV(a);
        pushV(b, feb0);
        pushV(c, fec0);
        pushEdge(b, a);
        pushEdge(c, b);
        pushEdge(a, c);
      } else {
        if (dataPos[0] > safeEnd) throw FormatException(tr('Datos meshopt truncados'));
        final codeaux = buf[dataPos[0]++];
        final fea = codetri == 0xFE ? 0 : 15;
        final feb = codeaux >> 4, fec = codeaux & 15;
        if (codeaux == 0) next = 0;
        int a = fea == 0 ? next++ : 0;
        int b = feb == 0 ? next++ : vfifo[(vo - feb) & 15];
        int c = fec == 0 ? next++ : vfifo[(vo - fec) & 15];
        if (fea == 15) last = a = _decodeIndex(buf, dataPos, last);
        if (feb == 15) last = b = _decodeIndex(buf, dataPos, last);
        if (fec == 15) last = c = _decodeIndex(buf, dataPos, last);
        write(a & 0xFFFFFFFF, b & 0xFFFFFFFF, c & 0xFFFFFFFF);
        pushV(a);
        pushV(b, feb == 0 || feb == 15);
        pushV(c, fec == 0 || fec == 15);
        pushEdge(b, a);
        pushEdge(c, b);
        pushEdge(a, c);
      }
    }
  }
  if (dataPos[0] != safeEnd) throw FormatException(tr('Datos meshopt de índices dañados'));
  return out;
}

Uint8List _decodeSequence(Uint8List buf, int indexCount, int indexSize) {
  if (buf.length < 1 + indexCount + 4) throw FormatException(tr('Datos meshopt truncados'));
  if ((buf[0] & 0xF0) != 0xD0) throw FormatException(tr('Cabecera meshopt de secuencia no válida'));
  final out = Uint8List(indexCount * indexSize);
  final bd = ByteData.sublistView(out);
  final pos = [1];
  final safeEnd = buf.length - 4;
  final last = [0, 0];
  for (var i = 0; i < indexCount; i++) {
    if (pos[0] >= safeEnd) throw FormatException(tr('Datos meshopt truncados'));
    var v = _vbyte(buf, pos);
    final cur = v & 1;
    v >>= 1;
    final d = (v >> 1) ^ (-(v & 1));
    final index = (last[cur] + d) & 0xFFFFFFFF;
    last[cur] = index;
    if (indexSize == 2) {
      bd.setUint16(i * 2, index, Endian.little);
    } else {
      bd.setUint32(i * 4, index, Endian.little);
    }
  }
  if (pos[0] != safeEnd) throw FormatException(tr('Datos meshopt de secuencia dañados'));
  return out;
}
