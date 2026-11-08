import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'mesh_data.dart';
import 'rich_mesh.dart';

/// Geometría lista para construir una malla con normales, UV y color: posiciones y
/// triángulos por esquinas, más lo que haya de normales, UV y color.
class RawGeo {
  RawGeo(this.pos, this.tris);
  final Float32List pos;
  final CornerTris tris;
  Float32List? nrm;
  bool nrmPerVertex = false;
  Float32List? uv;
  Uint8List? col;
  Float32List? faceColor;

  /// Sin normales en el archivo: plano (crease 0) o suave por encima de este coseno.
  bool flat = false;
  double creaseDot = 0.7;

  MeshData? build(String name, int? material) {
    if (tris.triangleCount == 0) return null;
    final b = RichMeshBuilder(
      pos: pos,
      nrm: nrm,
      uv: uv,
      col: col,
      faceColor: faceColor,
      flatWithoutNormals: flat,
      creaseDot: creaseDot,
    )..nrmPerVertex = nrmPerVertex;
    final out = b.build(tris, [name], materials: [material]);
    if (out.isEmpty) return null;
    return out.first.toMeshData();
  }
}

/// Acumula vértices con posición, normal y UV propias (primitivas con normales exactas).
class _Prim {
  final p = FloatBuf();
  final n = FloatBuf();
  final t = FloatBuf();
  final tris = CornerTris(withUv: true, withNrm: true);
  int _v = 0;

  int v(double x, double y, double z, double nx, double ny, double nz, double u, double w) {
    p.add3(x, y, z);
    n.add3(nx, ny, nz);
    t
      ..add(u)
      ..add(w);
    return _v++;
  }

  void tri(int a, int b, int c) => tris.tri(a, b, c, t0: a, t1: b, t2: c, n0: a, n1: b, n2: c);

  void quad(int a, int b, int c, int d) {
    tri(a, b, c);
    tri(a, c, d);
  }

  RawGeo done() => RawGeo(p.take(), tris)
    ..nrm = n.take()
    ..uv = t.take()
    ..nrmPerVertex = false;
}

RawGeo vrmlBox(double sx, double sy, double sz) {
  final h = _Prim();
  final x = sx / 2, y = sy / 2, z = sz / 2;
  void face(double nx, double ny, double nz, List<List<double>> c) {
    final a = h.v(c[0][0], c[0][1], c[0][2], nx, ny, nz, 0, 0);
    final b = h.v(c[1][0], c[1][1], c[1][2], nx, ny, nz, 1, 0);
    final d = h.v(c[2][0], c[2][1], c[2][2], nx, ny, nz, 1, 1);
    final e = h.v(c[3][0], c[3][1], c[3][2], nx, ny, nz, 0, 1);
    h.quad(a, b, d, e);
  }

  face(0, 0, 1, [[-x, -y, z], [x, -y, z], [x, y, z], [-x, y, z]]);
  face(0, 0, -1, [[x, -y, -z], [-x, -y, -z], [-x, y, -z], [x, y, -z]]);
  face(1, 0, 0, [[x, -y, z], [x, -y, -z], [x, y, -z], [x, y, z]]);
  face(-1, 0, 0, [[-x, -y, -z], [-x, -y, z], [-x, y, z], [-x, y, -z]]);
  face(0, 1, 0, [[-x, y, z], [x, y, z], [x, y, -z], [-x, y, -z]]);
  face(0, -1, 0, [[-x, -y, -z], [x, -y, -z], [x, -y, z], [-x, -y, z]]);
  return h.done();
}

