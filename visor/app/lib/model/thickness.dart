// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:math' as math;
import 'dart:typed_data';

/// Espesor de pared de una malla: desde el centro de cada triángulo se lanza un rayo hacia dentro
/// (contra su normal) y se mide la distancia hasta la cara de enfrente.
class ThicknessResult {
  ThicknessResult(this.perTriangle, this.minThickness, this.minAt, this.sampled, this.measured);

  /// Espesor por triángulo en unidades del modelo (`NaN` si no se midió o el rayo no encontró pared).
  final Float32List perTriangle;
  final double minThickness;

  /// Centro del triángulo más fino (x, y, z).
  final List<double> minAt;

  /// ¿Se midió sólo una muestra de los triángulos?
  final bool sampled;
  final int measured;
}

/// BVH de triángulos (partición por la mediana del centroide con cubos): sirve para lanzar rayos.
class _Bvh {
  _Bvh(this.a, this.n) {
    _build();
  }
  final Float32List a; // 9 por triángulo
  final int n;
  late Int32List order;
  // nodos: 6 floats de caja, hijo izquierdo (o -1), primer índice, cuenta
  Float32List box = Float32List(0);
  Int32List left = Int32List(0), first = Int32List(0), count = Int32List(0);
  Int32List right = Int32List(0);
  int nodes = 0;

  void _grow() {
    final c = left.length == 0 ? 1024 : left.length * 2;
    Int32List g(Int32List o) => Int32List(c)..setAll(0, o);
    left = g(left);
    right = g(right);
    first = g(first);
    count = g(count);
    box = Float32List(c * 6)..setAll(0, box);
  }

  int _alloc() {
    if (nodes >= left.length) _grow();
    return nodes++;
  }

  void _build() {
    order = Int32List(n);
    final cx = Float32List(n * 3);
    for (var i = 0; i < n; i++) {
      order[i] = i;
      for (var k = 0; k < 3; k++) {
        cx[i * 3 + k] = (a[i * 9 + k] + a[i * 9 + 3 + k] + a[i * 9 + 6 + k]) / 3;
      }
    }
    final stack = <(int, int, int)>[(0, n, _alloc())];
    while (stack.isNotEmpty) {
      final (s, e, node) = stack.removeLast();
      var mn0 = double.infinity, mn1 = double.infinity, mn2 = double.infinity;
      var mx0 = -double.infinity, mx1 = -double.infinity, mx2 = -double.infinity;
      var cmn = [double.infinity, double.infinity, double.infinity], cmx = [-double.infinity, -double.infinity, -double.infinity];
      for (var q = s; q < e; q++) {
        final t = order[q];
        for (var v = 0; v < 3; v++) {
          final x = a[t * 9 + v * 3], y = a[t * 9 + v * 3 + 1], z = a[t * 9 + v * 3 + 2];
          if (x < mn0) mn0 = x;
          if (y < mn1) mn1 = y;
          if (z < mn2) mn2 = z;
          if (x > mx0) mx0 = x;
          if (y > mx1) mx1 = y;
          if (z > mx2) mx2 = z;
        }
        for (var k = 0; k < 3; k++) {
          final c = cx[t * 3 + k];
          if (c < cmn[k]) cmn[k] = c;
          if (c > cmx[k]) cmx[k] = c;
        }
      }
      box[node * 6] = mn0;
      box[node * 6 + 1] = mn1;
      box[node * 6 + 2] = mn2;
      box[node * 6 + 3] = mx0;
      box[node * 6 + 4] = mx1;
      box[node * 6 + 5] = mx2;
      final cnt = e - s;
      var axis = 0;
      var ext = cmx[0] - cmn[0];
      for (var k = 1; k < 3; k++) {
        if (cmx[k] - cmn[k] > ext) {
          ext = cmx[k] - cmn[k];
          axis = k;
        }
      }
      if (cnt <= 4 || ext <= 0) {
        left[node] = -1;
        first[node] = s;
        count[node] = cnt;
        continue;
      }
      // partición por el punto medio del centroide (rápida y suficiente para rayos)
      final mid = (cmn[axis] + cmx[axis]) / 2;
      var i = s, j = e - 1;
      while (i <= j) {
        if (cx[order[i] * 3 + axis] < mid) {
          i++;
        } else {
          final t = order[i];
          order[i] = order[j];
          order[j] = t;
          j--;
        }
      }
      var split = i;
      if (split == s || split == e) split = (s + e) ~/ 2;
      final l = _alloc(), r = _alloc();
      left[node] = l;
      right[node] = r;
      count[node] = 0;
      stack
        ..add((s, split, l))
        ..add((split, e, r));
    }
  }

