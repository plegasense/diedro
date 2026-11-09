// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:isolate';
import 'dart:typed_data';

import '../model/brep.dart';
import '../model/material.dart';
import '../model/mesh.dart';
import '../model/pmi.dart';

/// Malla transportable entre isolates sin copiar.
class MeshData {
  MeshData(
    this.name,
    Float32List verts,
    this.min,
    this.max, {
    this.color,
    Uint32List? indices,
    Float32List? extra,
    this.material,
  }) : _data = TransferableTypedData.fromList([verts]),
       _idx = indices == null ? null : TransferableTypedData.fromList([indices]),
       _extra = extra == null ? null : TransferableTypedData.fromList([extra]);
  final String name;
  final int? color;

  /// Índice en `SceneData.materials`, o null.
  final int? material;
  final TransferableTypedData _data;
  final TransferableTypedData? _idx, _extra;
  final List<double> min;
  final List<double> max;

  Mesh toMesh() => Mesh(
    vertices: _data.materialize().asFloat32List(),
    bounds: Bounds(min, max),
    indices: _idx?.materialize().asUint32List(),
    extra: _extra?.materialize().asFloat32List(),
  );
}

/// Una pieza colocada: índice de malla + matriz 4x4 (column-major) + nombre.
class PlacedData {
  PlacedData(this.meshIndex, this.matrix, this.name);
  final int meshIndex;
  final List<double> matrix;
  final String name;
}

/// Nodo de un árbol de ensamblaje (el padre siempre aparece antes que sus hijos).
class NodeData {
  NodeData(
    this.name,
    this.parent,
    this.part,
    this.matrix,
    this.color, {
    this.tag,
  });
  final List<int>? tag; // datos propios del formato (3MF: tipo, índices)
  final String name;
  final int parent; // -1 = raíz
  final int part; // -1 = grupo
  final List<double> matrix; // 16, column-major
  final int? color;
}

/// B-rep de una pieza, transportable entre isolates.
class PartBrepData {
  PartBrepData(
    Int32List faceOfTri,
    this.faceCount,
    Float32List edgeSegs,
    Int32List edgeOfSeg,
    this.edgeCount, {
    this.materialName = '',
    this.materialDensity = 0,
  }) : _faces = TransferableTypedData.fromList([faceOfTri]),
       _segs = TransferableTypedData.fromList([edgeSegs]),
       _ids = TransferableTypedData.fromList([edgeOfSeg]);
  final TransferableTypedData _faces, _segs, _ids;
  final int faceCount, edgeCount;
  final String materialName;
  final double materialDensity;

  PartBrep toBrep() => PartBrep(
    faceOfTriangle: _faces.materialize().asInt32List(),
    faceCount: faceCount,
    edgeSegments: _segs.materialize().asFloat32List(),
    edgeOfSegment: _ids.materialize().asInt32List(),
    edgeCount: edgeCount,
    materialName: materialName,
    materialDensity: materialDensity,
  );
}

/// Geometría exacta mantenida por el núcleo nativo (solo STEP/IGES/BREP).
class CadData {
  CadData(
    this.handle,
    this.unit,
    this.origin,
    this.schema,
    this.parts,
    this.pmi,
  );
  final List<PmiItem> pmi;
  final int handle; // dirección del puntero nativo
  final String unit, origin, schema;
  final List<PartBrepData> parts;
}

class SceneData {
  SceneData(
    this.name,
    this.meshes,
    this.placed, {
    this.nodes = const [],
    this.cad,
    this.extra,
    this.materials = const [],
    this.textures = const [],
  });
  final CadData? cad;

  /// Materiales con textura, transparencia o color por vértice (glTF, OBJ, PLY).
  final List<SurfaceMaterial> materials;
  final List<SceneTexture> textures;

  /// Datos propios del formato (3MF: el proyecto con placas, filamentos y ajustes).
  final Object? extra;
  final String name;
  final List<MeshData> meshes;
  final List<PlacedData> placed; // lista plana (STL/OBJ/3MF)
  final List<NodeData> nodes; // jerarquía (STEP/IGES)
}
