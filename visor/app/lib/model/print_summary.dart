import 'dart:math' as math;
import 'dart:typed_data';

import '../l10n/l10n.dart';
import 'toolpath.dart';
import 'unit_system.dart';

/// Datos que el lector de G-code recoge mientras recorre el archivo
/// (todo son tipos simples para poder cruzar entre isolates).
class GcodeStats {
  GcodeStats({
    this.meta = const {},
    this.layerSeconds = const [],
    this.featureSeconds = const [],
    this.travelSeconds = 0,
    this.toolMm = const [],
    this.retractions = 0,
    this.nozzleTemps = const [],
    this.bedTemps = const [],
    this.fanMax = 0,
    this.colorChangeLayers = const [],
    this.thumbnail,
    this.thumbnailFormat = 0,
    this.segLine,
    this.segComp,
    this.source,
    this.cnc,
  });

  /// Línea del archivo de cada segmento de trabajo y el texto original (solo programas CNC).
  final Int32List? segLine;

  /// Compensación de radio activa en cada segmento: 1 izquierda (G41), -1 derecha (G42), 0 ninguna.
  final Int8List? segComp;
  final Uint8List? source;
  final CncStats? cnc;
  Int32List? _lineIdx;

  /// Texto de la línea [n] (1-based) del programa, si se conserva el original.
  String? lineText(int n) {
    final src = source;
    if (src == null || n < 1) return null;
    var idx = _lineIdx;
    if (idx == null) {
      final st = <int>[];
      var p = 0;
      while (p < src.length) {
        st.add(p);
        while (p < src.length && src[p] != 10 && src[p] != 13) {
          p++;
        }
        final e = p;
        p++;
        if (e < src.length && src[e] == 13 && p < src.length && src[p] == 10)
          p++;
      }
      idx = _lineIdx = Int32List.fromList(st);
    }
    if (n > idx.length) return null;
    var e = idx[n - 1];
    while (e < src.length && src[e] != 10 && src[e] != 13) {
      e++;
    }
    return String.fromCharCodes(
      src,
      idx[n - 1],
      math.min(e, idx[n - 1] + 120),
    ).trim();
  }

  /// Pares `clave = valor` de los comentarios del archivo (claves en minúsculas).
  final Map<String, String> meta;

  /// Tiempo teórico (longitud / avance, sin aceleraciones) de cada capa, en segundos.
  final List<double> layerSeconds;

  /// Ídem por categoría de movimiento (mismo índice que [kFeatureNames]).
  final List<double> featureSeconds;
  final double travelSeconds;

  /// Filamento empujado por cada herramienta, en mm (según los valores E).
  final List<double> toolMm;
  final int retractions;
  final List<int> nozzleTemps, bedTemps;
  final int fanMax; // 0-255

  /// Capa (0-based) en la que el programa se detiene a cambiar de filamento (M600).
  final List<int> colorChangeLayers;

  /// Miniatura incrustada por el laminador (0 PNG, 1 JPG, 2 QOI).
  final Uint8List? thumbnail;
  final int thumbnailFormat;
}

class CncTool {
  CncTool(this.number, this.line, this.comment);
  final int number;
  final int line;
  final String? comment;
}

/// Lo que un operario de CNC revisa antes de cargar el programa en la máquina.
class CncStats {
  CncStats({
    required this.tools,
    required this.rapidMm,
    required this.cutMm,
    required this.rapidPlunges,
    required this.firstPlungeLine,
    required this.spindleMin,
    required this.spindleMax,
    required this.envMin,
    required this.envMax,
    required this.units,
    required this.coolant,
    required this.lineCount,
    required this.noSpindle,
    this.usesFlow = false,
    this.cutterComp = false,
    this.wcsCount = 0,
    this.toolSeconds = const [],
    this.toolCutMm = const [],
  });
  final List<CncTool> tools;
  final double rapidMm, cutMm;

  /// Bajadas en avance rápido (G0) por debajo de Z0: causa clásica de colisiones.
  final int rapidPlunges;
  final int firstPlungeLine;
  final double spindleMin, spindleMax;
  final List<double> envMin, envMax; // todos los movimientos, incluidos rápidos
  final String? units;
  final bool coolant;
  final int lineCount;

