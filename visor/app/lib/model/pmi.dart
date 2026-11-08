import 'dart:typed_data';

import '../l10n/l10n.dart';
import 'units.dart';

enum PmiKind { dimension, tolerance, datum }

/// Cara (o arista) de una pieza a la que se refiere una anotación.
class PmiRef {
  const PmiRef(this.part, this.isEdge, this.index);
  final int part;
  final bool isEdge;
  final int index;
}

/// Anotación del archivo: cota, tolerancia geométrica o referencia (datum).
class PmiItem {
  PmiItem({
    required this.kind,
    required this.type,
    required this.v,
    required this.text,
    required this.refs,
    required this.segments,
  });
  final PmiKind kind;
  final int type;
  final List<double> v; // ver datum.h
  final String text;
  final List<PmiRef> refs;

  /// Representación gráfica: 6 floats por segmento (x y z, x y z).
  final Float32List segments;

  bool get hasGraphic => segments.isNotEmpty;

  // ---- Cotas
  static const _dimNames = <int, String>{
    1: 'Distancia curva',
    2: 'Distancia',
    3: 'Distancia (centro a exterior)',
    4: 'Distancia (centro a interior)',
    5: 'Distancia (exterior a centro)',
    6: 'Distancia (exterior a exterior)',
    7: 'Distancia (exterior a interior)',
    8: 'Distancia (interior a centro)',
    9: 'Distancia (interior a exterior)',
    10: 'Distancia (interior a interior)',
    11: 'Ángulo',
    12: 'Distancia orientada',
    13: 'Distancia con trayectoria',
    14: 'Longitud de curva',
    15: 'Diámetro',
    16: 'Diámetro esférico',
    17: 'Radio',
    18: 'Radio esférico',
    19: 'Diámetro menor del toro',
    20: 'Diámetro mayor del toro',
    21: 'Radio menor del toro',
    22: 'Radio mayor del toro',
    27: 'Espesor',
    28: 'Ángulo',
  };

  // ---- Tolerancias geométricas
  static const _tolNames = <int, String>{
    1: 'Angularidad',
    2: 'Oscilación circular',
    3: 'Redondez',
    4: 'Coaxialidad',
    5: 'Concentricidad',
    6: 'Cilindricidad',
    7: 'Planitud',
    8: 'Paralelismo',
    9: 'Perpendicularidad',
    10: 'Posición',
    11: 'Perfil de línea',
    12: 'Perfil de superficie',
    13: 'Rectitud',
    14: 'Simetría',
    15: 'Oscilación total',
  };

  static const _tolSymbols = <int, String>{
    1: '∠',
    2: '↗',
    3: '○',
    4: '◎',
    5: '◎',
    6: '⌭',
    7: '▱',
    8: '∥',
    9: '⟂',
    10: '⌖',
    11: '⌒',
    12: '⌓',
    13: '⏤',
    14: '⌯',
    15: '⌰',
  };

  bool get isAngular => kind == PmiKind.dimension && (type == 11 || type == 28);
  bool get isRadial =>
      kind == PmiKind.dimension &&
      (type == 15 || type == 16 || type == 17 || type == 18);

  /// Nombre corto de la anotación: "Diámetro", "Planitud", "Referencia A"…
  String get name {
    switch (kind) {
      case PmiKind.dimension:
        final n = _dimNames[type];
        return n != null ? tr(n) : (v[0] == 0 ? tr('Anotación') : tr('Cota'));
      case PmiKind.tolerance:
        final n = _tolNames[type];
        return n != null ? tr(n) : tr('Tolerancia');
      case PmiKind.datum:
        return text.isEmpty ? tr('Referencia') : tr('Referencia {t}', {'t': text});
    }
  }

  /// Valor legible: "Ø 12,70 ±0,10 mm", "▱ 0,05 mm · A B".
  String describe(LengthUnit unit) {
    switch (kind) {
      case PmiKind.dimension:
        final prefix = switch (type) {
          15 || 19 || 20 => 'Ø ',
          16 => 'SØ ',
          17 || 21 || 22 => 'R ',
          18 => 'SR ',
          _ => '',
        };
        final q = switch (v[6].round()) {
          1 => tr(' mín.'),
          2 => tr(' máx.'),
          3 => tr(' medio'),
          _ => '',
        };
        if (isAngular) {
          // OCCT entrega los ángulos en grados.
          final deg = v[0];
          String tol = '';
          if (v[5] == 1) tol = _pm(v[1], v[2], (x) => _deg(x));
          return '${_deg(deg)}$tol$q';
        }
        if (v[0] == 0 && v[5] == 0)
          return text.isEmpty ? tr('Anotación gráfica') : text;
        var s = '$prefix${unit.length(v[0], digits: 2)}';
        if (v[5] == 1) {
          s += _pm(
            v[1],
            v[2],
            (x) => unit
                .length(x.abs(), digits: 2)
                .replaceAll(' ${unit.symbol}', ''),
          );
        } else if (v[5] == 2) {
          s = '$prefix${unit.length(v[2], digits: 2).replaceAll(' ${unit.symbol}', '')} – ${unit.length(v[1], digits: 2)}';
        }
        return '$s$q';
      case PmiKind.tolerance:
        final sym = _tolSymbols[type] ?? '';
        final zone = v[7].round() == 1
            ? 'Ø '
            : (v[7].round() == 2 ? 'SØ ' : '');
        final mod = switch (v[8].round()) {
          1 => ' Ⓜ',
          2 => ' Ⓛ',
          _ => '',
        };
        final refs = text.isEmpty ? '' : '  ·  ${text.split('|').join(' ')}';
        return '$sym $zone${unit.length(v[0], digits: 3)}$mod$refs'.trim();
      case PmiKind.datum:
        return text.isEmpty ? tr('Referencia') : text;
    }
  }

  static String _deg(double d) =>
      '${d.toStringAsFixed(2).ldec}°';

  /// OCCT guarda la desviación inferior como magnitud positiva (−lo).
  static String _pm(double up, double lo, String Function(double) f) {
    if (up == 0 && lo == 0) return '';
    if ((up - lo).abs() < 1e-9) return '  ±${f(up)}';
    String plus(double x) => x == 0 ? '0' : '+${f(x)}';
    String minus(double x) => x == 0 ? '0' : '−${f(x)}';
    return '  ${plus(up)} / ${minus(lo)}';
  }
}
