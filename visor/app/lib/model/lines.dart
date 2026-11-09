// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:typed_data';

import 'mesh.dart';

/// Conjunto de segmentos de línea (pares de vértices) con color por vértice.
/// Vértices intercalados: x y z r g b (6 floats).
class LineSet {
  LineSet({
    required this.vertices,
    required this.bounds,
    this.groups = const [],
  });

  final Float32List vertices;
  final Bounds bounds;

  /// Particiones contiguas del buffer (p. ej. capas de un DXF).
  final List<LineGroup> groups;

  static const int floatsPerVertex = 6;
  int get vertexCount => vertices.length ~/ floatsPerVertex;
  int get segmentCount => vertexCount ~/ 2;

  Object? gpu; // buffer de GPU cacheado por el renderizador
}

class LineGroup {
  LineGroup(
    this.name,
    this.firstVertex,
    this.vertexCount, {
    this.visible = true,
  });
  final String name;
  final int firstVertex;
  final int vertexCount;
  bool visible;
}

/// Texto suelto de un dibujo 2D (cotas, rótulos).
class DrawingText {
  DrawingText(this.x, this.y, this.height, this.rotation, this.text);
  final double x, y, height, rotation;
  final String text;
}
