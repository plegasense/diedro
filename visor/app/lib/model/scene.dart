import 'package:vector_math/vector_math.dart' as vm;

import 'brep.dart';
import 'material.dart';
import 'mesh.dart';

/// Geometría única; se sube una sola vez a la GPU aunque tenga muchas instancias.
class Part {
  Part({
    required this.id,
    required this.name,
    required this.mesh,
    this.color,
    this.brep,
    this.material,
  });

  /// Material con textura, transparencia o color por vértice (glTF, OBJ, PLY).
  SurfaceMaterial? material;

  /// Caras y aristas exactas (solo en STEP/IGES).
  final PartBrep? brep;
  final int id;
  final String name;
  final Mesh mesh;

  /// Color ARGB (0xAARRGGBB) si el archivo lo define.
  final int? color;
  Object? gpu; // GpuMesh, cacheado por el renderizador
}

/// Nodo del árbol de ensamblaje: grupo o instancia de una pieza.
class SceneNode {
  SceneNode({
    required this.name,
    this.part,
    vm.Matrix4? transform,
    List<SceneNode>? children,
    this.tag,
  }) : transform = transform ?? vm.Matrix4.identity(),
       children = children ?? [];

  final String name;
  final Part? part;
  final vm.Matrix4 transform;
  final List<SceneNode> children;

  /// Datos propios del formato (3MF: tipo y números de placa, pieza o volumen).
  final List<int>? tag;
  bool visible = true;
  SceneNode? parent;

  int get instanceCount =>
      (part != null ? 1 : 0) + children.fold(0, (a, c) => a + c.instanceCount);
}

/// Una pieza colocada en el mundo, lista para dibujar.
class Instance {
  Instance(this.node, this.part, this.world);
  final SceneNode node;
  final Part part;
  final vm.Matrix4 world;
}

class Scene {
  Scene({
    required this.name,
    required this.root,
    required this.parts,
    this.cad,
    this.textures = const [],
  }) {
    _link(root);
  }

  /// Geometría exacta del archivo (STEP/IGES), si la hay.
  final CadBrep? cad;

  /// Imágenes de textura referidas por los materiales de las piezas.
  final List<SceneTexture> textures;

  /// Libera la memoria nativa de la geometría exacta.
  void dispose() => cad?.dispose();
  final String name;
  final SceneNode root;
  final List<Part> parts;

  void _link(SceneNode n) {
    for (final c in n.children) {
      c.parent = n;
      _link(c);
    }
  }

  Bounds? _bounds;

  /// Instancias visibles con su matriz de mundo. Con [explode] > 0 las piezas se separan
  /// del centro del conjunto.
  List<Instance> instances({bool onlyVisible = true, double explode = 0}) {
    final out = <Instance>[];
    void walk(SceneNode n, vm.Matrix4 parent) {
      if (onlyVisible && !n.visible) return;
      final w = parent * n.transform;
      if (n.part != null) out.add(Instance(n, n.part!, w));
      for (final c in n.children) {
        walk(c, w);
      }
    }

    walk(root, vm.Matrix4.identity());
    if (explode <= 0 || out.length < 2) return out;
    final b = _bounds ??= boundsOfInstances(instances(onlyVisible: false));
    final c = b.center;
    final center = vm.Vector3(c[0], c[1], c[2]);
    return [
      for (final i in out)
        () {
          final bc = i.part.mesh.bounds.center;
          final p = vm.Vector3(bc[0], bc[1], bc[2])..applyMatrix4(i.world);
          final shift = (p - center) * explode;
          return Instance(
            i.node,
            i.part,
            vm.Matrix4.translation(shift) * i.world,
          );
        }(),
    ];
  }

  int get triangleCount => instances(
    onlyVisible: false,
  ).fold(0, (a, i) => a + i.part.mesh.triangleCount);

  /// Caja envolvente de todas las instancias (con sus transformaciones).
  Bounds bounds() => boundsOfInstances(instances(onlyVisible: false));

  /// Instancias que pertenecen a alguno de los nodos dados (o a sus descendientes).
  List<Instance> instancesOf(Iterable<SceneNode> nodes) {
    final set = nodes.toSet();
    return instances(onlyVisible: false).where((i) {
      for (SceneNode? n = i.node; n != null; n = n.parent) {
        if (set.contains(n)) return true;
      }
      return false;
    }).toList();
  }

  static Bounds boundsOfInstances(List<Instance> list) {
    final mn = [double.infinity, double.infinity, double.infinity];
    final mx = [-double.infinity, -double.infinity, -double.infinity];
    for (final i in list) {
      final b = i.part.mesh.bounds;
      for (var c = 0; c < 8; c++) {
        final p = vm.Vector3(
          (c & 1) == 0 ? b.min[0] : b.max[0],
          (c & 2) == 0 ? b.min[1] : b.max[1],
          (c & 4) == 0 ? b.min[2] : b.max[2],
        )..applyMatrix4(i.world);
        for (var k = 0; k < 3; k++) {
          final v = k == 0 ? p.x : (k == 1 ? p.y : p.z);
          if (v < mn[k]) mn[k] = v;
          if (v > mx[k]) mx[k] = v;
        }
      }
    }
    if (mn[0].isInfinite) return Bounds([0, 0, 0], [1, 1, 1]);
    return Bounds(mn, mx);
  }
}