  /// Hay corte pero ningún M3/M4.
  final bool noSpindle;

  /// Estructuras de control que Datum no sabe seguir (el recorrido puede estar incompleto).
  final bool usesFlow;

  /// Usa G41/G42: el recorrido mostrado es la línea central, sin el radio de la fresa.
  final bool cutterComp;

  /// Sistemas de coordenadas de trabajo distintos (G54–G59, G154…) usados.
  final int wcsCount;

  /// Tiempo teórico y recorrido de corte de cada herramienta (índice = nº de T).
  final List<double> toolSeconds, toolCutMm;
}

/// Duración «1d 2h 3m 4s» → segundos.
double? parseDuration(String s) {
  var total = 0.0;
  var any = false;
  for (final m in RegExp(r'(\d+(?:\.\d+)?)\s*([dhms])').allMatches(s)) {
    final v = double.parse(m.group(1)!);
    total +=
        v *
        switch (m.group(2)) {
          'd' => 86400,
          'h' => 3600,
          'm' => 60,
          _ => 1,
        };
    any = true;
  }
  return any ? total : null;
}

String formatDuration(double sec) {
  final s = sec.round();
  final d = s ~/ 86400, h = (s % 86400) ~/ 3600, m = (s % 3600) ~/ 60;
  if (d > 0) return '${d}d ${h}h ${m}m';
  if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
  if (m > 0) return '${m}m ${(s % 60).toString().padLeft(2, '0')}s';
  return '${s}s';
}

/// Un filamento utilizado en la impresión.
class FilamentUse {
  FilamentUse({
    required this.index,
    required this.mm,
    required this.grams,
    this.type,
    this.color,
    this.nozzleTemp,
    this.bedTemp,
  });
  final int index;
  final double mm;
  final double grams;
  final String? type;
  final int? color;
  final int? nozzleTemp, bedTemp;
}

/// Ficha de la impresión: lo que el operario de la máquina quiere saber antes de pulsar «imprimir».
/// Combina lo que declara el laminador con lo medido sobre las trayectorias.
class PrintSummary {
  PrintSummary._({
    required this.slicer,
    required this.printer,
    required this.seconds,
    required this.secondsFromSlicer,
    required this.filaments,
    required this.layerHeight,
    required this.firstLayerHeight,
    required this.nozzle,
    required this.infill,
    required this.walls,
    required this.supports,
    required this.cost,
    required this.retractions,
    required this.fanPercent,
    required this.timeScale,
    required this.extras,
  });

  final String? slicer, printer;

  /// Tiempo total de impresión; [secondsFromSlicer] indica si lo declara el laminador.
  final double? seconds;
  final bool secondsFromSlicer;
  final List<FilamentUse> filaments;
  final double? layerHeight, firstLayerHeight, nozzle;
  final String? infill;
  final int? walls;
  final bool? supports;
  final double? cost;
  final int retractions;
  final int? fanPercent;

  /// Factor que lleva el tiempo teórico acumulado al tiempo del laminador.
  final double timeScale;

  /// El tiempo teórico se acerca al del laminador: los porcentajes por tipo son fiables.
  bool get timeReliable => timeScale > 0.75 && timeScale < 1.4;
  final List<(String, String)> extras;

  double get totalGrams => filaments.fold(0.0, (a, f) => a + f.grams);
  double get totalMm => filaments.fold(0.0, (a, f) => a + f.mm);

  /// Segundos transcurridos al terminar la capa [layer] (0-based).
  double elapsedAt(Toolpath t, int layer) {
    final ls = t.stats.layerSeconds;
    var acc = 0.0;
    for (var i = 0; i <= layer && i < ls.length; i++) {
      acc += ls[i];
    }
    return acc * timeScale;
  }

  static List<String> _list(String? v) => v == null
      ? const []
      : v
            .split(RegExp(r'[;,]'))
            .map((e) => e.trim().replaceAll('"', ''))
            .where((e) => e.isNotEmpty)
            .toList();

  static double? _num(String? v) {
    if (v == null) return null;
    final m = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(v);
    return m == null ? null : double.parse(m.group(0)!);
  }

