import '../l10n/l10n.dart';

/// Lo que se sabe de una nube de puntos más allá de sus puntos: formato, sistema de coordenadas,
/// unidades, cuántos puntos hay en el archivo y cuántos se muestran.
class CloudInfo {
  CloudInfo(this.format);

  /// 'LAS 1.4', 'LAZ 1.2', 'E57', 'PCD', 'XYZ', 'PTS', 'PLY'.
  String format;

  /// Puntos que declara el archivo y puntos que se han cargado (se diezma por encima del límite).
  int totalPoints = 0;
  int shownPoints = 0;

  /// 'formato 3 (retornos, GPS y color)', etc.
  String? pointFormat;

  /// Nombre del sistema de coordenadas (de EPSG o WKT) y su unidad.
  String? crs;
  int? epsg;

  /// 'm', 'ft', 'ft EE. UU.', '°' o vacío si no se sabe.
  String unit = '';
  double? mmPerUnit;
  bool geographic = false;

  String? software, system, date;
  List<double>? scale;

  /// Cajas del archivo en coordenadas absolutas.
  List<double>? minAbs, maxAbs;

  bool hasIntensity = false, hasClass = false, hasReturns = false, hasGps = false, hasRgb = false;

  /// Recuento de clases ASPRS y de número de retorno entre los puntos mostrados.
  final Map<int, int> classCounts = {};
  final Map<int, int> returnCounts = {};

  /// Intensidad: mínimo y máximo del archivo, y el intervalo (percentiles 2–98) con que se pinta.
  int intensityMin = 0, intensityMax = 0;
  double intensityLo = 0, intensityHi = 1;

  /// Rango de tiempo GPS, si lo hay.
  double? gpsMin, gpsMax;

  /// Puntos por m² sobre las celdas ocupadas (si se conoce la unidad).
  double? density;

  int vlrCount = 0;
  int extraBytes = 0;
  final List<String> warnings = [];

  bool get sampled => shownPoints < totalPoints;

  void warn(String t) {
    if (!warnings.contains(t)) warnings.add(t);
  }
}

/// Clases del estándar ASPRS (LAS 1.4) con nombre y color.
const Map<int, (String, int)> kAsprsClasses = {
  0: ('Nunca clasificado', 0x9AA5A8),
  1: ('Sin clasificar', 0xBFC9CC),
  2: ('Suelo', 0xB58B5A),
  3: ('Vegetación baja', 0xA6D96A),
  4: ('Vegetación media', 0x4CAF50),
  5: ('Vegetación alta', 0x1B7F3B),
  6: ('Edificio', 0xE5533D),
  7: ('Ruido bajo', 0xF0C419),
  8: ('Clave del modelo', 0xB07CF0),
  9: ('Agua', 0x3B82F6),
  10: ('Ferrocarril', 0x6B7280),
  11: ('Superficie de carretera', 0x8E8E93),
  12: ('Solape', 0xD1A3FF),
  13: ('Cable (protección)', 0xFF8FB1),
  14: ('Cable (conductor)', 0xFF5C8A),
  15: ('Torre de transmisión', 0xF59E0B),
  16: ('Conector de cable', 0xFFC4A3),
  17: ('Puente', 0xC084FC),
  18: ('Ruido alto', 0xFFE066),
  19: ('Estructura aérea', 0x22D3EE),
  20: ('Suelo ignorado', 0x7C5E3C),
  21: ('Nieve', 0xF1F5F9),
  22: ('Exclusión temporal', 0x94A3B8),
};

String asprsName(int c) {
  final n = kAsprsClasses[c]?.$1;
  return n != null ? tr(n) : tr('Clase {c} (definida por el usuario)', {'c': c});
}

int asprsColor(int c) => kAsprsClasses[c]?.$2 ?? 0xFF6EC7;