  /// Distancia al primer triángulo golpeado por el rayo (o infinito) y su índice en [hitTri].
  int hitTri = -1;
  double cast(double ox, double oy, double oz, double dx, double dy, double dz, double tmax, int skip) {
    var best = tmax;
    hitTri = -1;
    final idx = 1.0 / (dx == 0 ? 1e-30 : dx), idy = 1.0 / (dy == 0 ? 1e-30 : dy), idz = 1.0 / (dz == 0 ? 1e-30 : dz);
    final st = Int32List(128);
    var sp = 0;
    st[sp++] = 0;
    while (sp > 0) {
      final node = st[--sp];
      final b = node * 6;
      var t0 = 0.0, t1 = best;
      var x0 = (box[b] - ox) * idx, x1 = (box[b + 3] - ox) * idx;
      if (x0 > x1) {
        final t = x0;
        x0 = x1;
        x1 = t;
      }
      t0 = math.max(t0, x0);
      t1 = math.min(t1, x1);
      if (t0 > t1) continue;
      var y0 = (box[b + 1] - oy) * idy, y1 = (box[b + 4] - oy) * idy;
      if (y0 > y1) {
        final t = y0;
        y0 = y1;
        y1 = t;
      }
      t0 = math.max(t0, y0);
      t1 = math.min(t1, y1);
      if (t0 > t1) continue;
      var z0 = (box[b + 2] - oz) * idz, z1 = (box[b + 5] - oz) * idz;
      if (z0 > z1) {
        final t = z0;
        z0 = z1;
        z1 = t;
      }
      t0 = math.max(t0, z0);
      t1 = math.min(t1, z1);
      if (t0 > t1) continue;
      if (left[node] < 0) {
        for (var q = first[node]; q < first[node] + count[node]; q++) {
          final t = order[q];
          if (t == skip) continue;
          final o = t * 9;
          final e1x = a[o + 3] - a[o], e1y = a[o + 4] - a[o + 1], e1z = a[o + 5] - a[o + 2];
          final e2x = a[o + 6] - a[o], e2y = a[o + 7] - a[o + 1], e2z = a[o + 8] - a[o + 2];
          final px = dy * e2z - dz * e2y, py = dz * e2x - dx * e2z, pz = dx * e2y - dy * e2x;
          final det = e1x * px + e1y * py + e1z * pz;
          if (det.abs() < 1e-12) continue;
          final inv = 1 / det;
          final tx = ox - a[o], ty = oy - a[o + 1], tz = oz - a[o + 2];
          final u = (tx * px + ty * py + tz * pz) * inv;
          if (u < 0 || u > 1) continue;
          final qx = ty * e1z - tz * e1y, qy = tz * e1x - tx * e1z, qz = tx * e1y - ty * e1x;
          final v = (dx * qx + dy * qy + dz * qz) * inv;
          if (v < 0 || u + v > 1) continue;
          final tt = (e2x * qx + e2y * qy + e2z * qz) * inv;
          if (tt > 1e-9 && tt < best) {
            best = tt;
            hitTri = t;
          }
        }
      } else if (sp < 124) {
        st[sp++] = left[node];
        st[sp++] = right[node];
      }
    }
    return best;
  }
}

