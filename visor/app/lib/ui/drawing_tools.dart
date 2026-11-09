// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../io/dxf_writer.dart';
import '../l10n/l10n.dart';
import '../model/document.dart';
import '../model/drawing_stats.dart';
import '../model/shapes.dart';
import '../model/unit_system.dart';
import '../model/units.dart';
import 'glass.dart';
import 'theme.dart';

/// Estado de las herramientas de un dibujo 2D para corte: unidades, datos de corte y revisión.
class DrawingController extends ChangeNotifier {
  DrawingController(this.doc) {
    final u = _unitOfIns(doc.insUnits);
    unitDeclared = u != null;
    unit = u ?? LengthUnit.mm;
    included = {
      for (final g in doc.lines.groups)
        if (isCutLayer(g.name)) g.name,
    };
  }
  final DrawingDocument doc;

  /// Unidad en la que están los números del archivo (1 unidad del dibujo = `unit`).
  late LengthUnit unit;
  late bool unitDeclared;
  late Set<String> included;
  bool fill = false;
  DrawingProblem? highlight;
  int rotation90 = 0;

  List<Shape>? _shapes;
  DrawingAnalysis? _analysis;

  static LengthUnit? _unitOfIns(int code) => switch (code) {
    1 => LengthUnit.inch,
    2 => LengthUnit.foot,
    4 => LengthUnit.mm,
    5 => LengthUnit.cm,
    6 => LengthUnit.m,
    13 => LengthUnit.um,
    100 => LengthUnit.px96,
    _ => null,
  };

  List<Shape> get shapes => _shapes ??= buildShapes(doc.lines);

  DrawingAnalysis get analysis =>
      _analysis ??= analyzeDrawing(shapes, doc.lines);

  bool get analysed => _analysis != null;

  /// Longitud en el texto: el valor del dibujo con su unidad.
  String len(double v, {int? digits}) =>
      displayUnit.length(v * unit.mmPerUnit, digits: digits);

  String area(double v) => displayUnit.area(v * unit.mmPerUnit * unit.mmPerUnit);

  /// Unidad con la que se muestran las medidas: la del archivo; en imperial, las métricas pasan a pulgadas.
  LengthUnit get displayUnit => Units.forFile(unit);

  /// Problemas, incluida la unidad dudosa.
  List<DrawingProblem> get problems => [
    if (doc.truncated)
      DrawingProblem(
        ProblemKind.incomplete,
        tr('El archivo está incompleto: termina antes de tiempo. ¿Se cortó la descarga o la copia? Falta parte del dibujo.'),
        Float64List(0),
      ),
    ...analysis.problems,
    if (!unitDeclared)
      DrawingProblem(
        ProblemKind.unit,
        tr('El archivo no indica sus unidades: se supone {u}. Compruébalo antes de cortar.', {'u': unit.name}),
        Float64List(0),
      ),
  ];

  /// Texto del aviso con las unidades del archivo.
  String problemText(DrawingProblem p) {
    if (p.kind != ProblemKind.open) return p.text;
    return p.isGap
        ? tr('Contorno abierto: falta cerrar un hueco de {d}', {'d': len(p.value, digits: 3)})
        : tr('Contorno abierto de {d} de longitud', {'d': len(p.value, digits: 1)});
  }

  void setUnit(LengthUnit u) {
    unit = u;
    unitDeclared = true;
    notifyListeners();
  }

  void toggleLayer(String name) {
    included.contains(name) ? included.remove(name) : included.add(name);
    notifyListeners();
  }

  void toggleFill() {
    fill = !fill;
    notifyListeners();
  }

  void show(DrawingProblem? p) {
    highlight = p;
    notifyListeners();
  }

  void rotate90() {
    rotation90 = (rotation90 + 1) % 4;
    notifyListeners();
  }

