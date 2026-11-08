import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import '../model/material.dart';
import '../model/mesh_info.dart';
import 'mesh_data.dart';
import 'mesh_data_extra.dart';
import 'obj_loader.dart' show guessUpAxis;
import 'rich_mesh.dart';
import 'vrml_geom.dart' show thinGeometry;
import '../l10n/l10n.dart';

// Códigos de tipo escalar de PLY.
const _i8 = 0, _u8 = 1, _i16 = 2, _u16 = 3, _i32 = 4, _u32 = 5, _f32 = 6, _f64 = 7;

int _code(String t) => switch (t) {
  'char' || 'int8' => _i8,
  'uchar' || 'uint8' => _u8,
  'short' || 'int16' => _i16,
  'ushort' || 'uint16' => _u16,
  'int' || 'int32' => _i32,
  'uint' || 'uint32' => _u32,
  'float' || 'float32' => _f32,
  'double' || 'float64' => _f64,
  _ => throw FormatException(tr('Tipo PLY desconocido: {t}', {'t': t})),
};

class _Prop {
  _Prop(this.name, this.type, {this.countType = -1});
  final String name;
  final int type; // tipo escalar o, en listas, el de los elementos
  final int countType; // −1 si no es lista
  bool get isList => countType >= 0;
}

class _Element {
  _Element(this.name, this.count);
  final String name;
  final int count;
  final props = <_Prop>[];
}

/// Lector de números sobre el cuerpo del archivo (binario o ASCII).
class _Reader {
  _Reader(this.bytes, this.pos, this.ascii, this.endian)
    : bd = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final ByteData bd;
  int pos;
  final bool ascii;
  final Endian endian;

  bool get atEnd => pos >= bytes.length;

  static const _sizes = [1, 1, 2, 2, 4, 4, 4, 8];

  double num(int t) {
    if (ascii) return _ascii();
    if (pos + _sizes[t] > bytes.length) throw FormatException(tr('PLY truncado'));
    switch (t) {
      case _i8:
        return bd.getInt8(pos++).toDouble();
      case _u8:
        return bytes[pos++].toDouble();
      case _i16:
        final v = bd.getInt16(pos, endian);
        pos += 2;
        return v.toDouble();
      case _u16:
        final v = bd.getUint16(pos, endian);
        pos += 2;
        return v.toDouble();
      case _i32:
        final v = bd.getInt32(pos, endian);
        pos += 4;
        return v.toDouble();
      case _u32:
        final v = bd.getUint32(pos, endian);
        pos += 4;
        return v.toDouble();
      case _f32:
        final v = bd.getFloat32(pos, endian);
        pos += 4;
        return v;
      default:
        final v = bd.getFloat64(pos, endian);
        pos += 8;
        return v;
    }
  }

  int int_(int t) => num(t).toInt();

  double _ascii() {
    final n = bytes.length;
    while (pos < n && bytes[pos] <= 32) {
      pos++;
    }
    if (pos >= n) throw FormatException(tr('PLY truncado'));
    var neg = false;
    if (bytes[pos] == 0x2D || bytes[pos] == 0x2B) {
      neg = bytes[pos] == 0x2D;
      pos++;
    }
    var m = 0.0;
    var any = false;
    while (pos < n) {
      final d = bytes[pos] - 48;
      if (d < 0 || d > 9) break;
      m = m * 10 + d;
      pos++;
      any = true;
    }
    var sc = 0;
    if (pos < n && bytes[pos] == 0x2E) {
      pos++;
      while (pos < n) {
        final d = bytes[pos] - 48;
        if (d < 0 || d > 9) break;
        m = m * 10 + d;
        sc--;
        pos++;
        any = true;
      }
    }
    if (!any) {
      // nan / inf u otro texto: se salta la palabra
      while (pos < n && bytes[pos] > 32) {
        pos++;
      }
      return 0;
    }
    if (pos < n && (bytes[pos] == 0x65 || bytes[pos] == 0x45)) {
      pos++;
      var en = false;
      if (pos < n && (bytes[pos] == 0x2D || bytes[pos] == 0x2B)) {
        en = bytes[pos] == 0x2D;
        pos++;
      }
      var x = 0;
      while (pos < n) {
        final d = bytes[pos] - 48;
        if (d < 0 || d > 9) break;
        x = x * 10 + d;
        pos++;
      }
      sc += en ? -x : x;
    }
    if (sc != 0) {
      var f = 1.0;
      final k = sc < 0 ? -sc : sc;
      for (var j = 0; j < k && j < 40; j++) {
        f *= 10;
      }
      m = sc < 0 ? m / f : m * f;
    }
    return neg ? -m : m;
  }
}

