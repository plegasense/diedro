import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';
import 'cloud_info.dart';
import 'units.dart';

/// Sistema de unidades con el que se muestran las medidas. La geometría interna siempre está en mm.
enum UnitSystem { auto, metric, imperial }

const double kMmPerInch = 25.4;
const double kGramsPerOunce = 28.349523125;
const double kGramsPerPound = 453.59237;

/// Estado global y formato de medidas para la pantalla. Con [UnitSystem.metric] (o Automático fuera de
/// EE. UU., Liberia y Birmania) el texto sale exactamente igual que antes; en imperial se pasa a pulgadas.
class Units {
  /// Cambia al elegir otro sistema; las pantallas se reconstruyen escuchándolo.
  static final ValueNotifier<UnitSystem> notifier = ValueNotifier(UnitSystem.auto);

  static UnitSystem get system => notifier.value;
  static set system(UnitSystem s) => notifier.value = s;

  /// Países que usan el sistema imperial/anglosajón en el día a día.
  static const imperialCountries = {'US', 'LR', 'MM'};

  static bool get isImperial => switch (system) {
    UnitSystem.metric => false,
    UnitSystem.imperial => true,
    UnitSystem.auto => imperialCountries.contains(L.countryCode?.toUpperCase()),
  };

  /// Unidad de longitud por defecto para archivos sin unidad propia.
  static LengthUnit get defaultUnit => isImperial ? LengthUnit.inch : LengthUnit.mm;

  /// Unidad con la que mostrar un archivo que declara [file]: en imperial, las métricas pasan a pulgadas; las
  /// demás (pulgadas, pies, píxeles…) se respetan; en métrico no cambia nada.
  static LengthUnit forFile(LengthUnit file) {
    if (!isImperial) return file;
    if (identical(file, LengthUnit.mm) || identical(file, LengthUnit.cm) || identical(file, LengthUnit.m) || identical(file, LengthUnit.um)) {
      return LengthUnit.inch;
    }
    return file;
  }

  /// Símbolo de la longitud corta: «mm» o «in».
  static String get symbol => isImperial ? 'in' : 'mm';

  /// Nombre del sistema para la interfaz.
  static String label(UnitSystem s) => switch (s) {
    UnitSystem.auto => tr('Automático'),
    UnitSystem.metric => tr('Métrico (mm)'),
    UnitSystem.imperial => tr('Imperial (in)'),
  };

  // ---- Números