  /// "N piezas · M agujeros" para la cabecera.
  String get summary {
    final t = analysis.totals(included, doc.lines.groups);
    final parts = <String>[];
    if (t.$1 > 0) parts.add(_piezas(t.$1));
    if (t.$2 > 0) parts.add(_agujeros(t.$2));
    if (t.$3 > 0) parts.add(_abiertos(t.$3));
    return parts.isEmpty ? tr('Sin contornos') : parts.join(' · ');
  }

  bool get readyToCut {
    final t = analysis.totals(included, doc.lines.groups);
    return problems.isEmpty && t.$3 == 0 && t.$1 > 0;
  }

  String csv() {
    final sb = StringBuffer(
      '${tr('Capa;Piezas;Agujeros;Abiertos;Longitud de corte ({u});Perforaciones', {'u': unit.symbol})}\n',
    );
    String n(double v) => v.toStringAsFixed(3).ldec;
    for (final l in analysis.layers.values) {
      sb.writeln(
        '"${l.name}";${l.outer};${l.holes};${l.open};${n(l.length)};${l.pierces}',
      );
    }
    final t = analysis.totals(included, doc.lines.groups);
    sb.writeln(
      '"${tr('TOTAL (capas incluidas)')}";${t.$1};${t.$2};${t.$3};${n(t.$4)};${t.$1 + t.$2 + t.$3}',
    );
    return sb.toString();
  }
}

String _piezas(int n) =>
    n == 1 ? tr('{n} pieza', {'n': n}) : tr('{n} piezas', {'n': n});
String _agujeros(int n) =>
    n == 1 ? tr('{n} agujero', {'n': n}) : tr('{n} agujeros', {'n': n});
String _abiertos(int n) =>
    n == 1 ? tr('{n} abierto', {'n': n}) : tr('{n} abiertos', {'n': n});

// ============================================================ Hojas

Widget _title(String t, {String? sub}) => Padding(
  padding: const EdgeInsets.only(bottom: 12),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        t,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      if (sub != null)
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            sub,
            style: const TextStyle(color: DT.muted, fontSize: 12.5),
          ),
        ),
    ],
  ),
);

Future<void> _sheet(BuildContext context, Widget child) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Glass(
          radius: 26,
          color: const Color(0xEB101B1F),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: child,
        ),
      ),
    ),
  );
}

Widget _metric(String label, String value, {Color? color}) => Expanded(
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0x0FFFFFFF),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: DT.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: DT.muted, fontSize: 11.5)),
        const SizedBox(height: 3),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: TextStyle(
              color: color ?? DT.text,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    ),
  ),
);

