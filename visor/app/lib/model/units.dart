// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import '../l10n/l10n.dart';
import 'unit_system.dart';

/// Unidad de longitud para mostrar medidas. La geometría interna siempre está en milímetros.
class LengthUnit {
  const LengthUnit(this.symbol, this._name, this.mmPerUnit);
  final String symbol;
  final String _name;

  /// Nombre largo de la unidad, en el idioma de la interfaz.
  String get name => tr(_name);
  final double mmPerUnit;

  static const mm = LengthUnit('mm', 'milímetros', 1);
  static const cm = LengthUnit('cm', 'centímetros', 10);
  static const m = LengthUnit('m', 'metros', 1000);
  static const inch = LengthUnit('in', 'pulgadas', 25.4);
  static const foot = LengthUnit('ft', 'pies', 304.8);
  static const um = LengthUnit('µm', 'micras', 0.001);
  static const px96 = LengthUnit('px', 'píxeles a 96 ppp', 25.4 / 96);
  static const pt72 = LengthUnit('pt', 'puntos a 72 ppp', 25.4 / 72);

  /// Unidad declarada en el archivo STEP (nombres de Open CASCADE o de la norma).
  static LengthUnit fromFile(String name) {
    final n = name.toUpperCase().trim();
    if (n.contains('INCH') || n == 'IN') return inch;
    if (n.contains('FOOT') || n.contains('FEET') || n == 'FT') return foot;
    if (n.contains('MICRO')) return um;
    if (n.contains('CENTI') || n == 'CM') return cm;
    if (n.contains('METRE') && !n.contains('MILLI')) return m;
    if (n == 'M') return m;
    return mm;
  }

  double fromMm(double v) => v / mmPerUnit;

  /// Tres medidas con la unidad una sola vez: "599,1 × 300,0 × 600,0 mm".
  String dims(List<double> mm) {
    String n(double v) => _num(fromMm(v), 1);
    return '${n(mm[0])} × ${n(mm[1])} × ${n(mm[2])} $symbol';
  }

  /// Masa en g o kg con coma decimal.
  static String mass(double grams) =>
      grams >= 1000 ? '${_num(grams / 1000, 2)} kg' : '${_num(grams, 1)} g';

  /// Longitud con la cantidad justa de decimales: "8,00 mm", "1 234,5 mm".
  String length(double mmValue, {int? digits}) {
    final v = fromMm(mmValue);
    final d = digits != null ? (_fineInch ? digits + 2 : digits) : _digits(v.abs());
    return '${_num(v, d)} $symbol';
  }

  String area(double mm2) {
    final v = mm2 / (mmPerUnit * mmPerUnit);
    return '${_num(v, _fineInch ? Units.inDigits2(v.abs()) : _digits(v.abs()))} $symbol²';
  }

  String volume(double mm3) {
    final v = mm3 / (mmPerUnit * mmPerUnit * mmPerUnit);
    return '${_num(v, _fineInch ? Units.inDigits2(v.abs()) : _digits(v.abs()))} $symbol³';
  }

  /// En imperial las pulgadas necesitan más decimales que los milímetros (0,0394 in).
  bool get _fineInch => identical(this, inch) && Units.isImperial;

  int _digits(double a) => _fineInch ? Units.inDigits(a) : (a >= 1000 ? 1 : (a >= 100 ? 2 : 2));

  /// Número con los separadores del idioma y [digits] decimales (para [Units]).
  static String numText(double v, int digits) => _num(v, digits);

  static String _num(double v, int digits) {
    var s = v.toStringAsFixed(digits);
    final neg = s.startsWith('-');
    if (neg) s = s.substring(1);
    final parts = s.split('.');
    final intPart = parts[0];
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(L.en ? ',' : ' ');
      buf.write(intPart[i]);
    }
    final frac = parts.length > 1 ? '${L.decimal}${parts[1]}' : '';
    return '${neg ? '-' : ''}$buf$frac';
  }
}

/// Nombre corriente del protocolo STEP a partir del identificador de esquema del archivo.
String stepProtocol(String schema) {
  final s = schema.toUpperCase();
  if (s.contains('AP242') || s.contains('MANAGED_MODEL_BASED'))
    return 'STEP AP242';
  if (s.contains('AUTOMOTIVE_DESIGN')) return 'STEP AP214';
  if (s.contains('CONFIG_CONTROL') || s.contains('AP203')) return 'STEP AP203';
  if (s.contains('AP214')) return 'STEP AP214';
  return s.isEmpty ? '' : 'STEP';
}

/// Densidades habituales para estimar la masa (g/cm³).
List<(String, double)> get kMaterials => [
  (tr('Acero'), 7.85),
  (tr('Acero inoxidable'), 8.0),
  (tr('Aluminio'), 2.70),
  (tr('Latón'), 8.50),
  (tr('Cobre'), 8.96),
  (tr('Titanio'), 4.51),
  (tr('Plástico ABS'), 1.05),
  (tr('Nailon'), 1.14),
];