RawGeo vrmlSphere(double r, {int seg = 32}) {
  final h = _Prim();
  final rings = seg ~/ 2;
  for (var i = 0; i <= rings; i++) {
    final a = math.pi * i / rings;
    final y = math.cos(a), s = math.sin(a);
    for (var j = 0; j <= seg; j++) {
      final b = 2 * math.pi * j / seg;
      final nx = s * math.sin(b), nz = s * math.cos(b);
      h.v(r * nx, r * y, r * nz, nx, y, nz, j / seg, 1 - i / rings);
    }
  }
  for (var i = 0; i < rings; i++) {
    for (var j = 0; j < seg; j++) {
      final a = i * (seg + 1) + j, b = a + seg + 1;
      if (i > 0) h.tri(a, b, a + 1);
      if (i < rings - 1) h.tri(a + 1, b, b + 1);
    }
  }
  return h.done();
}

RawGeo vrmlCylinder(double r, double height, {bool side = true, bool top = true, bool bottom = true, int seg = 32}) {
  final h = _Prim();
  final y = height / 2;
  if (side) {
    for (var j = 0; j <= seg; j++) {
      final b = 2 * math.pi * j / seg;
      final nx = math.sin(b), nz = math.cos(b);
      h.v(r * nx, y, r * nz, nx, 0, nz, j / seg, 1);
      h.v(r * nx, -y, r * nz, nx, 0, nz, j / seg, 0);
    }
    for (var j = 0; j < seg; j++) {
      final a = j * 2;
      h.tri(a, a + 1, a + 2);
      h.tri(a + 2, a + 1, a + 3);
    }
  }
  void cap(double yy, double ny) {
    final c = h.v(0, yy, 0, 0, ny, 0, 0.5, 0.5);
    final first = h.v(r * math.sin(0), yy, r * math.cos(0), 0, ny, 0, 0.5, 1);
    var prev = first;
    for (var j = 1; j <= seg; j++) {
      final b = 2 * math.pi * j / seg;
      final cur = h.v(r * math.sin(b), yy, r * math.cos(b), 0, ny, 0, 0.5 + 0.5 * math.sin(b), 0.5 + 0.5 * math.cos(b));
      if (ny > 0) {
        h.tri(c, prev, cur);
      } else {
        h.tri(c, cur, prev);
      }
      prev = cur;
    }
  }

  if (top) cap(y, 1);
  if (bottom) cap(-y, -1);
  return h.done();
}

RawGeo vrmlCone(double r, double height, {bool side = true, bool bottom = true, int seg = 32}) {
  final h = _Prim();
  final y = height / 2;
  if (side) {
    final slope = r / height; // para la normal: (h, r) normalizado en el plano radial
    final l = math.sqrt(1 + slope * slope);
    for (var j = 0; j <= seg; j++) {
      final b = 2 * math.pi * j / seg;
      final nx = math.sin(b) / l, nz = math.cos(b) / l;
      h.v(0, y, 0, nx, slope / l, nz, j / seg, 1);
      h.v(r * math.sin(b), -y, r * math.cos(b), nx, slope / l, nz, j / seg, 0);
    }
    for (var j = 0; j < seg; j++) {
      final a = j * 2;
      h.tri(a, a + 1, a + 2);
      h.tri(a + 2, a + 1, a + 3);
    }
  }
  if (bottom) {
    final c = h.v(0, -y, 0, 0, -1, 0, 0.5, 0.5);
    var prev = h.v(0, -y, r, 0, -1, 0, 0.5, 1);
    for (var j = 1; j <= seg; j++) {
      final b = 2 * math.pi * j / seg;
      final cur = h.v(r * math.sin(b), -y, r * math.cos(b), 0, -1, 0, 0.5 + 0.5 * math.sin(b), 0.5 + 0.5 * math.cos(b));
      h.tri(c, cur, prev);
      prev = cur;
    }
  }
  return h.done();
}

