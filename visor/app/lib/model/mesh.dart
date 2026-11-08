import 'dart:math' as math;
import 'dart:typed_data';

/// Caja envolvente alineada con los ejes.
class Bounds {
  Bounds(this.min, this.max);
  final List<double> min; // x y z
  final List<double> max;

  List<double> get center => [
    (min[0] + max[0]) / 2,
    (min[1] + max[1]) / 2,
    (min[2] + max[2]) / 2,
  ];
  List<double> get size => [max[0] - min[0], max[1] - min[1], max[2] - min[2]];
  double get radius {
    final s = size;
    return 0.5 * math.sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]);
  }
}

/// Malla de triángulos con vértices intercalados: posición (3) + normal (3).
class Mesh {
  Mesh({
    required this.vertices,
    required this.bounds,
    this.indices,
    this.extra,
  });

  /// 6 floats por vértice.
  final Float32List vertices;

  /// Si existe, la malla es indexada: `vertices` guarda vértices únicos y cada tres
  /// índices forman un triángulo. Si no, cada tres vértices son un triángulo.
  final Uint32List? indices;
  final Bounds bounds;

  /// Atributos opcionales por vértice (mismo orden que `vertices`): u, v, r, g, b, a.
  final Float32List? extra;
  static const int extraFloats = 6;

  static const int floatsPerVertex = 6;
  int get vertexCount => vertices.length ~/ floatsPerVertex;
  int get triangleCount => (indices?.length ?? vertexCount) ~/ 3;
}