/// Lee un PLY (ASCII o binario). Devuelve una [SceneData] (malla) o [PointData] (sin caras).
Object parsePly(String path) {
  try {
    return _parsePly(path);
  } on FormatException {
    rethrow;
  } on Exception {
    rethrow;
  } on Error catch (e) {
    throw FormatException(tr('El PLY está dañado ({e})', {'e': e}));
  }
}

Object _parsePly(String path) {
  final file = File(path);
  final bytes = file.readAsBytesSync();
  final name = path.split('/').last;
  // ---- cabecera
  var pos = 0;
  final lines = <String>[];
  var closed = false;
  while (pos < bytes.length && lines.length < 4000) {
    var e = pos;
    while (e < bytes.length && bytes[e] != 10) {
      e++;
    }
    final line = String.fromCharCodes(bytes, pos, e).trim();
    pos = e + 1;
    lines.add(line);
    if (line == 'end_header') {
      closed = true;
      break;
    }
  }
  if (lines.isEmpty || lines.first != 'ply') {
    throw FormatException(tr('No es un archivo PLY válido (falta la marca «ply»)'));
  }
  if (!closed) {
    throw FormatException(tr('El PLY está cortado: no tiene «end_header»'));
  }
  var format = 'ascii';
  var textureFile = '';
  final elements = <_Element>[];
  final info = MeshFileInfo('PLY');
  for (final l in lines) {
    final p = l.split(RegExp(r'\s+'));
    if (p.isEmpty) continue;
    if (p[0] == 'format' && p.length > 1) format = p[1];
    if (p[0] == 'comment' && p.length > 2) {
      final low = p[1].toLowerCase();
      if (low == 'texturefile' || low == 'texture_file') {
        textureFile = l.substring(l.indexOf(p[1]) + p[1].length).trim();
      } else if (info.generator.isEmpty &&
          RegExp(r'generated|created|exported|vcglib|blender|meshlab|colmap|open3d|cloudcompare|reality', caseSensitive: false).hasMatch(l)) {
        info.generator = l.substring(8).trim();
      }
    }
    if (p[0] == 'element' && p.length > 2) {
      elements.add(_Element(p[1], int.tryParse(p[2]) ?? 0));
    }
    if (p[0] == 'property' && elements.isNotEmpty && p.length > 2) {
      if (p[1] == 'list' && p.length > 4) {
        elements.last.props.add(_Prop(p[4], _code(p[3]), countType: _code(p[2])));
      } else {
        elements.last.props.add(_Prop(p[2], _code(p[1])));
      }
    }
  }
  for (final el in elements) {
    // un recuento imposible (cabecera dañada) se rechaza antes de reservar memoria
    if (el.count < 0 || el.count > bytes.length) {
      throw FormatException(tr('El PLY tiene una cabecera dañada (recuento imposible)'));
    }
  }
  final ascii = format == 'ascii';
  if (!ascii && format != 'binary_little_endian' && format != 'binary_big_endian') {
    throw FormatException(tr('Formato PLY desconocido: {format}', {'format': format}));
  }
  info.format = ascii
      ? 'PLY texto'
      : (format == 'binary_big_endian' ? 'PLY binario (big endian)' : 'PLY binario');
  final rd = _Reader(
    bytes,
    pos,
    ascii,
    format == 'binary_big_endian' ? Endian.big : Endian.little,
  );

  Float32List? positions, normals, uv, scalars;
  var scalarName = '';
  Uint8List? colors;
  var hasAlpha = false;
  CornerTris? tris;
  FloatBuf? cornerUv;
  FloatBuf? faceColors;
  FloatBuf? faceScal;
  var faceScalName = '';
  final edgePairs = <int>[];

  for (final el in elements) {
    final names = [for (final p in el.props) p.name];
    int ix(List<String> n) {
      for (final s in n) {
        final i = names.indexOf(s);
        if (i >= 0) return i;
      }
      return -1;
    }

    if (el.name == 'vertex') {
      final cx = ix(['x']), cy = ix(['y']), cz = ix(['z']);
      if (cx < 0 || cy < 0 || cz < 0) {
        throw FormatException(tr('El PLY no tiene coordenadas x, y, z'));
      }
      final nx = ix(['nx']), ny = ix(['ny']), nz = ix(['nz']);
      final cr = ix(['red', 'r', 'diffuse_red']),
          cg = ix(['green', 'g', 'diffuse_green']),
          cb = ix(['blue', 'b', 'diffuse_blue']),
          ca = ix(['alpha', 'a', 'diffuse_alpha']);
      final su = ix(['s', 'u', 'texture_u', 'texture_s']),
          sv = ix(['t', 'v', 'texture_v', 'texture_t']);
      final hasN = nx >= 0 && ny >= 0 && nz >= 0;
      final hasC = cr >= 0 && cg >= 0 && cb >= 0;
      final hasUv = su >= 0 && sv >= 0;
      final n = el.count;
      // campo escalar: la primera propiedad numérica que no es geometría ni color
      const known = {'x', 'y', 'z', 'nx', 'ny', 'nz', 'red', 'green', 'blue', 'alpha', 'r', 'g', 'b', 'a', 'diffuse_red', 'diffuse_green', 'diffuse_blue', 'diffuse_alpha', 's', 't', 'u', 'v', 'texture_u', 'texture_v', 'texture_s', 'texture_t', 'flags', 'material_index'};
      var sc = -1;
      for (var k = 0; k < el.props.length; k++) {
        if (!el.props[k].isList && !known.contains(el.props[k].name)) {
          sc = k;
          break;
        }
      }
      if (sc >= 0) {
        scalars = Float32List(n);
        scalarName = el.props[sc].name;
      }
      positions = Float32List(n * 3);
      if (hasN) normals = Float32List(n * 3);
      if (hasC) {
        colors = Uint8List(n * 4);
        hasAlpha = ca >= 0;
      }
      if (hasUv) uv = Float32List(n * 2);
      int colorByte(int k, double v) {
        final t = el.props[k].type;
        if (t == _f32 || t == _f64) return (v.clamp(0.0, 1.0) * 255).round();
        if (t == _u16) return (v / 257).round().clamp(0, 255);
        return v.round().clamp(0, 255);
      }

      for (var i = 0; i < n; i++) {
        if (rd.atEnd) throw FormatException(tr('PLY truncado en los vértices'));
        if (hasC && !hasAlpha) colors![i * 4 + 3] = 255;
        for (var k = 0; k < el.props.length; k++) {
          final p = el.props[k];
          if (p.isList) {
            final c = rd.int_(p.countType);
            if (c < 0 || c > 100000) throw FormatException(tr('PLY dañado'));
            for (var j = 0; j < c; j++) {
              rd.num(p.type);
            }
            continue;
          }
          final v = rd.num(p.type);
          if (k == cx) {
            positions[i * 3] = v;
          } else if (k == cy) {
            positions[i * 3 + 1] = v;
          } else if (k == cz) {
            positions[i * 3 + 2] = v;
          } else if (hasN && k == nx) {
            normals![i * 3] = v;
          } else if (hasN && k == ny) {
            normals![i * 3 + 1] = v;
          } else if (hasN && k == nz) {
            normals![i * 3 + 2] = v;
          } else if (hasC && k == cr) {
            colors![i * 4] = colorByte(k, v);
          } else if (hasC && k == cg) {
            colors![i * 4 + 1] = colorByte(k, v);
          } else if (hasC && k == cb) {
            colors![i * 4 + 2] = colorByte(k, v);
          } else if (hasC && k == ca) {
            colors![i * 4 + 3] = colorByte(k, v);
          } else if (k == sc && scalars != null) {
            scalars[i] = v;
          } else if (hasUv && k == su) {
            uv![i * 2] = v;
          } else if (hasUv && k == sv) {
            uv![i * 2 + 1] = 1 - v;
          }
        }
      }
    } else if (el.name == 'face') {
      final li = el.props.indexWhere(
        (p) => p.isList && (p.name == 'vertex_indices' || p.name == 'vertex_index'),
      );
      final ti = el.props.indexWhere((p) => p.isList && (p.name == 'texcoord' || p.name == 'texture_coordinates'));
      final fr = ix(['red', 'r']), fg = ix(['green', 'g']), fb = ix(['blue', 'b']), fa = ix(['alpha', 'a']);
      final hasFc = fr >= 0 && fg >= 0 && fb >= 0;
      tris = CornerTris(withUv: ti >= 0);
      const faceKnown = {'red', 'green', 'blue', 'alpha', 'r', 'g', 'b', 'a', 'flags', 'material_index'};
      final fsi = hasFc ? -1 : el.props.indexWhere((p) => !p.isList && !faceKnown.contains(p.name));
      if (fsi >= 0) {
        faceScal = FloatBuf();
        faceScalName = el.props[fsi].name;
      }
      if (ti >= 0) cornerUv = FloatBuf();
      if (hasFc) faceColors = FloatBuf();
      for (var i = 0; i < el.count; i++) {
        if (rd.atEnd) throw FormatException(tr('PLY truncado en las caras'));
        var idx = const <int>[];
        var tc = const <double>[];
        var fcR = 1.0, fcG = 1.0, fcB = 1.0, fcA = 1.0, fsv = 0.0;
        for (var k = 0; k < el.props.length; k++) {
          final p = el.props[k];
          if (p.isList) {
            final c = rd.int_(p.countType);
            if (c < 0 || c > 100000) throw FormatException(tr('PLY dañado en las caras'));
            if (k == li) {
              idx = List<int>.filled(c, 0);
              for (var j = 0; j < c; j++) {
                idx[j] = rd.int_(p.type);
              }
            } else if (k == ti) {
              tc = List<double>.filled(c, 0);
              for (var j = 0; j < c; j++) {
                tc[j] = rd.num(p.type);
              }
            } else {
              for (var j = 0; j < c; j++) {
                rd.num(p.type);
              }
            }
          } else {
            final v = rd.num(p.type);
            double cv(double x) => (p.type == _f32 || p.type == _f64) ? x : x / (p.type == _u16 ? 65535 : 255);
            if (k == fr) fcR = cv(v);
            if (k == fg) fcG = cv(v);
            if (k == fb) fcB = cv(v);
            if (k == fa) fcA = cv(v);
            if (k == fsi) fsv = v;
          }
        }
        if (idx.length < 3) continue;
        if (ti >= 0 && tc.length >= idx.length * 2) {
          for (var j = 0; j < idx.length; j++) {
            cornerUv!
              ..add(tc[j * 2])
              ..add(1 - tc[j * 2 + 1]);
          }
        }
        final hasTc = ti >= 0 && tc.length >= idx.length * 2;
        final uvBase = cornerUv == null ? 0 : (cornerUv.n ~/ 2) - idx.length;
        for (var j = 1; j + 1 < idx.length; j++) {
          tris.tri(
            idx[0],
            idx[j],
            idx[j + 1],
            t0: hasTc ? uvBase : -1,
            t1: hasTc ? uvBase + j : -1,
            t2: hasTc ? uvBase + j + 1 : -1,
          );
          if (faceScal != null) faceScal.add(fsv);
          if (hasFc) {
            faceColors!
              ..add(fcR)
              ..add(fcG)
              ..add(fcB)
              ..add(fa >= 0 ? fcA : 1);
          }
          if (idx.length > 3 && j == 1) info.polygonsNonTri++;
        }
        info.faces++;
      }
    } else if (el.name == 'tristrips') {
      // bandas de triángulos: índices separados por −1; el sentido de las caras alterna
      tris ??= CornerTris();
      final li = el.props.indexWhere((p) => p.isList);
      for (var i = 0; i < el.count; i++) {
        if (rd.atEnd) throw FormatException(tr('PLY truncado en las bandas de triángulos'));
        for (var k = 0; k < el.props.length; k++) {
          final p = el.props[k];
          if (p.isList) {
            final c = rd.int_(p.countType);
            if (c < 0 || c > 60000000) throw FormatException(tr('PLY dañado en las bandas de triángulos'));
            if (k != li) {
              for (var j = 0; j < c; j++) {
                rd.num(p.type);
              }
              continue;
            }
            var a = -1, b = -1, parity = 0;
            for (var j = 0; j < c; j++) {
              final v = rd.int_(p.type);
              if (v < 0) {
                a = b = -1;
                parity = 0;
                continue;
              }
              if (a >= 0 && b >= 0 && v != a && v != b && a != b) {
                if (parity == 0) {
                  tris.tri(a, b, v);
                } else {
                  tris.tri(b, a, v);
                }
                info.faces++;
              }
              if (a >= 0 && b >= 0) parity ^= 1;
              a = b;
              b = v;
            }
          } else {
            rd.num(p.type);
          }
        }
      }
    } else {
      // elemento desconocido (material, extras…): se salta; `edge` se guarda como segmentos
      final e1 = el.name == 'edge' ? ix(['vertex1', 'vertex_index1', 'v1']) : -1;
      final e2 = el.name == 'edge' ? ix(['vertex2', 'vertex_index2', 'v2']) : -1;
      for (var i = 0; i < el.count; i++) {
        if (rd.atEnd) break;
        var a = -1, b = -1;
        for (var k = 0; k < el.props.length; k++) {
          final p = el.props[k];
          if (p.isList) {
            final c = rd.int_(p.countType);
            if (c < 0 || c > 100000) throw FormatException(tr('PLY dañado'));
            for (var j = 0; j < c; j++) {
              rd.num(p.type);
            }
          } else {
            final v = rd.num(p.type);
            if (k == e1) a = v.toInt();
            if (k == e2) b = v.toInt();
          }
        }
        if (a >= 0 && b >= 0 && edgePairs.length < 2000000) {
          edgePairs
            ..add(a)
            ..add(b);
        }
      }
    }
  }
  if (positions == null) throw FormatException(tr('El PLY no contiene vértices'));
  info.vertices = positions.length ~/ 3;
  if (scalars != null && colors == null) {
    // sin color: el campo escalar se pinta con una rampa (azul → verde → amarillo)
    var lo = double.infinity, hi = -double.infinity;
    for (final v in scalars) {
      if (!v.isFinite) continue;
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    if (lo.isFinite && hi > lo) {
      info
        ..scalarName = scalarName
        ..scalarMin = lo
        ..scalarMax = hi;
      colors = Uint8List(scalars.length * 4);
      for (var i = 0; i < scalars.length; i++) {
        final t = scalars[i].isFinite ? ((scalars[i] - lo) / (hi - lo)).clamp(0.0, 1.0) : 0.0;
        final c = _ramp(t);
        colors[i * 4] = c[0];
        colors[i * 4 + 1] = c[1];
        colors[i * 4 + 2] = c[2];
        colors[i * 4 + 3] = 255;
      }
    }
  } else if (scalars != null) {
    info.scalarName = scalarName;
  }
  info.hasNormals = normals != null;
  info.hasColors = colors != null || faceColors != null;
  info.hasUv = uv != null || cornerUv != null;

  if (faceColors == null && faceScal != null && faceScal.n > 0 && tris != null && faceScal.n == tris.triangleCount) {
    final fv = faceScal.take();
    var lo = double.infinity, hi = -double.infinity;
    for (final v in fv) {
      if (!v.isFinite) continue;
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    if (lo.isFinite && hi > lo) {
      faceColors = FloatBuf();
      for (final v in fv) {
        final c = _ramp(v.isFinite ? ((v - lo) / (hi - lo)).clamp(0.0, 1.0) : 0.0);
        faceColors
          ..add(c[0] / 255)
          ..add(c[1] / 255)
          ..add(c[2] / 255)
          ..add(1);
      }
      info
        ..scalarName = tr('{name} (por cara)', {'name': faceScalName})
        ..scalarMin = lo
        ..scalarMax = hi
        ..hasColors = true;
    }
  }
  // Aristas (`edge`): se dibujan como tubos finos
  MeshData? edgeMesh;
  if (edgePairs.isNotEmpty) {
    final nv = positions.length ~/ 3;
    var mnx = double.infinity, mxx = -double.infinity, mny = double.infinity, mxy = -double.infinity, mnz = double.infinity, mxz = -double.infinity;
    for (var i = 0; i < nv; i++) {
      final x = positions[i * 3], y = positions[i * 3 + 1], z = positions[i * 3 + 2];
      if (x < mnx) mnx = x;
      if (x > mxx) mxx = x;
      if (y < mny) mny = y;
      if (y > mxy) mxy = y;
      if (z < mnz) mnz = z;
      if (z > mxz) mxz = z;
    }
    final diag = math.sqrt((mxx - mnx) * (mxx - mnx) + (mxy - mny) * (mxy - mny) + (mxz - mnz) * (mxz - mnz));
    final segs = <List<double>>[];
    for (var i = 0; i + 1 < edgePairs.length; i += 2) {
      final a = edgePairs[i], b = edgePairs[i + 1];
      if (a < 0 || b < 0 || a >= nv || b >= nv) continue;
      segs.add([positions[a * 3], positions[a * 3 + 1], positions[a * 3 + 2], positions[b * 3], positions[b * 3 + 1], positions[b * 3 + 2]]);
    }
    final g = thinGeometry(segments: segs, radius: (diag.isFinite && diag > 0 ? diag : 1) * 0.002);
    edgeMesh = g?.build(tr('Aristas'), null);
    info.warnings.add(tr('{n} aristas (edge): se dibujan como tubos finos.', {'n': segs.length}));
  }
  if ((tris == null || tris.triangleCount == 0) && edgeMesh != null) {
    final mm = [edgeMesh];
    guessUpAxis(info, mm, 'z');
    return SceneData(name, mm, [PlacedData(0, <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], name)], extra: info);
  }

  if (tris == null || tris.triangleCount == 0) {
    // Nube de puntos
    final pb = PointBuilder()..hasColor = colors != null;
    final n = positions.length ~/ 3;
    for (var i = 0; i < n; i++) {
      if (colors != null) {
        pb.add(
          positions[i * 3],
          positions[i * 3 + 1],
          positions[i * 3 + 2],
          colors[i * 4] / 255,
          colors[i * 4 + 1] / 255,
          colors[i * 4 + 2] / 255,
        );
      } else {
        pb.add(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]);
      }
    }
    return pb.build(name, format: 'PLY');
  }

  info.triangles = tris.triangleCount;
  final builder = RichMeshBuilder(
    pos: positions,
    nrm: normals,
    uv: cornerUv != null ? cornerUv.take() : uv,
    col: colors,
    faceColor: faceColors?.take(),
  )..nrmPerVertex = normals != null;
  info.normalsComputed = normals == null;
  // Las UV por vértice usan el índice del vértice; las de cara, su propio índice.
  if (cornerUv == null && uv != null) {
    // reescribe las esquinas para que el índice de UV sea el del vértice
    final t2 = CornerTris(withUv: true);
    for (var i = 0; i < tris.triangleCount; i++) {
      final a = tris.pos.a[i * 3], b = tris.pos.a[i * 3 + 1], c = tris.pos.a[i * 3 + 2];
      t2.tri(a, b, c, t0: a, t1: b, t2: c);
    }
    tris = t2;
  }
  final out = builder.build(tris, [name]);
  if (out.isEmpty) throw FormatException(tr('El PLY no contiene triángulos válidos'));

  // Textura citada en la cabecera
  final materials = <SurfaceMaterial>[];
  final textures = <SceneTexture>[];
  int? matIdx;
  if (textureFile.isNotEmpty && info.hasUv) {
    final tex = File('${file.parent.path}/$textureFile');
    final ti = TextureInfo(textureFile, role: 'color');
    if (tex.existsSync()) {
      final b = tex.readAsBytesSync();
      ti.bytes = b.length;
      textures.add(SceneTexture(textureFile, b));
      materials.add(SurfaceMaterial(name: textureFile, texture: 0));
      matIdx = 0;
    } else {
      ti.missing = true;
      info.missing.add(textureFile);
    }
    info.textures.add(ti);
  }
  final meshes = <MeshData>[];
  final placed = <PlacedData>[];
  final identity = <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  for (final g in out) {
    meshes.add(
      RichGroupOut(g.group, g.name, g.vertices, g.indices, g.min, g.max, g.extra, matIdx)
          .toMeshData(),
    );
    placed.add(PlacedData(meshes.length - 1, identity, name));
  }
  if (edgeMesh != null) {
    meshes.add(edgeMesh);
    placed.add(PlacedData(meshes.length - 1, identity, tr('Aristas')));
  }
  guessUpAxis(info, meshes, 'z');
  return SceneData(
    name,
    meshes,
    placed,
    materials: materials,
    textures: textures,
    extra: info,
  );
}

/// Rampa de color de un campo escalar (de azul oscuro a amarillo, pasando por verde azulado).
List<int> _ramp(double t) {
  const stops = [
    [68, 1, 84],
    [59, 82, 139],
    [33, 145, 140],
    [94, 201, 98],
    [253, 231, 37],
  ];
  final x = t * (stops.length - 1);
  final i = x.floor().clamp(0, stops.length - 2);
  final f = x - i;
  return [for (var k = 0; k < 3; k++) (stops[i][k] + (stops[i + 1][k] - stops[i][k]) * f).round()];
}