  static String? _first(Map<String, String> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  /// Densidades habituales (g/cm³) cuando el archivo no la declara.
  static double _density(String? type) => switch (type?.toUpperCase()) {
    'PLA' => 1.24,
    'PETG' => 1.27,
    'ABS' => 1.04,
    'ASA' => 1.07,
    'TPU' => 1.21,
    'PA' || 'NYLON' => 1.14,
    'PC' => 1.20,
    _ => 1.24,
  };

  static PrintSummary of(Toolpath t) {
    final st = t.stats;
    final m = st.meta;

    // --- laminador e impresora
    String? slicer = _first(m, ['generator', 'generated with']);
    if (slicer == null) {
      for (final s in t.info) {
        final r = RegExp(
          r'(PrusaSlicer|OrcaSlicer|BambuStudio|Bambu Studio|SuperSlicer|Cura|Simplify3D|IdeaMaker|Slic3r)[^\n]*?(\d+\.\d+(?:\.\d+)*)?',
          caseSensitive: false,
        ).firstMatch(s);
        if (r != null) {
          slicer = r.group(0)!.trim();
          break;
        }
      }
    }
    final printer = _first(m, [
      'printer_model',
      'target_machine.name',
      'printer_settings_id',
    ]);

    // --- tiempo
    double? seconds;
    var fromSlicer = false;
    for (final k in [
      'total estimated time',
      'estimated printing time (normal mode)',
      'estimated printing time',
      'model printing time',
      'print.time',
      'build time',
      'time',
      'print time',
    ]) {
      final v = m[k];
      if (v == null) continue;
      final d = (k == 'time' || k == 'print.time') ? _num(v) : parseDuration(v);
      if (d != null && d > 0) {
        seconds = d;
        fromSlicer = true;
        break;
      }
    }
    final computed = st.layerSeconds.fold(0.0, (a, b) => a + b);
    seconds ??= computed > 0 ? computed : null;
    final scale = fromSlicer && computed > 0 ? seconds! / computed : 1.0;

    // --- material por herramienta
    final types = _list(m['filament_type']);
    final dens = _list(m['filament_density']).map(double.tryParse).toList();
    final diam = _list(m['filament_diameter']).map(double.tryParse).toList();
    final nozT = _list(
      _first(m, ['nozzle_temperature', 'temperature']),
    ).map(int.tryParse).toList();
    final bedT = _list(
      _first(m, [
        'hot_plate_temp',
        'bed_temperature',
        'first_layer_bed_temperature',
      ]),
    ).map(int.tryParse).toList();
    var declMm = _list(
      _first(m, ['total filament length [mm]', 'filament used [mm]']),
    ).map(double.tryParse).toList();
    if (declMm.isEmpty) {
      // Cura: «Filament used: 3.4m»; Simplify3D: «Filament length: 99908.9 mm (99.91 m)».
      final cura = m['filament used'] ?? m['filament length'];
      if (cura != null) {
        declMm = [
          for (final t in cura.split(RegExp(r'[;,]')))
            if (RegExp(r'-?\d').hasMatch(t))
              (_num(t) ?? 0) *
                  (RegExp(r'\d\s*m\b').hasMatch(t.split('(').first) ? 1000 : 1),
        ];
      }
    }
    if (declMm.isEmpty) {
      // Ultimaker: volumen por extrusor en mm³.
      for (var i = 0; i < 4; i++) {
        final v = _num(m['extruder_train.$i.material.volume_used']);
        if (v != null) declMm.add(v / (math.pi * 0.875 * 0.875));
      }
    }
    final declG = _list(
      _first(m, [
        'total filament weight [g]',
        'filament used [g]',
        'plastic weight',
      ]),
    ).map(_num).toList();

    final filaments = <FilamentUse>[];
    final active = [
      for (var i = 0; i < st.toolMm.length; i++)
        if (st.toolMm[i] > 1) i,
    ];
    // Si el laminador da un solo total pero se usaron varias herramientas,
    // el reparto se toma de lo medido y se escala al total declarado.
    final totalOnly = declMm.length == 1 && active.length > 1;
    final measuredSum = active.fold(0.0, (a, i) => a + st.toolMm[i]);
    final tools = totalOnly
        ? st.toolMm.length
        : math.max(st.toolMm.length, declMm.length);
    final declGTotal = declG.length == 1 && (totalOnly || active.length > 1)
        ? declG.first
        : null;
    for (var i = 0; i < tools; i++) {
      final measured = i < st.toolMm.length ? st.toolMm[i] : 0.0;
      final mm = totalOnly
          ? (measuredSum > 0
                ? (declMm.first ?? 0) * measured / measuredSum
                : 0.0)
          : (i < declMm.length ? declMm[i] : null) ?? measured;
      if (mm < 1) continue;
      final type = i < types.length
          ? types[i]
          : (types.isNotEmpty ? types.first : null);
      final d = (i < diam.length ? diam[i] : null) ?? 1.75;
      final rho = (i < dens.length ? dens[i] : null) ?? _density(type);
      final g = declGTotal != null
          ? declGTotal *
                mm /
                (totalOnly ? (declMm.first ?? 1.0) : math.max(1.0, measuredSum))
          : (i < declG.length ? declG[i] : null) ??
                mm * math.pi * math.pow(d / 2, 2) * rho / 1000;
      filaments.add(
        FilamentUse(
          index: i,
          mm: mm,
          grams: g,
          type: type,
          color: i < t.toolColors.length ? t.toolColors[i] : null,
          nozzleTemp: i < nozT.length
              ? nozT[i]
              : (nozT.length == 1 ? nozT[0] : null),
          bedTemp: i < bedT.length
              ? bedT[i]
              : (bedT.length == 1 ? bedT[0] : null),
        ),
      );
    }

    // --- ajustes de laminado
    final lh = _num(_first(m, ['layer_height', 'layer height', 'layerheight']));
    final flh = _num(
      _first(m, [
        'initial_layer_print_height',
        'first_layer_height',
        'initial layer height',
      ]),
    );
    final noz = _num(
      _first(m, [
        'nozzle_diameter',
        'machine_nozzle_size',
        'extruder_train.0.nozzle.diameter',
        'extruderdiameter',
      ]),
    );
    final infill = _first(m, [
      'infillpercentage',
      'sparse_infill_density',
      'fill_density',
      'infill_sparse_density',
    ]);
    final walls = _num(
      _first(m, ['wall_loops', 'perimeters', 'wall_line_count']),
    )?.round();
    final sup = _first(m, [
      'enable_support',
      'support_material',
      'support_enable',
    ]);
    final cost = _num(
      _first(m, ['total filament cost', 'filament cost', 'material cost']),
    );

    final extras = <(String, String)>[];
    final mat = _first(m, ['filament_settings_id']);
    if (mat != null && _list(mat).isNotEmpty) {
      extras.add((tr('Perfil de material'), _list(mat).toSet().join(', ')));
    }
    final bed = _first(m, ['curr_bed_type', 'bed_type']);
    if (bed != null) extras.add((tr('Plato'), bed.replaceAll('"', '')));
    final brim = _num(_first(m, ['brim_width']));
    if (brim != null && brim > 0)
      extras.add((tr('Borde (brim)'), Units.isImperial ? Units.fine(brim) : '${_g(brim)} mm'));
    final spd = _first(m, ['outer_wall_speed', 'perimeter_speed']);
    if (spd != null)
      extras.add((tr('Vel. pared exterior'), Units.isImperial ? Units.feedSec(_num(spd) ?? 0) : '${_g(_num(spd) ?? 0)} mm/s'));

    return PrintSummary._(
      slicer: slicer,
      printer: printer?.replaceAll('"', ''),
      seconds: seconds,
      secondsFromSlicer: fromSlicer,
      filaments: filaments,
      layerHeight: lh,
      firstLayerHeight: flh,
      nozzle: noz,
      infill: infill,
      walls: walls,
      supports: sup == null
          ? null
          : (sup == '1' || sup.toLowerCase() == 'true'),
      cost: cost != null && cost > 0 ? cost : null,
      retractions: st.retractions,
      fanPercent: st.fanMax > 0 ? (st.fanMax * 100 / 255).round() : null,
      timeScale: scale,
      extras: extras,
    );
  }

  static String _g(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
}