  /// Igual que `fmtNum` (separador de miles y decimal del idioma).
  static String fmt(double v, {int d = 1}) {
    final s = v.toStringAsFixed(d);
    final parts = s.split('.');
    final ip = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => kThousands);
    return parts.length > 1 ? '$ip${L.decimal}${parts[1]}' : ip;
  }

  /// Decimales para pulgadas: 0,0394 · 0,197 · 3,94 · 39,37 · 393,7.
  static int inDigits(double a) => a >= 100 ? 1 : (a >= 1 ? 2 : (a >= 0.1 ? 3 : 4));

  /// Decimales para áreas y volúmenes en pulgadas cuadradas/cúbicas.
  static int inDigits2(double a) => a >= 1000 ? 1 : (a >= 1 ? 2 : (a >= 0.01 ? 4 : 5));

  // ---- Longitud

  /// Longitud en el estilo de [LengthUnit]: "8,00 mm" · "0,315 in".
  static String len(double mm, {int? digits}) {
    if (!isImperial) return LengthUnit.mm.length(mm, digits: digits);
    return LengthUnit.inch.length(mm, digits: digits);
  }

  /// Tres medidas con la unidad una sola vez.
  static String dims(List<double> mm) {
    if (!isImperial) return LengthUnit.mm.dims(mm);
    final m = mm.map((v) => v.abs()).reduce((a, b) => a > b ? a : b) / kMmPerInch;
    final d = inDigits(m);
    String n(double v) => LengthUnit.numText(v / kMmPerInch, d);
    return '${n(mm[0])} × ${n(mm[1])} × ${n(mm[2])} in';
  }

  /// Longitud en el estilo de `fmtNum` con la unidad: "12,5 mm" · "0,492 in". [d] son los decimales en mm.
  static String mm(double mm, {int d = 1}) {
    if (!isImperial) return '${fmt(mm, d: d)} mm';
    final v = mm / kMmPerInch;
    return '${fmt(v, d: inDigits(v.abs()))} in';
  }

  /// Sólo el número (sin unidad) en la unidad mostrada, con el estilo de `fmtNum`.
  static String number(double mm, {int d = 1}) {
    if (!isImperial) return fmt(mm, d: d);
    final v = mm / kMmPerInch;
    return fmt(v, d: inDigits(v.abs()));
  }

  /// Espesores, alturas de capa y tolerancias: un decimal más en imperial (0,0079 in).
  static String fine(double mm, {int d = 2}) {
    if (!isImperial) return '${fmt(mm, d: d)} mm';
    final v = mm / kMmPerInch;
    return '${fmt(v, d: v.abs() >= 1 ? 3 : 4)} in';
  }

  /// Medida de un diámetro/valor ya redondeado en mm con `toStringAsFixed`, sin separadores de miles.
  /// Equivale a '${mm.toStringAsFixed(d)} mm' en métrico.
  static String plain(double mm, {int d = 1}) {
    if (!isImperial) return '${mm.toStringAsFixed(d)} mm';
    final v = mm / kMmPerInch;
    return '${v.toStringAsFixed(inDigits(v.abs()))} in';
  }

  /// Sólo el número con `toStringAsFixed` (sin separadores de miles) en la unidad mostrada: cotas Z, límites…
  static String plainNum(double mm, {int d = 1}) {
    if (!isImperial) return mm.toStringAsFixed(d);
    final v = mm / kMmPerInch;
    return v.toStringAsFixed(inDigits(v.abs()));
  }

  /// Tres medidas con `toStringAsFixed(d)` y «mm» al final (resúmenes de G-code); en imperial, [dims].
  static String dimsPlain(List<double> mm, {int d = 1}) {
    if (isImperial) return dims(mm);
    return '${mm[0].toStringAsFixed(d)} × ${mm[1].toStringAsFixed(d)} × ${mm[2].toStringAsFixed(d)} mm';
  }

  /// Recorridos largos con `toStringAsFixed`: "12,34 m" / "850 mm" (con punto decimal, como el G-code).
  static String farPlain(double mm) {
    if (!isImperial) return mm >= 10000 ? '${(mm / 1000).toStringAsFixed(2)} m' : '${mm.toStringAsFixed(0)} mm';
    return far(mm);
  }

  /// Longitud de filamento: "1.25 m" (con `toStringAsFixed`) o pies.
  static String filament(double mm) {
    if (!isImperial) return '${(mm / 1000).toStringAsFixed(2)} m';
    return '${(mm / kMmPerInch / 12).toStringAsFixed(1)} ft';
  }

  /// Rango de avances en mm/min: "300 – 1200 mm/min" · "11.8 – 47.2 in/min".
  static String feedRange(double aMmMin, double bMmMin) {
    if (!isImperial) return '${aMmMin.round()} – ${bMmMin.round()} mm/min';
    String n(double v) => (v / kMmPerInch).toStringAsFixed(1);
    return '${n(aMmMin)} – ${n(bMmMin)} in/min';
  }

  /// Distancias grandes (recorridos, nubes de puntos): mm hasta 10 m → m; en imperial pulgadas, pies o millas.
  static String far(double mm, {int d = 2}) {
    if (!isImperial) {
      return mm >= 10000 ? '${fmt(mm / 1000, d: d)} m' : '${fmt(mm, d: mm >= 100 ? 0 : 1)} mm';
    }
    final inch = mm / kMmPerInch;
    if (inch >= 12 * 5280) return '${fmt(inch / (12 * 5280), d: 2)} mi';
    if (inch >= 12 * 30) return '${fmt(inch / 12, d: inch >= 12 * 1000 ? 0 : 1)} ft';
    return '${fmt(inch, d: inDigits(inch.abs()))} in';
  }

  /// Longitud en metros de la escena (nubes de puntos) → m o ft.
  static String meters(double m, {int d = 1}) {
    if (!isImperial) return '${fmt(m, d: d)} m';
    final ft = m * 1000 / kMmPerInch / 12;
    return '${fmt(ft, d: d)} ft';
  }

  // ---- Área y volumen

  static String area(double mm2) {
    if (!isImperial) return LengthUnit.mm.area(mm2);
    final v = mm2 / (kMmPerInch * kMmPerInch);
    return '${LengthUnit.numText(v, inDigits2(v.abs()))} in²';
  }

  static String volume(double mm3) {
    if (!isImperial) return LengthUnit.mm.volume(mm3);
    final v = mm3 / (kMmPerInch * kMmPerInch * kMmPerInch);
    return '${LengthUnit.numText(v, inDigits2(v.abs()))} in³';
  }

  /// Área en cm² (como la usan las hojas de impresión): "12,3 cm²" · "1,9 in²". [d] decimales en cm².
  static String areaCm2(double cm2, {int d = 1}) {
    if (!isImperial) return '${fmt(cm2, d: d)} cm²';
    final v = cm2 * 100 / (kMmPerInch * kMmPerInch);
    return '${fmt(v, d: inDigits2(v.abs()))} in²';
  }

  /// Sólo el número de un área dada en cm² (en in² si es imperial); para plantillas con «cm²» y [tru].
  static String areaCm2N(double cm2, {int d = 1}) {
    if (!isImperial) return fmt(cm2, d: d);
    final v = cm2 * 100 / (kMmPerInch * kMmPerInch);
    return fmt(v, d: inDigits2(v.abs()));
  }

  /// Sólo el número de un volumen dado en cm³ (en in³ si es imperial); para plantillas con «cm³» y [tru].
  static String volumeCm3N(double cm3, {int d = 1}) {
    if (!isImperial) return fmt(cm3, d: d);
    final v = cm3 * 1000 / (kMmPerInch * kMmPerInch * kMmPerInch);
    return fmt(v, d: inDigits2(v.abs()));
  }

  /// Volumen en cm³ ("{v} cm³"): "12,3 cm³" · "0,75 in³".
  static String volumeCm3(double cm3, {int d = 1}) {
    if (!isImperial) return '${fmt(cm3, d: d)} cm³';
    final v = cm3 * 1000 / (kMmPerInch * kMmPerInch * kMmPerInch);
    return '${fmt(v, d: inDigits2(v.abs()))} in³';
  }

  // ---- Masa

  /// Masa a partir de gramos: "12,3 g" · "1,25 kg" → "0,43 oz" · "2,76 lb".
  static String mass(double grams) {
    if (!isImperial) return LengthUnit.mass(grams);
    if (grams >= kGramsPerPound) return '${LengthUnit.numText(grams / kGramsPerPound, 2)} lb';
    final oz = grams / kGramsPerOunce;
    return '${LengthUnit.numText(oz, oz >= 10 ? 1 : 2)} oz';
  }

  /// Masa con `toStringAsFixed(d)` y la g pegada ("12 g"), como en los resúmenes de G-code.
  static String grams(double g, {int d = 1}) {
    if (!isImperial) return '${g.toStringAsFixed(d)} g';
    final oz = g / kGramsPerOunce;
    if (g >= kGramsPerPound) return '${(g / kGramsPerPound).toStringAsFixed(2)} lb';
    return '${oz.toStringAsFixed(oz >= 10 ? 1 : 2)} oz';
  }

  // ---- Velocidad

  /// Avance en mm/min → "1200 mm/min" · "47,2 in/min".
  static String feedMin(double mmPerMin, {int d = 0}) {
    if (!isImperial) return '${mmPerMin.toStringAsFixed(d)} mm/min';
    final v = mmPerMin / kMmPerInch;
    return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} in/min';
  }

  /// Avance en mm/s → "60 mm/s" · "2,36 in/s".
  static String feedSec(double mmPerSec, {int d = 0}) {
    if (!isImperial) return '${mmPerSec.toStringAsFixed(d)} mm/s';
    final v = mmPerSec / kMmPerInch;
    return '${v.toStringAsFixed(v >= 10 ? 1 : 2)} in/s';
  }

  /// Densidad de puntos por m² → número por ft² (0,0929 m² = 1 ft²).
  static double perAreaValue(double perM2) => isImperial ? perM2 * 0.09290304 : perM2;

  // ---- Nubes de puntos (valores en la unidad propia del archivo)

  /// Factor para pasar un valor de la nube a lo que se muestra: en imperial, las nubes en metros (u otra unidad
  /// métrica conocida) pasan a pies; las que ya están en pies, en grados o sin unidad no cambian.
  static double cloudFactor(CloudInfo i) {
    if (!isImperial || i.geographic || i.mmPerUnit == null || i.unit.isEmpty) return 1;
    final m = i.mmPerUnit!;
    if (m >= 304.7 && m <= 304.9) return 1;
    return m / 304.8;
  }

  /// Sufijo de unidad de la nube con espacio inicial: " m", " ft", "°" o "".
  static String cloudLabel(CloudInfo i) {
    if (i.geographic) return '°';
    if (i.unit.isEmpty) return '';
    return cloudFactor(i) == 1 ? ' ${i.unit}' : ' ft';
  }

  /// Densidad (puntos por m²) en la unidad mostrada: por ft² en imperial.
  static double densityValue(double perM2) => isImperial ? perM2 * 0.09290304 : perM2;

  /// Separación media entre puntos en cm (métrico) o en pulgadas (imperial) para [perM2] puntos por m².
  static double spacingValue(double perM2) {
    final cm = 100 / _sqrt(perM2);
    return isImperial ? cm / 2.54 : cm;
  }

  static double _sqrt(double v) {
    var x = v > 1 ? v : 1.0;
    for (var k = 0; k < 40; k++) {
      x = 0.5 * (x + v / x);
    }
    return x;
  }

  // ---- Textos

  /// Como [tr], pero en imperial cambia el «mm» suelto del texto traducido por «in». Los números de los
  /// marcadores ya deben venir convertidos (p. ej. con [number]).
  static String tru(String es, [Map<String, Object?>? args]) {
    final s = tr(es, args);
    if (!isImperial) return s;
    return s.replaceAll(RegExp(r'\bmm\b(?![/²³])'), 'in').replaceAll('cm²', 'in²').replaceAll('cm³', 'in³');
  }

  // ---- Persistencia

  static Future<File> _prefsFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/prefs.json');
  }

  static Future<Map<String, dynamic>> _readPrefs() async {
    try {
      final f = await _prefsFile();
      if (!f.existsSync()) return {};
      final m = jsonDecode(await f.readAsString());
      return m is Map<String, dynamic> ? m : {};
    } catch (_) {
      return {};
    }
  }

  /// Carga la preferencia guardada (si falla se queda en Automático).
  static Future<void> load() async {
    try {
      final m = await _readPrefs();
      final lg = m['lang'];
      if (lg is String) L.apply(lg);
      final name = m['units'];
      for (final s in UnitSystem.values) {
        if (s.name == name) system = s;
      }
    } catch (_) {}
  }

  /// Cambia el sistema y lo guarda (sin historial no pasa nada si falla).
  static Future<void> set(UnitSystem s) async {
    system = s;
    try {
      final m = await _readPrefs();
      m['units'] = s.name;
      final f = await _prefsFile();
      await f.writeAsString(jsonEncode(m));
    } catch (_) {}
  }

  /// Cambia el idioma de la interfaz ('auto' o un código de `L.names`) y lo guarda.
  static Future<void> setLang(String c) async {
    L.apply(c);
    try {
      final m = await _readPrefs();
      m['lang'] = L.choice.value;
      final f = await _prefsFile();
      await f.writeAsString(jsonEncode(m));
    } catch (_) {}
  }
}
