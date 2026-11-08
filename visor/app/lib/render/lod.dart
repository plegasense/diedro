import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart' as vm;

import '../model/mesh.dart';
import '../model/scene.dart';

/// Simplificación por agrupación de vértices de una malla indexada: cada celda de una
/// rejilla se convierte en un vértice (posición, normal y color medios; UV del primero).
/// Devuelve la malla simplificada, también indexada.
({Float32List verts, Float32List? extra, Uint32List indices}) decimateIndexed(
  Float32List v,
  Float32List? ex,
  Uint32List idx,
  List<double> mn,
  List<double> mx,
  int targetTriangles,
) {
  final n = (math.sqrt(targetTriangles / 2)).clamp(16, 1500).round();
  final ix = (mx[0] - mn[0]) > 0 ? n / (mx[0] - mn[0]) : 0.0;
  final iy = (mx[1] - mn[1]) > 0 ? n / (mx[1] - mn[1]) : 0.0;
  final iz = (mx[2] - mn[2]) > 0 ? n / (mx[2] - mn[2]) : 0.0;
  final nv = v.length ~/ 6;
  final remap = Int32List(nv);
  final ids = <int, int>{};
  final acc = <double>[]; // px py pz nx ny nz u v r g b a count
  for (var i = 0; i < nv; i++) {
    final o = i * 6;
    final qx = ((v[o] - mn[0]) * ix).floor().clamp(0, n);
    final qy = ((v[o + 1] - mn[1]) * iy).floor().clamp(0, n);
    final qz = ((v[o + 2] - mn[2]) * iz).floor().clamp(0, n);
    final key = (qx * (n + 1) + qy) * (n + 1) + qz;
    var id = ids[key];
    if (id == null) {
      id = acc.length ~/ 13;
      ids[key] = id;
      acc.addAll(List<double>.filled(13, 0));
      if (ex != null) {
        acc[id * 13 + 6] = ex[o];
        acc[id * 13 + 7] = ex[o + 1];
      }
    }
    final a = id * 13;
    for (var k = 0; k < 6; k++) {
      acc[a + k] += v[o + k];
    }
    if (ex != null) {
      for (var k = 0; k < 4; k++) {
        acc[a + 8 + k] += ex[o + 2 + k];
      }
    }
    acc[a + 12] += 1;
    remap[i] = id;
  }
  final nn = acc.length ~/ 13;
  final outV = Float32List(nn * 6);
  final outE = ex != null ? Float32List(nn * 6) : null;
  for (var i = 0; i < nn; i++) {
    final a = i * 13, c = acc[a + 12];
    for (var k = 0; k < 3; k++) {
      outV[i * 6 + k] = acc[a + k] / c;
    }
    final l = math.sqrt(acc[a + 3] * acc[a + 3] + acc[a + 4] * acc[a + 4] + acc[a + 5] * acc[a + 5]);
    for (var k = 0; k < 3; k++) {
      outV[i * 6 + 3 + k] = l > 0 ? acc[a + 3 + k] / l : 0;
    }
    if (outE != null) {
      outE[i * 6] = acc[a + 6];
      outE[i * 6 + 1] = acc[a + 7];
      for (var k = 0; k < 4; k++) {
        outE[i * 6 + 2 + k] = acc[a + 8 + k] / c;
      }
    }
  }
  final tris = <int>[];
  for (var t = 0; t + 2 < idx.length; t += 3) {
    final a = remap[idx[t]], b = remap[idx[t + 1]], c = remap[idx[t + 2]];
    if (a == b || b == c || a == c) continue;
    tris.addAll([a, b, c]);
  }
  return (verts: outV, extra: outE, indices: Uint32List.fromList(tris));
}

/// Escena simplificada con la misma estructura de nodos que la original.
class LodScene {
  LodScene(this.scene, this._src, this._dst);
  final Scene scene;
  final SceneNode _src, _dst;

  /// Copia la visibilidad de la escena original.
  void sync() {
    void walk(SceneNode a, SceneNode b) {
      b.visible = a.visible;
      b.transform.setFrom(a.transform);
      for (var i = 0; i < a.children.length && i < b.children.length; i++) {
        walk(a.children[i], b.children[i]);
      }
    }

    walk(_src, _dst);
  }
}

/// Construye la versión simplificada (≈[budget] triángulos en total) de una escena con más
/// de [minTotal] triángulos; null si no hace falta.
Future<LodScene?> buildLodScene(
  Scene scene, {
  int budget = 120000,
  int minTotal = 400000,
  int minPart = 4000,
}) async {
  var total = 0;
  for (final p in scene.parts) {
    total += p.mesh.triangleCount;
  }
  if (total < minTotal) return null;
  final jobs = <int, Future<Mesh>>{};
  for (final p in scene.parts) {
    final t = p.mesh.triangleCount;
    if (t < minPart) continue;
    final m = p.mesh;
    final target = math.max(300, budget * t ~/ total);
    final bmn = m.bounds.min, bmx = m.bounds.max;
    final vs = TransferableTypedData.fromList([m.vertices]);
    final ex = m.extra == null ? null : TransferableTypedData.fromList([m.extra!]);
    final ix = m.indices == null ? null : TransferableTypedData.fromList([m.indices!]);
    jobs[p.id] = Isolate.run(() {
      final verts = vs.materialize().asFloat32List();
      final extra = ex?.materialize().asFloat32List();
      var indices = ix?.materialize().asUint32List();
      final v6 = verts;
      final e6 = extra;
      if (indices == null) {
        // malla desplegada (3 vértices por triángulo): se indexa tal cual
        final nIdx = verts.length ~/ 6;
        indices = Uint32List(nIdx);
        for (var i = 0; i < nIdx; i++) {
          indices[i] = i;
        }
      }
      final r = decimateIndexed(v6, e6, indices, bmn, bmx, target);
      return Mesh(vertices: r.verts, indices: r.indices, extra: r.extra, bounds: m.bounds);
    });
  }
  final done = <int, Mesh>{};
  for (final e in jobs.entries) {
    done[e.key] = await e.value;
  }
  final lodParts = <int, Part>{
    for (final p in scene.parts)
      p.id: done.containsKey(p.id)
          ? Part(id: p.id, name: p.name, mesh: done[p.id]!, color: p.color, material: p.material)
          : p,
  };
  SceneNode copy(SceneNode n) => SceneNode(
    name: n.name,
    part: n.part == null ? null : lodParts[n.part!.id],
    transform: vm.Matrix4.copy(n.transform),
    tag: n.tag,
    children: [for (final c in n.children) copy(c)],
  );
  final root = copy(scene.root);
  final lod = Scene(name: 'lod', root: root, parts: lodParts.values.toList(), textures: scene.textures);
  return LodScene(lod, scene.root, root)..sync();
}