List<double> _cross(List<double> a, List<double> b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
double _len(List<double> a) => math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
List<double> _norm(List<double> a) {
  final l = _len(a);
  return l < 1e-12 ? [0, 0, 0] : [a[0] / l, a[1] / l, a[2] / l];
}

List<double> _sub(List<double> a, List<double> b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];

/// Extrusion de VRML: sección por cada punto de la espina con su escala y orientación.
RawGeo? vrmlExtrusion({
  required List<double> spine,
  required List<double> cross,
  List<double> scale = const [1, 1],
  List<double> orientation = const [0, 0, 1, 0],
  bool beginCap = true,
  bool endCap = true,
  bool ccw = true,
}) {
  final n = spine.length ~/ 3, m = cross.length ~/ 2;
  if (n < 2 || m < 2 || n * m > 4000000) return null;
  List<double> p(int i) => [spine[i * 3], spine[i * 3 + 1], spine[i * 3 + 2]];
  bool same(List<double> a, List<double> b) => _len(_sub(a, b)) < 1e-9;
  final closedSpine = same(p(0), p(n - 1));
  final closedCross = cross[0] == cross[(m - 1) * 2] && cross[1] == cross[(m - 1) * 2 + 1];

  List<double> rotAxis(List<double> v, List<double> axis, double ang) {
    final l = _len(axis);
    if (l < 1e-12 || ang == 0) return v;
    final k = [axis[0] / l, axis[1] / l, axis[2] / l];
    final c = math.cos(ang), s = math.sin(ang);
    final kv = k[0] * v[0] + k[1] * v[1] + k[2] * v[2];
    final kx = _cross(k, v);
    return [v[0] * c + kx[0] * s + k[0] * kv * (1 - c), v[1] * c + kx[1] * s + k[1] * kv * (1 - c), v[2] * c + kx[2] * s + k[2] * kv * (1 - c)];
  }

  // marcos de la espina (SCP)
  final ys = <List<double>>[], zs = <List<double>?>[];
  for (var i = 0; i < n; i++) {
    List<double> y;
    List<double>? z;
    if (i == 0) {
      y = closedSpine && n > 2 ? _sub(p(1), p(n - 2)) : _sub(p(1), p(0));
      z = closedSpine && n > 2 ? _cross(_sub(p(1), p(0)), _sub(p(n - 2), p(0))) : null;
    } else if (i == n - 1) {
      y = closedSpine && n > 2 ? _sub(p(1), p(n - 2)) : _sub(p(n - 1), p(n - 2));
      z = closedSpine && n > 2 ? _cross(_sub(p(1), p(0)), _sub(p(n - 2), p(0))) : null;
    } else {
      y = _sub(p(i + 1), p(i - 1));
      z = _cross(_sub(p(i + 1), p(i)), _sub(p(i - 1), p(i)));
    }
    ys.add(_norm(y));
    zs.add(z != null && _len(z) > 1e-12 ? _norm(z) : null);
  }
  if (!zs.any((z) => z != null)) {
    // espina recta: se gira (0,1,0) hasta la dirección de la espina
    final d = ys[0];
    final ax = _cross([0, 1, 0], d);
    final List<double> z0;
    if (_len(ax) < 1e-9) {
      z0 = d[1] >= 0 ? [0, 0, 1] : [0, 0, -1];
    } else {
      z0 = rotAxis([0, 0, 1], ax, math.acos((d[1]).clamp(-1.0, 1.0)));
    }
    for (var i = 0; i < n; i++) {
      zs[i] = z0;
    }
  } else {
    for (var i = 0; i < n; i++) {
      if (zs[i] != null) continue;
      var k = i - 1;
      while (k >= 0 && zs[k] == null) {
        k--;
      }
      if (k < 0) {
        k = i + 1;
        while (k < n && zs[k] == null) {
          k++;
        }
      }
      zs[i] = zs[k];
    }
  }
  for (var i = 1; i < n; i++) {
    final a = zs[i]!, b = zs[i - 1]!;
    if (a[0] * b[0] + a[1] * b[1] + a[2] * b[2] < 0) zs[i] = [-a[0], -a[1], -a[2]];
  }

  final pos = FloatBuf();
  for (var i = 0; i < n; i++) {
    final y = ys[i], z = zs[i]!;
    final x = _norm(_cross(y, z));
    final sc = scale.length >= (i + 1) * 2 ? [scale[i * 2], scale[i * 2 + 1]] : [scale.isNotEmpty ? scale[0] : 1.0, scale.length > 1 ? scale[1] : 1.0];
    final or = orientation.length >= (i + 1) * 4 ? orientation.sublist(i * 4, i * 4 + 4) : (orientation.length >= 4 ? orientation.sublist(0, 4) : [0.0, 0.0, 1.0, 0.0]);
    for (var j = 0; j < m; j++) {
      var v = [cross[j * 2] * sc[0], 0.0, cross[j * 2 + 1] * sc[1]];
      v = rotAxis(v, or.sublist(0, 3), or[3]);
      pos.add3(
        spine[i * 3] + x[0] * v[0] + y[0] * v[1] + z[0] * v[2],
        spine[i * 3 + 1] + x[1] * v[0] + y[1] * v[1] + z[1] * v[2],
        spine[i * 3 + 2] + x[2] * v[0] + y[2] * v[1] + z[2] * v[2],
      );
    }
  }
  final positions = pos.take();
  final tris = CornerTris();
  final mm = closedCross ? m - 1 : m;
  int id(int i, int j) => i * m + (j % mm == j ? j : j % mm);
  for (var i = 0; i + 1 < n; i++) {
    for (var j = 0; j + 1 < m; j++) {
      final a = id(i, j), b = id(i, j + 1), c = id(i + 1, j + 1), d = id(i + 1, j);
      // según la norma, la sección va en sentido antihorario visto desde +Y
      if (ccw) {
        tris
          ..tri(a, c, d)
          ..tri(a, b, c);
      } else {
        tris
          ..tri(a, d, c)
          ..tri(a, c, b);
      }
    }
  }
  void cap(int i, bool begin) {
    final poly = [for (var j = 0; j < mm; j++) i * m + j];
    if (poly.length < 3) return;
    final t = triangulatePolygon(positions, poly);
    for (var k = 0; k + 2 < t.length; k += 3) {
      final a = poly[t[k]], b = poly[t[k + 1]], c = poly[t[k + 2]];
      // el casquete inicial mira contra la espina; el final, a favor
      if (begin == ccw) {
        tris.tri(a, c, b);
      } else {
        tris.tri(a, b, c);
      }
    }
  }

  if (beginCap) cap(0, true);
  if (endCap && !(closedSpine && n > 2)) cap(n - 1, false);
  return RawGeo(positions, tris);
}

/// ElevationGrid: malla regular de alturas.
RawGeo? vrmlElevationGrid({
  required int xDim,
  required int zDim,
  required double xSpacing,
  required double zSpacing,
  required List<double> height,
  bool ccw = true,
}) {
  if (xDim < 2 || zDim < 2 || xDim * zDim > 16000000 || height.length < xDim * zDim) return null;
  final pos = Float32List(xDim * zDim * 3);
  final uv = Float32List(xDim * zDim * 2);
  for (var j = 0; j < zDim; j++) {
    for (var i = 0; i < xDim; i++) {
      final k = j * xDim + i;
      pos[k * 3] = i * xSpacing;
      pos[k * 3 + 1] = height[k];
      pos[k * 3 + 2] = j * zSpacing;
      uv[k * 2] = i / (xDim - 1);
      uv[k * 2 + 1] = 1 - j / (zDim - 1);
    }
  }
  final tris = CornerTris(withUv: true);
  for (var j = 0; j + 1 < zDim; j++) {
    for (var i = 0; i + 1 < xDim; i++) {
      final a = j * xDim + i, b = (j + 1) * xDim + i, c = (j + 1) * xDim + i + 1, d = j * xDim + i + 1;
      if (ccw) {
        tris
          ..tri(a, b, c, t0: a, t1: b, t2: c)
          ..tri(a, c, d, t0: a, t1: c, t2: d);
      } else {
        tris
          ..tri(a, c, b, t0: a, t1: c, t2: b)
          ..tri(a, d, c, t0: a, t1: d, t2: c);
      }
    }
  }
  return RawGeo(pos, tris)..uv = uv;
}

/// Líneas y puntos no se dibujan como tales en Datum: se convierten en tubos finos y octaedros.
RawGeo? thinGeometry({List<List<double>> segments = const [], List<List<double>> points = const [], required double radius}) {
  final pos = FloatBuf();
  final tris = CornerTris();
  var nv = 0;
  for (final s in segments) {
    final a = [s[0], s[1], s[2]], b = [s[3], s[4], s[5]];
    final d = _sub(b, a);
    final l = _len(d);
    if (l < 1e-12) continue;
    final dir = [d[0] / l, d[1] / l, d[2] / l];
    final ref = dir[1].abs() < 0.9 ? [0.0, 1.0, 0.0] : [1.0, 0.0, 0.0];
    final u = _norm(_cross(dir, ref));
    final w = _cross(dir, u);
    final ring = <List<double>>[
      [u[0] + w[0], u[1] + w[1], u[2] + w[2]],
      [-u[0] + w[0], -u[1] + w[1], -u[2] + w[2]],
      [-u[0] - w[0], -u[1] - w[1], -u[2] - w[2]],
      [u[0] - w[0], u[1] - w[1], u[2] - w[2]],
    ];
    final r = radius * 0.7071;
    for (final c in [a, b]) {
      for (final q in ring) {
        pos.add3(c[0] + q[0] * r, c[1] + q[1] * r, c[2] + q[2] * r);
      }
    }
    for (var k = 0; k < 4; k++) {
      final k2 = (k + 1) % 4;
      final p0 = nv + k, p1 = nv + k2, p2 = nv + 4 + k2, p3 = nv + 4 + k;
      tris
        ..tri(p0, p1, p2)
        ..tri(p0, p2, p3);
    }
    nv += 8;
    if (nv > 8000000) break;
  }
  for (final q in points) {
    final r = radius;
    pos
      ..add3(q[0] + r, q[1], q[2])
      ..add3(q[0] - r, q[1], q[2])
      ..add3(q[0], q[1] + r, q[2])
      ..add3(q[0], q[1] - r, q[2])
      ..add3(q[0], q[1], q[2] + r)
      ..add3(q[0], q[1], q[2] - r);
    const f = [
      [0, 2, 4],
      [2, 1, 4],
      [1, 3, 4],
      [3, 0, 4],
      [2, 0, 5],
      [1, 2, 5],
      [3, 1, 5],
      [0, 3, 5],
    ];
    for (final t in f) {
      tris.tri(nv + t[0], nv + t[1], nv + t[2]);
    }
    nv += 6;
    if (nv > 8000000) break;
  }
  if (tris.triangleCount == 0) return null;
  return RawGeo(pos.take(), tris);
}

// ---------------------------------------------------------------- PNG

final List<int> _crcT = () {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int _crc(List<int> b, [int start = 0, int? end]) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < (end ?? b.length); i++) {
    c = _crcT[(c ^ b[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

/// Codifica píxeles RGBA (8 bits) como PNG para las texturas de píxeles de VRML.
Uint8List encodePngRgba(int w, int h, Uint8List rgba) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    raw.add(Uint8List.sublistView(rgba, y * w * 4, (y + 1) * w * 4));
  }
  final z = zlib.encode(raw.toBytes());
  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final len = ByteData(4)..setUint32(0, data.length);
    out.add(len.buffer.asUint8List());
    final body = [...type.codeUnits, ...data];
    out.add(body);
    final crc = ByteData(4)..setUint32(0, _crc(body));
    out.add(crc.buffer.asUint8List());
  }

  final ihdr = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  chunk('IHDR', ihdr.buffer.asUint8List());
  chunk('IDAT', z);
  chunk('IEND', const []);
  return out.toBytes();
}