/// Datos de corte: contornos, longitud, perforaciones y rendimiento, por capa.
Future<void> showCutSheet(BuildContext context, DrawingController c) {
  return _sheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) {
        final a = c.analysis;
        final groups = c.doc.lines.groups;
        final t = a.totals(c.included, groups);
        final w = a.bounds[2] - a.bounds[0], h = a.bounds[3] - a.bounds[1];
        final boxArea = w * h;
        final yieldPct = boxArea > 0 ? (t.$5 / boxArea * 100) : 0.0;
        return SizedBox(
          height: math.min(640, MediaQuery.of(ctx).size.height * 0.82),
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              _title(
                tr('Datos de corte'),
                sub: c.unitDeclared
                    ? tr('Unidades del archivo: {u}', {'u': c.unit.name})
                    : tr('El archivo no indica unidades: se supone {u}', {'u': c.unit.name}),
              ),
              Row(
                children: [
                  _metric(tr('Longitud de corte'), c.len(t.$4, digits: 1)),
                  const SizedBox(width: 8),
                  _metric(tr('Perforaciones'), '${t.$1 + t.$2 + t.$3}'),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _metric(tr('Piezas'), tr('{n}  ({m} distintas)', {'n': t.$1, 'm': t.$6})),
                  const SizedBox(width: 8),
                  _metric(tr('Agujeros'), '${t.$2}'),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _metric(
                    tr('Contornos abiertos'),
                    '${t.$3}',
                    color: t.$3 > 0 ? DT.orangeSoft : null,
                  ),
                  const SizedBox(width: 8),
                  _metric(
                    tr('Rendimiento de chapa'),
                    '${yieldPct.toStringAsFixed(1).ldec} %',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _metric(
                    tr('Caja envolvente'),
                    '${c.len(w, digits: 1).replaceAll(' ${c.displayUnit.symbol}', '')} × ${c.len(h, digits: 1)}',
                  ),
                  const SizedBox(width: 8),
                  _metric(tr('Área neta'), c.area(t.$5)),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.ios_share, size: 18),
                  label: Text(tr('Guardar DXF de las capas marcadas')),
                  onPressed: () async {
                    final base = c.doc.name.replaceAll(RegExp(r'\.[^.]*$'), '');
                    final bytes = writeDxf(c.doc, layers: c.included, shapes: c.shapes);
                    await FilePicker.saveFile(fileName: '$base.dxf', bytes: bytes);
                  },
                ),
              ),
              const SizedBox(height: 8),
              Text(
                tr('CAPAS QUE SE CORTAN'),
                style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.6,
                  color: DT.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              for (final l in a.layers.values)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: c.included.contains(l.name),
                  onChanged: (_) => c.toggleLayer(l.name),
                  title: Text(l.name.isEmpty ? tr('(sin nombre)') : l.name),
                  subtitle: Text(
                    '${_piezas(l.outer)} · ${_agujeros(l.holes)}'
                    '${l.open > 0 ? ' · ${_abiertos(l.open)}' : ''}',
                    style: const TextStyle(color: DT.muted, fontSize: 12),
                  ),
                  secondary: Text(
                    c.len(l.length, digits: 1),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                tr('LOS NÚMEROS DEL ARCHIVO ESTÁN EN'),
                style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.6,
                  color: DT.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final u in c.doc.insUnits == 100
                      ? [
                          LengthUnit.px96,
                          LengthUnit.pt72,
                          LengthUnit.mm,
                          LengthUnit.inch,
                        ]
                      : [
                          LengthUnit.mm,
                          LengthUnit.cm,
                          LengthUnit.m,
                          LengthUnit.inch,
                        ])
                    ChoiceChip(
                      label: Text(u.name),
                      selected: c.unit.symbol == u.symbol,
                      onSelected: (_) => c.setUnit(u),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: c.csv()));
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(
                          content: Text(tr('Datos copiados (pégalos en Excel)')),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(tr('Copiar datos')),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// Revisión del archivo antes de cortar.
Future<void> showReviewSheet(
  BuildContext context,
  DrawingController c, {
  required void Function(DrawingProblem) onShow,
}) {
  final probs = c.problems;
  final ok = c.readyToCut;
  return _sheet(
    context,
    SizedBox(
      height: math.min(520, 190.0 + probs.length * 78),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(tr('Revisión del archivo')),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: (ok ? DT.mint : DT.orange).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(
                  ok ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                  color: ok ? DT.mint : DT.orangeSoft,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    ok
                        ? tr('Listo para cortar: todos los contornos están cerrados y no hay líneas repetidas.')
                        : probs.length == 1
                        ? tr('{n} aviso que conviene revisar antes de cortar.', {'n': probs.length})
                        : tr('{n} avisos que conviene revisar antes de cortar.', {'n': probs.length}),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.builder(
              itemCount: probs.length,
              itemBuilder: (ctx, i) {
                final p = probs[i];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: DT.orange.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(switch (p.kind) {
                      ProblemKind.open => Icons.gesture_rounded,
                      ProblemKind.duplicate => Icons.layers_rounded,
                      ProblemKind.tiny => Icons.blur_on_rounded,
                      ProblemKind.unit => Icons.straighten_rounded,
                      ProblemKind.incomplete => Icons.cloud_off_rounded,
                    }, color: DT.orangeSoft),
                  ),
                  title: Text(
                    c.problemText(p),
                    style: const TextStyle(fontSize: 14),
                  ),
                  trailing: p.poly.isEmpty
                      ? null
                      : TextButton(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            onShow(p);
                          },
                          child: Text(tr('Ver')),
                        ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
