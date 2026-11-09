// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

import '../model/scene.dart';
import 'camera.dart';

/// Resultado de un rayo contra el modelo.
class Hit {
  Hit(this.instance, this.triangle, this.world, this.distance);
  final Instance instance;
  final int triangle;
  final vm.Vector3 world;
  final double distance;
}

/// Selección por rayo: devuelve el nodo tocado.
SceneNode? pickNode(
  Scene scene,
  OrbitCamera cam,
  double x,
  double y,
  double w,
  double h, {
  double explode = 0,
}) => pickHit(scene, cam, x, y, w, h, explode: explode)?.instance.node;

/// Rayo desde un píxel: caja envolvente para descartar y triángulos para afinar.
Hit? pickHit(
  Scene scene,
  OrbitCamera cam,
  double x,
  double y,
  double w,
  double h, {
  double explode = 0,
}) {
  final inv = (cam.projection(w / h) * cam.viewMatrix())..invert();
  final nx = 2 * x / w - 1, ny = 1 - 2 * y / h;
  final near = vm.Vector4(nx, ny, -1, 1)..applyMatrix4(inv);
  final far = vm.Vector4(nx, ny, 1, 1)..applyMatrix4(inv);
  final o = vm.Vector3(near.x / near.w, near.y / near.w, near.z / near.w);
  final f = vm.Vector3(far.x / far.w, far.y / far.w, far.z / far.w);
  final d = (f - o)..normalize();

  final cands = <(double, Instance)>[];
  for (final inst in scene.instances(explode: explode)) {
    final iw = vm.Matrix4.copy(inst.world)..invert();
    final lo = iw.transformed3(o.clone());
    final ld = iw.transformed3(o + d)..sub(lo);
    final t = _rayBox(
      lo,
      ld,
      inst.part.mesh.bounds.min,
      inst.part.mesh.bounds.max,
    );
    if (t != null) cands.add((t, inst));
  }
  cands.sort((a, b) => a.$1.compareTo(b.$1));
  double bestT = double.infinity;
  Hit? best;
  for (final (tBox, inst) in cands) {
    if (tBox > bestT) break;
    final iw = vm.Matrix4.copy(inst.world)..invert();
    final lo = iw.transformed3(o.clone());
    final ld = iw.transformed3(o + d)..sub(lo);
    final r = inst.part.mesh.indices != null
        ? _rayIndexed(lo, ld, inst.part.mesh.vertices, inst.part.mesh.indices!)
        : _rayMesh(lo, ld, inst.part.mesh.vertices);
    if (r != null) {
      // Distancia en espacio de mundo (por si hay escala).
      final hit = lo + ld * r.$1;
      final wHit = inst.world.transformed3(hit);
      final dist = (wHit - o).length;
      if (dist < bestT) {
        bestT = dist;
        best = Hit(inst, r.$2, wHit, dist);
      }
    }
  }
  return best;
}

double? _rayBox(vm.Vector3 o, vm.Vector3 d, List<double> mn, List<double> mx) {
  var tmin = -double.infinity, tmax = double.infinity;
  for (var i = 0; i < 3; i++) {
    final oi = i == 0 ? o.x : (i == 1 ? o.y : o.z);
    final di = i == 0 ? d.x : (i == 1 ? d.y : d.z);
    if (di.abs() < 1e-12) {
      if (oi < mn[i] || oi > mx[i]) return null;
    } else {
      var t1 = (mn[i] - oi) / di, t2 = (mx[i] - oi) / di;
      if (t1 > t2) {
        final tmp = t1;
        t1 = t2;
        t2 = tmp;
      }
      tmin = math.max(tmin, t1);
      tmax = math.min(tmax, t2);
      if (tmin > tmax) return null;
    }
  }
  return tmax < 0 ? null : math.max(tmin, 0);
}

/// Möller–Trumbore sobre vértices intercalados (pos+normal, 3 por triángulo).
(double, int)? _rayMesh(vm.Vector3 o, vm.Vector3 d, List<double> v) {
  double? best;
  var bestTri = -1;
  final n = v.length ~/ 18;
  for (var t = 0; t < n; t++) {
    final b = t * 18;
    final ax = v[b], ay = v[b + 1], az = v[b + 2];
    final e1x = v[b + 6] - ax, e1y = v[b + 7] - ay, e1z = v[b + 8] - az;
    final e2x = v[b + 12] - ax, e2y = v[b + 13] - ay, e2z = v[b + 14] - az;
    final px = d.y * e2z - d.z * e2y,
        py = d.z * e2x - d.x * e2z,
        pz = d.x * e2y - d.y * e2x;
    final det = e1x * px + e1y * py + e1z * pz;
    if (det.abs() < 1e-14) continue;
    final inv = 1 / det;
    final tx = o.x - ax, ty = o.y - ay, tz = o.z - az;
    final u = (tx * px + ty * py + tz * pz) * inv;
    if (u < 0 || u > 1) continue;
    final qx = ty * e1z - tz * e1y,
        qy = tz * e1x - tx * e1z,
        qz = tx * e1y - ty * e1x;
    final vv = (d.x * qx + d.y * qy + d.z * qz) * inv;
    if (vv < 0 || u + vv > 1) continue;
    final tt = (e2x * qx + e2y * qy + e2z * qz) * inv;
    if (tt > 0 && (best == null || tt < best)) {
      best = tt;
      bestTri = t;
    }
  }
  return best == null ? null : (best, bestTri);
}

/// Möller–Trumbore sobre una malla indexada (vértices únicos de 6 floats).
(double, int)? _rayIndexed(
  vm.Vector3 o,
  vm.Vector3 d,
  List<double> v,
  List<int> idx,
) {
  double? best;
  var bestTri = -1;
  final n = idx.length ~/ 3;
  for (var t = 0; t < n; t++) {
    final ia = idx[t * 3] * 6, ib = idx[t * 3 + 1] * 6, ic = idx[t * 3 + 2] * 6;
    final ax = v[ia], ay = v[ia + 1], az = v[ia + 2];
    final e1x = v[ib] - ax, e1y = v[ib + 1] - ay, e1z = v[ib + 2] - az;
    final e2x = v[ic] - ax, e2y = v[ic + 1] - ay, e2z = v[ic + 2] - az;
    final px = d.y * e2z - d.z * e2y,
        py = d.z * e2x - d.x * e2z,
        pz = d.x * e2y - d.y * e2x;
    final det = e1x * px + e1y * py + e1z * pz;
    if (det.abs() < 1e-14) continue;
    final inv = 1 / det;
    final tx = o.x - ax, ty = o.y - ay, tz = o.z - az;
    final u = (tx * px + ty * py + tz * pz) * inv;
    if (u < 0 || u > 1) continue;
    final qx = ty * e1z - tz * e1y,
        qy = tz * e1x - tx * e1z,
        qz = tx * e1y - ty * e1x;
    final vv = (d.x * qx + d.y * qy + d.z * qz) * inv;
    if (vv < 0 || u + vv > 1) continue;
    final tt = (e2x * qx + e2y * qy + e2z * qz) * inv;
    if (tt > 0 && (best == null || tt < best)) {
      best = tt;
      bestTri = t;
    }
  }
  return best == null ? null : (best, bestTri);
}
