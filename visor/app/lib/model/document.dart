import 'vector_info.dart';
import 'lines.dart';
import 'pointcloud.dart';
import 'scene.dart';
import 'toolpath.dart';

/// Lo que Datum puede tener abierto: un modelo 3D, un dibujo 2D o unas trayectorias.
sealed class Document {
  String get name;
}

class ModelDocument extends Document {
  ModelDocument(this.scene);
  final Scene scene;
  @override
  String get name => scene.name;
}

class DrawingDocument extends Document {
  DrawingDocument(
    this.name,
    this.lines,
    this.texts, [
    this.insUnits = 0,
    this.truncated = false,
  ]);

  /// El archivo parece cortado (falta la marca final).
  final bool truncated;

  /// Datos propios de SVG y HPGL (origen, avisos, plumas…); nulo en DXF.
  VectorInfo? info;

  /// `$INSUNITS` del DXF: 0 sin unidad, 1 pulgadas, 4 milímetros…
  final int insUnits;
  @override
  final String name;
  final LineSet lines;
  final List<DrawingText> texts;
}

class ToolpathDocument extends Document {
  ToolpathDocument(this.toolpath);
  final Toolpath toolpath;
  @override
  String get name => toolpath.name;
}

class PointCloudDocument extends Document {
  PointCloudDocument(this.cloud);
  final PointCloud cloud;
  @override
  String get name => cloud.name;
}
