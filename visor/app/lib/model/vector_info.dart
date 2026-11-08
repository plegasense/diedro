/// Lo que se sabe de un SVG o un HPGL más allá de sus líneas: de dónde viene, qué tamaño dice
/// tener, qué no se ha podido dibujar y, en HPGL, cómo trabajaría el plóter.
class VectorPen {
  VectorPen(this.number);
  final int number;
  double? widthMm;
  int? rgb;
  double drawMm = 0;
  int strokes = 0;
}

class VectorInfo {
  VectorInfo(this.format);

  /// 'SVG', 'HPGL' o 'HPGL/2'.
  final String format;

  /// Programa que lo generó, si se reconoce (Inkscape, Illustrator, LightBurn, vpype…).
  String? generator;

  /// Tamaño físico declarado por el propio archivo (SVG con width/height en mm, cm, in o pt).
  double? declaredWidthMm, declaredHeightMm;

  bool usesCss = false;

  /// Cómo se han interpretado las unidades, en una frase.
  String unitNote = '';

  /// Elementos que el visor no representa o representa distinto, con su recuento.
  final Map<String, int> counts = {};

  /// Avisos legibles para el usuario (qué falta y por qué importa).
  final List<String> warnings = [];

  // ---- HPGL
  final List<VectorPen> pens = [];
  double drawMm = 0;
  double travelMm = 0;
  int lifts = 0;
  int labels = 0;
  bool encodedPolylines = false;
  final Set<String> unknownCommands = {};

  void count(String key, [int n = 1]) => counts[key] = (counts[key] ?? 0) + n;

  void warn(String text) {
    if (!warnings.contains(text)) warnings.add(text);
  }

  /// Parte del recorrido total que el plóter hace con la pluma levantada.
  double get travelShare {
    final t = drawMm + travelMm;
    return t <= 0 ? 0 : travelMm / t;
  }
}