/// Calcula el espesor de pared de una malla sin índices (vértices x y z nx ny nz, 3 por triángulo).
/// Con más de [maxRays] triángulos se mide una muestra uniforme y el resto toma el valor del
/// triángulo medido más cercano en el archivo.
ThicknessResult computeThickness(Float32List verts, {int maxRays = 300000}) {
  final n = verts.length ~/ 18;
  final a = Float32List(n * 9);
  for (var t = 0; t < n; t++) {
    for (var v = 0; v < 3; v++) {
      final s = t * 18 + v * 6;
      a[t * 9 + v * 3] = verts[s];
      a[t * 9 + v * 3 + 1] = verts[s + 1];
      a[t * 9 + v * 3 + 2] = verts[s + 2];
    }
  }
  final res = Float32List(n)..fillRange(0, n, double.nan);
  if (n == 0) return ThicknessResult(res, double.nan, [0, 0, 0], false, 0);
  final bvh = _Bvh(a, n);
  final stride = math.max(1, (n / maxRays).ceil());
  // caras casi coincidentes (casquillos solapados): no cuentan como pared
  var mnx = double.infinity, mny = double.infinity, mnz = double.infinity, mxx = -double.infinity, mxy = -double.infinity, mxz = -double.infinity;
  for (var i = 0; i < a.length; i += 3) {
    if (a[i] < mnx) mnx = a[i];
    if (a[i] > mxx) mxx = a[i];
    if (a[i + 1] < mny) mny = a[i + 1];
    if (a[i + 1] > mxy) mxy = a[i + 1];
    if (a[i + 2] < mnz) mnz = a[i + 2];
    if (a[i + 2] > mxz) mxz = a[i + 2];
  }
  final eps = 2e-4 * math.sqrt((mxx - mnx) * (mxx - mnx) + (mxy - mny) * (mxy - mny) + (mxz - mnz) * (mxz - mnz));
  var minT = double.infinity;
  var minAt = [0.0, 0.0, 0.0];
  var measured = 0;
  double last = double.nan;
  for (var t = 0; t < n; t++) {
    if (t % stride != 0) {
      res[t] = last.isNaN ? double.nan : last;
      continue;
    }
    final o = t * 9;
    final e1x = a[o + 3] - a[o], e1y = a[o + 4] - a[o + 1], e1z = a[o + 5] - a[o + 2];
    final e2x = a[o + 6] - a[o], e2y = a[o + 7] - a[o + 1], e2z = a[o + 8] - a[o + 2];
    var nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x;
    final l = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l < 1e-18) {
      last = double.nan;
      continue;
    }
    nx /= l;
    ny /= l;
    nz /= l;
    final cx = (a[o] + a[o + 3] + a[o + 6]) / 3, cy = (a[o + 1] + a[o + 4] + a[o + 7]) / 3, cz = (a[o + 2] + a[o + 5] + a[o + 8]) / 3;
    // hacia dentro: contra la normal
    final d = bvh.cast(cx, cy, cz, -nx, -ny, -nz, double.infinity, t);
    double th = double.nan;
    if (d.isFinite && bvh.hitTri >= 0) {
      final h = bvh.hitTri * 9;
      final f1x = a[h + 3] - a[h], f1y = a[h + 4] - a[h + 1], f1z = a[h + 5] - a[h + 2];
      final f2x = a[h + 6] - a[h], f2y = a[h + 7] - a[h + 1], f2z = a[h + 8] - a[h + 2];
      final hx = f1y * f2z - f1z * f2y, hy = f1z * f2x - f1x * f2z, hz = f1x * f2y - f1y * f2x;
      // la pared de enfrente mira en sentido contrario: su normal apunta como el rayo
      if (hx * -nx + hy * -ny + hz * -nz > 0 && d >= eps) th = d;
    }
    res[t] = th;
    last = th;
    measured++;
    if (th.isFinite && th < minT) {
      minT = th;
      minAt = [cx, cy, cz];
    }
  }
  return ThicknessResult(res, minT.isFinite ? minT : double.nan, minAt, stride > 1, measured);
}

/// Autointersecciones: pares de triángulos que se atraviesan sin compartir vértices.
class SelfIntersections {
  SelfIntersections(this.pairs, this.at, this.truncated, this.checked);

  /// Pares encontrados (hasta el límite pedido).
  final int pairs;

  /// Centro de los primeros pares (x y z por par).
  final List<double> at;
  final bool truncated;
  final int checked;
}

