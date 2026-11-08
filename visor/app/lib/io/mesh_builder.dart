import 'dart:math' as math;
import 'dart:typed_data';

import '../model/mesh.dart';

/// Construye una malla con normales planas a partir de triángulos indexados.
Mesh meshFromIndexed(Float32List pos, Uint32List tri) {
  final n = tri.length ~/ 3;
  final out = Float32List(n * 18);
  final mn = [double.infinity, double.infinity, double.infinity];
  final mx = [-double.infinity, -double.infinity, -double.infinity];
  var o = 0;
  for (var t = 0; t < n; t++) {
    final ia = tri[t * 3] * 3, ib = tri[t * 3 + 1] * 3, ic = tri[t * 3 + 2] * 3;
    final ax = pos[ia], ay = pos[ia + 1], az = pos[ia + 2];
    final bx = pos[ib], by = pos[ib + 1], bz = pos[ib + 2];
    final cx = pos[ic], cy = pos[ic + 1], cz = pos[ic + 2];
    final ux = bx - ax, uy = by - ay, uz = bz - az;
    final vx = cx - ax, vy = cy - ay, vz = cz - az;
    var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    final len = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 0) {
      nx /= len;
      ny /= len;
      nz /= len;
    }
    out[o] = ax;
    out[o + 1] = ay;
    out[o + 2] = az;
    out[o + 3] = nx;
    out[o + 4] = ny;
    out[o + 5] = nz;
    out[o + 6] = bx;
    out[o + 7] = by;
    out[o + 8] = bz;
    out[o + 9] = nx;
    out[o + 10] = ny;
    out[o + 11] = nz;
    out[o + 12] = cx;
    out[o + 13] = cy;
    out[o + 14] = cz;
    out[o + 15] = nx;
    out[o + 16] = ny;
    out[o + 17] = nz;
    o += 18;
    for (final p in [ia, ib, ic]) {
      for (var k = 0; k < 3; k++) {
        final v = pos[p + k];
        if (v < mn[k]) mn[k] = v;
        if (v > mx[k]) mx[k] = v;
      }
    }
  }
  if (n == 0) {
    return Mesh(vertices: out, bounds: Bounds([0, 0, 0], [0, 0, 0]));
  }
  return Mesh(vertices: out, bounds: Bounds(mn, mx));
}

Bounds boundsOf(Float32List verts) {
  final mn = [double.infinity, double.infinity, double.infinity];
  final mx = [-double.infinity, -double.infinity, -double.infinity];
  for (var i = 0; i < verts.length; i += 6) {
    for (var k = 0; k < 3; k++) {
      final v = verts[i + k];
      if (v < mn[k]) mn[k] = v;
      if (v > mx[k]) mx[k] = v;
    }
  }
  if (mn[0].isInfinite) return Bounds([0, 0, 0], [0, 0, 0]);
  return Bounds(mn, mx);
}

/// Malla a partir de triángulos indexados con normales por vértice (si el archivo las trae).
Mesh meshFromIndexedWithNormals(
  Float32List pos,
  Float32List nor,
  Uint32List tri,
) {
  final n = tri.length ~/ 3;
  final out = Float32List(n * 18);
  final mn = [double.infinity, double.infinity, double.infinity];
  final mx = [-double.infinity, -double.infinity, -double.infinity];
  var o = 0;
  for (var t = 0; t < n; t++) {
    for (var k = 0; k < 3; k++) {
      final i = tri[t * 3 + k] * 3;
      out[o] = pos[i];
      out[o + 1] = pos[i + 1];
      out[o + 2] = pos[i + 2];
      out[o + 3] = nor[i];
      out[o + 4] = nor[i + 1];
      out[o + 5] = nor[i + 2];
      o += 6;
      for (var a = 0; a < 3; a++) {
        final v = pos[i + a];
        if (v < mn[a]) mn[a] = v;
        if (v > mx[a]) mx[a] = v;
      }
    }
  }
  if (n == 0) return Mesh(vertices: out, bounds: Bounds([0, 0, 0], [0, 0, 0]));
  return Mesh(vertices: out, bounds: Bounds(mn, mx));
}