SelfIntersections findSelfIntersections(Float32List verts, {int maxPairs = 5000}) {
  final n = verts.length ~/ 18;
  final a = Float32List(n * 9);
  for (var t = 0; t < n; t++) {
    for (var v = 0; v < 3; v++) {
      final s = t * 18 + v * 6;
      for (var k = 0; k < 3; k++) {
        a[t * 9 + v * 3 + k] = verts[s + k];
      }
    }
  }
  if (n < 2) return SelfIntersections(0, const [], false, n);
  final bvh = _Bvh(a, n);
  final at = <double>[];
  var pairs = 0;
  final st = Int32List(128);

  bool shares(int t, int u) {
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        if (a[t * 9 + i * 3] == a[u * 9 + j * 3] &&
            a[t * 9 + i * 3 + 1] == a[u * 9 + j * 3 + 1] &&
            a[t * 9 + i * 3 + 2] == a[u * 9 + j * 3 + 2]) {
          return true;
        }
      }
    }
    return false;
  }

  // ¿El segmento p→q atraviesa el interior del triángulo u? (Möller–Trumbore acotado a [0,1])
  bool pierces(double px, double py, double pz, double qx, double qy, double qz, int u) {
    final o = u * 9;
    final dx = qx - px, dy = qy - py, dz = qz - pz;
    final e1x = a[o + 3] - a[o], e1y = a[o + 4] - a[o + 1], e1z = a[o + 5] - a[o + 2];
    final e2x = a[o + 6] - a[o], e2y = a[o + 7] - a[o + 1], e2z = a[o + 8] - a[o + 2];
    final hx = dy * e2z - dz * e2y, hy = dz * e2x - dx * e2z, hz = dx * e2y - dy * e2x;
    final det = e1x * hx + e1y * hy + e1z * hz;
    if (det.abs() < 1e-18) return false;
    final inv = 1 / det;
    final sx = px - a[o], sy = py - a[o + 1], sz = pz - a[o + 2];
    final uu = (sx * hx + sy * hy + sz * hz) * inv;
    const m = 1e-6;
    if (uu < m || uu > 1 - m) return false;
    final qx2 = sy * e1z - sz * e1y, qy2 = sz * e1x - sx * e1z, qz2 = sx * e1y - sy * e1x;
    final vv = (dx * qx2 + dy * qy2 + dz * qz2) * inv;
    if (vv < m || uu + vv > 1 - m) return false;
    final tt = (e2x * qx2 + e2y * qy2 + e2z * qz2) * inv;
    return tt > m && tt < 1 - m;
  }

  bool crosses(int t, int u) {
    for (var i = 0; i < 3; i++) {
      final j = (i + 1) % 3;
      if (pierces(a[t * 9 + i * 3], a[t * 9 + i * 3 + 1], a[t * 9 + i * 3 + 2], a[t * 9 + j * 3], a[t * 9 + j * 3 + 1], a[t * 9 + j * 3 + 2], u)) return true;
      if (pierces(a[u * 9 + i * 3], a[u * 9 + i * 3 + 1], a[u * 9 + i * 3 + 2], a[u * 9 + j * 3], a[u * 9 + j * 3 + 1], a[u * 9 + j * 3 + 2], t)) return true;
    }
    return false;
  }

  var truncated = false;
  for (var t = 0; t < n && !truncated; t++) {
    final o = t * 9;
    var lx = double.infinity, ly = double.infinity, lz = double.infinity;
    var hx = -double.infinity, hy = -double.infinity, hz = -double.infinity;
    for (var v = 0; v < 3; v++) {
      lx = math.min(lx, a[o + v * 3]);
      hx = math.max(hx, a[o + v * 3]);
      ly = math.min(ly, a[o + v * 3 + 1]);
      hy = math.max(hy, a[o + v * 3 + 1]);
      lz = math.min(lz, a[o + v * 3 + 2]);
      hz = math.max(hz, a[o + v * 3 + 2]);
    }
    var sp = 0;
    st[sp++] = 0;
    while (sp > 0) {
      final node = st[--sp];
      final b = node * 6;
      if (bvh.box[b] > hx || bvh.box[b + 3] < lx || bvh.box[b + 1] > hy || bvh.box[b + 4] < ly || bvh.box[b + 2] > hz || bvh.box[b + 5] < lz) continue;
      if (bvh.left[node] < 0) {
        for (var q = bvh.first[node]; q < bvh.first[node] + bvh.count[node]; q++) {
          final u = bvh.order[q];
          if (u <= t || shares(t, u)) continue;
          if (crosses(t, u)) {
            pairs++;
            if (at.length < 300) {
              at.addAll([
                (a[o] + a[o + 3] + a[o + 6]) / 3,
                (a[o + 1] + a[o + 4] + a[o + 7]) / 3,
                (a[o + 2] + a[o + 5] + a[o + 8]) / 3,
              ]);
            }
            if (pairs >= maxPairs) truncated = true;
          }
        }
      } else if (sp < 124) {
        st[sp++] = bvh.left[node];
        st[sp++] = bvh.right[node];
      }
    }
  }
  return SelfIntersections(pairs, at, truncated, n);
}
