// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../io/qoi.dart';
import '../l10n/l10n.dart';
import '../model/print_summary.dart';
import '../model/stock_sim.dart';
import '../model/toolpath.dart';
import 'glass.dart';
import 'theme.dart';
import '../model/unit_system.dart';

Color _c(int rgb) => Color(0xFF000000 | rgb);

TextStyle _label() => const TextStyle(
  fontSize: 11.5,
  letterSpacing: 1.6,
  color: DT.muted,
  fontWeight: FontWeight.w600,
);

/// Tarjeta inferior del visor de G-code: capa actual, tiempo, rango de capas con reproducción,
/// leyenda del color en uso y modos de color.
class GcodeCard extends StatelessWidget {
  const GcodeCard({
    super.key,
    required this.toolpath,
    required this.lo,
    required this.hi,
    required this.frac,
    required this.playing,
    required this.hidden,
    required this.onRange,
    required this.onPlay,
    required this.onMode,
    required this.onHidden,
  });
  final Toolpath toolpath;
  final int lo, hi;
  final double frac;
  final bool playing;
  final Set<int> hidden;
  final void Function(int lo, int hi) onRange;
  final VoidCallback onPlay;
  final void Function(ToolpathColorMode) onMode;
  final void Function(Set<int>) onHidden;

  @override
  Widget build(BuildContext context) {
    final t = toolpath;
    final n = t.layerCount;
    final s = t.summary;
    final z = t.layerZ.isEmpty
        ? 0.0
        : t.layerZ[hi.clamp(0, t.layerZ.length - 1)];
    final prevZ = hi > 0 && hi - 1 < t.layerZ.length ? t.layerZ[hi - 1] : 0.0;
    final lh = hi > 0 ? z - prevZ : z;
    final elapsed = s.elapsedAt(t, hi);
    final modes = [
      if (t.isFdm && t.featureCounts().where((c) => c > 0).length >= 2)
        (ToolpathColorMode.feature, tr('Tipo')),
      if (t.isFdm && s.filaments.length > 1)
        (ToolpathColorMode.tool, tr('Filamento')),
      (ToolpathColorMode.speed, tr('Velocidad')),
      if (t.isFdm) (ToolpathColorMode.flow, tr('Flujo')),
      (ToolpathColorMode.height, tr('Altura')),
      (ToolpathColorMode.flat, tr('Liso')),
    ];
    return Glass(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${hi + 1}',
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w300,
                    height: 1,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  ' / $n',
                  style: const TextStyle(color: DT.muted, fontSize: 14),
                ),
                const SizedBox(width: 12),
                Text(
                  'Z ${Units.plainNum(z, d: 2)}',
                  style: const TextStyle(
                    color: DT.mint,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (s.seconds != null)
                  Flexible(
                    child: Text(
                      '${s.secondsFromSlicer ? '' : '≈ '}${formatDuration(elapsed)}',
                      style: const TextStyle(
                        color: DT.muted,
                        fontSize: 13,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          Row(
            children: [
              IconButton(
                tooltip: playing ? tr('Pausar') : tr('Reproducir la impresión'),
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: DT.orange,
                ),
                onPressed: onPlay,
              ),
              Expanded(
                child: n < 2
                    ? const SizedBox(height: 40)
                    : SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          rangeTickMarkShape:
                              const RoundRangeSliderTickMarkShape(
                                tickMarkRadius: 0,
                              ),
                        ),
                        child: RangeSlider(
                          values: RangeValues(lo.toDouble(), hi.toDouble()),
                          min: 0,
                          max: (n - 1).toDouble(),
                          divisions: n - 1,
                          onChanged: (v) =>
                              onRange(v.start.round(), v.end.round()),
                        ),
                      ),
              ),
              IconButton(
                tooltip: lo == hi
                    ? tr('Mostrar todas las capas')
                    : tr('Solo esta capa'),
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  lo == hi ? Icons.layers_rounded : Icons.layers_outlined,
                  color: lo == hi ? DT.orange : DT.muted,
                ),
                onPressed: () => lo == hi ? onRange(0, hi) : onRange(hi, hi),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 8),
            child: GcodeLegend(toolpath: t, hidden: hidden, onHidden: onHidden),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 6),
            child: Row(
              children: [
                for (final (m, label) in modes)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: t.mode == m,
                      onSelected: (_) => onMode(m),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Leyenda del color en uso: tipos (tocables para ocultarlos), filamentos o degradado.
class GcodeLegend extends StatelessWidget {
  const GcodeLegend({
    super.key,
    required this.toolpath,
    required this.hidden,
    required this.onHidden,
  });
  final Toolpath toolpath;
  final Set<int> hidden;
  final void Function(Set<int>) onHidden;

  Widget _gradient(List<Color> colors, String a, String b) {
    return Row(
      children: [
        Text(a, style: const TextStyle(fontSize: 12, color: DT.muted)),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 8,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: LinearGradient(colors: colors),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(b, style: const TextStyle(fontSize: 12, color: DT.muted)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = toolpath;
    final s = t.summary;
    switch (t.mode) {
      case ToolpathColorMode.feature:
        final counts = t.featureCounts();
        final secs = t.stats.featureSeconds;
        final total = secs.fold(0.0, (a, b) => a + b) + t.stats.travelSeconds;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (var i = 0; i < kFeatureNames.length; i++)
                if (counts[i] > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => onHidden(
                        hidden.contains(i)
                            ? ({...hidden}..remove(i))
                            : {...hidden, i},
                      ),
                      child: Opacity(
                        opacity: hidden.contains(i) ? 0.35 : 1,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: _c(kFeatureColors[i]),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                tr(kFeatureNames[i]) +
                                    (s.timeReliable &&
                                            total > 0 &&
                                            secs[i] / total >= 0.005
                                        ? ' ${(secs[i] * 100 / total).round()}%'
                                        : ''),
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        );
      case ToolpathColorMode.tool when !t.isFdm:
        final tools = {
          for (final c in t.stats.cnc?.tools ?? <CncTool>[]) c.number: c,
        };
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final e in tools.values)
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _c(kToolColors[e.number % kToolColors.length]),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'T${e.number}${e.comment != null ? ' ${e.comment}' : ''}',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      case ToolpathColorMode.tool:
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final f in s.filaments)
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _c(
                            f.color ??
                                kToolColors[f.index % kToolColors.length],
                          ),
                          shape: BoxShape.circle,
                          border: Border.all(color: DT.border),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'T${f.index + 1}${f.type != null ? ' ${f.type}' : ''} · ${Units.grams(f.grams, d: 0)}',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      case ToolpathColorMode.speed:
        final (a, b) = t.speedRange;
        return _gradient(
          const [Color(0xFF0000FF), Color(0xFF00FF80), Color(0xFFFF0000)],
          t.isFdm ? Units.feedSec(a) : Units.feedMin(a * 60),
          t.isFdm ? Units.feedSec(b) : Units.feedMin(b * 60),
        );
      case ToolpathColorMode.flow:
        return _gradient(
          [_c(0x38BDF8), _c(0xF43F5E)],
          '0 mm³/s',
          '${t.flowMax.toStringAsFixed(1)} mm³/s',
        );
      case ToolpathColorMode.height:
        final bz = t.bounds;
        return _gradient(
          [_c(0xFB923C), _c(0x5EEAD4)],
          'Z ${Units.plainNum(bz.min[2])}',
          'Z ${Units.plainNum(bz.max[2])}',
        );
      case ToolpathColorMode.flat:
        return const SizedBox.shrink();
    }
  }
}

/// Ficha lateral: tiempo, material, ajustes de laminado y datos del archivo.
class GcodeInfoPanel extends StatelessWidget {
  const GcodeInfoPanel({
    super.key,
    required this.toolpath,
    required this.hidden,
    required this.onHidden,
    required this.onLayer,
  });
  final void Function(int layer) onLayer;
  final Toolpath toolpath;
  final Set<int> hidden;
  final void Function(Set<int>) onHidden;

  Widget _row(String k, String v, {Widget? lead}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lead != null) ...[lead, const SizedBox(width: 8)],
        Expanded(
          flex: 5,
          child: Text(
            k,
            style: const TextStyle(color: DT.muted, fontSize: 13.5),
          ),
        ),
        Expanded(
          flex: 6,
          child: Text(
            v,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13.5),
          ),
        ),
      ],
    ),
  );

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 4),
    child: Text(t, style: _label()),
  );

  @override
  Widget build(BuildContext context) {
    final t = toolpath;
    final s = t.summary;
    final size = t.bounds.size;
    final counts = t.featureCounts();
    final secs = t.stats.featureSeconds;
    final total = secs.fold(0.0, (a, b) => a + b) + t.stats.travelSeconds;
    final st = t.stats;
    final multi = s.filaments.length > 1;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            t.isFdm ? tr('Ficha de impresión') : tr('Ficha del programa'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          if (s.printer != null || s.slicer != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                [s.printer, s.slicer].whereType<String>().join(' · '),
                style: const TextStyle(color: DT.muted),
              ),
            ),
          if (st.thumbnail != null)
            ThumbView(bytes: st.thumbnail!, format: st.thumbnailFormat),
          _section(tr('RESUMEN')),
          if (s.seconds != null)
            _row(
              s.secondsFromSlicer ? tr('Tiempo de impresión') : tr('Tiempo estimado'),
              (s.secondsFromSlicer ? '' : '≈ ') + formatDuration(s.seconds!),
            ),
          if (s.filaments.isNotEmpty) ...[
            _row(
              tr('Filamento'),
              '${Units.grams(s.totalGrams)} · ${Units.filament(s.totalMm)}',
            ),
          ],
          if (s.cost != null)
            _row(tr('Coste de material'), s.cost!.toStringAsFixed(2)),
          _row(
            tr('Tamaño'),
            Units.dimsPlain(size),
          ),
          _row(tr('Capas'), '${t.layerCount}'),
          if (s.retractions > 0) _row(tr('Retracciones'), '${s.retractions}'),
          if (s.filaments.isNotEmpty) ...[
            _section(multi ? tr('MATERIALES') : tr('MATERIAL')),
            for (final f in s.filaments)
              _row(
                multi ? 'T${f.index + 1}' : (f.type ?? tr('Filamento')),
                [
                  if (multi && f.type != null) f.type!,
                  Units.grams(f.grams),
                  if (f.nozzleTemp != null) '${f.nozzleTemp}°',
                  if (f.bedTemp != null) tr('cama {n}°', {'n': f.bedTemp}),
                ].join(' · '),
                lead: multi
                    ? Container(
                        width: 14,
                        height: 14,
                        margin: const EdgeInsets.only(top: 2),
                        decoration: BoxDecoration(
                          color: _c(
                            f.color ??
                                kToolColors[f.index % kToolColors.length],
                          ),
                          shape: BoxShape.circle,
                          border: Border.all(color: DT.border),
                        ),
                      )
                    : null,
              ),
          ],
          if (s.layerHeight != null ||
              s.nozzle != null ||
              s.infill != null) ...[
            _section(tr('LAMINADO')),
            if (s.layerHeight != null)
              _row(
                tr('Altura de capa'),
                Units.isImperial
                    ? '${Units.fine(s.layerHeight!)}${s.firstLayerHeight != null && (s.firstLayerHeight! - s.layerHeight!).abs() > 0.001 ? ' (${tr('1ª: {h}', {'h': Units.fine(s.firstLayerHeight!)})})' : ''}'
                    : '${s.layerHeight} mm${s.firstLayerHeight != null && (s.firstLayerHeight! - s.layerHeight!).abs() > 0.001 ? ' (${tr('1ª: {h}', {'h': s.firstLayerHeight})})' : ''}',
              ),
            if (s.nozzle != null) _row(tr('Boquilla'), Units.isImperial ? Units.fine(s.nozzle!) : '${s.nozzle} mm'),
            if (s.walls != null) _row(tr('Paredes'), '${s.walls}'),
            if (s.infill != null) _row(tr('Relleno'), s.infill!),
            if (s.supports != null) _row(tr('Soportes'), s.supports! ? tr('Sí') : tr('No')),
            if (s.fanPercent != null)
              _row(tr('Ventilador máx.'), '${s.fanPercent}%'),
            for (final (k, v) in s.extras) _row(k, v),
          ],
          ...() {
            final w = t.extrusionWidths();
            final rows = <Widget>[];
            for (var k = 0; k < w.length; k++) {
              final v = w[k];
              if (v == null || k == 0) continue;
              final nz = s.nozzle;
              final rel = nz != null && nz > 0 ? ' (${v >= nz ? '+' : '−'}${tr('{p} % sobre la boquilla', {'p': ((v / nz - 1).abs() * 100).round()})})' : '';
              rows.add(_row(tr(kFeatureNames[k]), '≈ ${Units.fine(v)}$rel'));
            }
            if (rows.isEmpty) return <Widget>[];
            return [_section(tr('ANCHURA REAL DE EXTRUSIÓN (ESTIMADA)')), ...rows];
          }(),
          if (st.colorChangeLayers.isNotEmpty) ...[
            _section(tr('PARADAS PARA CAMBIAR FILAMENTO')),
            for (final l in st.colorChangeLayers.take(30))
              InkWell(
                onTap: () => onLayer(l.clamp(0, t.layerCount - 1)),
                child: _row(
                  tr('Capa {n}', {'n': l + 1}),
                  'Z ${Units.plainNum(t.layerZ[l.clamp(0, t.layerZ.length - 1)], d: 2)}'
                      '${s.seconds != null ? ' · ${tr('tras {t}', {'t': formatDuration(s.elapsedAt(t, math.max(0, l - 1)))})}' : ''}',
                ),
              ),
          ],
          if (t.layerCount > 2 && st.layerSeconds.length == t.layerCount) ...[
            _section(tr('TIEMPO POR CAPA')),
            LayerTimeChart(
              seconds: [for (final v in st.layerSeconds) v * s.timeScale],
              onLayer: onLayer,
            ),
          ],
          if (t.isFdm) ...[
            _section(tr('QUÉ MOSTRAR')),
            for (var i = 0; i < kFeatureNames.length; i++)
              if (counts[i] > 0)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeTrackColor: DT.orange,
                  title: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _c(kFeatureColors[i]),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(tr(kFeatureNames[i]))),
                      if (s.timeReliable && total > 0)
                        Text(
                          '${math.max(1, (secs[i] * 100 / total).round())}%',
                          style: const TextStyle(
                            color: DT.muted,
                            fontSize: 12.5,
                          ),
                        ),
                    ],
                  ),
                  value: !hidden.contains(i),
                  onChanged: (on) =>
                      onHidden(on ? ({...hidden}..remove(i)) : {...hidden, i}),
                ),
          ],
          if (t.info.isNotEmpty || st.meta.isNotEmpty)
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(tr('DATOS DEL ARCHIVO'), style: _label()),
                children: [
                  for (final e in st.meta.entries.take(120))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${e.key}: ${e.value}',
                        style: const TextStyle(fontSize: 11.5, color: DT.muted),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Tarjeta inferior para programas de CNC: línea de código en curso, avance del programa y color.
class CncCard extends StatelessWidget {
  const CncCard({
    super.key,
    required this.toolpath,
    required this.progress,
    required this.playing,
    required this.onProgress,
    required this.onPlay,
    required this.onMode,
    required this.stock,
    required this.onStock,
  });
  final bool stock;
  final VoidCallback onStock;
  final Toolpath toolpath;
  final double progress;
  final bool playing;
  final void Function(double) onProgress;
  final VoidCallback onPlay;
  final void Function(ToolpathColorMode) onMode;

  @override
  Widget build(BuildContext context) {
    final t = toolpath;
    final st = t.stats;
    final total = t.paths.segmentCount;
    final seg = (progress * total).round().clamp(0, total);
    final line = seg == 0 || st.segLine == null ? 0 : st.segLine![seg - 1];
    final text = line == 0 ? null : st.lineText(line);
    final s = t.summary;
    final toolsN = {
      for (final c in st.cnc?.tools ?? <CncTool>[]) c.number,
    }.length;
    final modes = [
      (ToolpathColorMode.speed, tr('Avance')),
      (ToolpathColorMode.height, tr('Profundidad')),
      if (toolsN > 1) (ToolpathColorMode.tool, tr('Herramienta')),
      (ToolpathColorMode.flat, tr('Liso')),
    ];
    return Glass(
      radius: 26,
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  line == 0 ? tr('Inicio') : tr('Línea {n}', {'n': line}),
                  style: const TextStyle(
                    color: DT.mint,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 13,
                      color: DT.text,
                    ),
                  ),
                ),
                if (s.seconds != null) ...[
                  const SizedBox(width: 10),
                  Text(
                    '≈ ${formatDuration(s.seconds! * progress)}',
                    style: const TextStyle(color: DT.muted, fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
          Row(
            children: [
              IconButton(
                tooltip: playing ? tr('Pausar') : tr('Simular el recorrido'),
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: DT.orange,
                ),
                onPressed: onPlay,
              ),
              Expanded(
                child: Slider(value: progress, onChanged: onProgress),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 8),
            child: GcodeLegend(toolpath: t, hidden: const {}, onHidden: (_) {}),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 6),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    avatar: const Icon(Icons.view_in_ar_outlined, size: 18),
                    label: Text(tr('Material')),
                    selected: stock,
                    onSelected: (_) => onStock(),
                    selectedColor: DT.mint.withValues(alpha: 0.2),
                  ),
                ),
                for (final (m, label) in modes)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: t.mode == m,
                      onSelected: (_) => onMode(m),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Ficha lateral de un programa CNC.
class CncInfoPanel extends StatelessWidget {
  const CncInfoPanel({
    super.key,
    required this.toolpath,
    required this.sim,
    required this.onDiameter,
  });
  final Toolpath toolpath;
  final StockSim sim;
  final void Function(int tool, double diameter) onDiameter;

  Widget _row(String k, String v, {Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 4,
          child: Text(
            k,
            style: const TextStyle(color: DT.muted, fontSize: 13.5),
          ),
        ),
        Expanded(
          flex: 7,
          child: Text(
            v,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 13.5, color: color),
          ),
        ),
      ],
    ),
  );

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 4),
    child: Text(t, style: _label()),
  );

  Future<void> _editDiameter(BuildContext context, int tool) async {
    final imperial = Units.isImperial;
    final ctl = TextEditingController(
      text: imperial
          ? (sim.diameterOf(tool) / kMmPerInch).toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '')
          : sim
                .diameterOf(tool)
                .toStringAsFixed(sim.diameterOf(tool) % 1 == 0 ? 0 : 2),
    );
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Diámetro de la herramienta T{n}', {'n': tool})),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(suffixText: Units.symbol),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('Cancelar')),
          ),
          FilledButton(
            onPressed: () {
              final x = double.tryParse(ctl.text.replaceAll(',', '.'));
              Navigator.pop(ctx, x == null ? null : (imperial ? x * kMmPerInch : x));
            },
            child: Text(tr('Aceptar')),
          ),
        ],
      ),
    );
    if (v != null && v > 0 && v < 500) onDiameter(tool, v);
  }

  String _len(double mm) => Units.farPlain(mm);

  @override
  Widget build(BuildContext context) {
    final t = toolpath;
    final c = t.stats.cnc!;
    final s = t.summary;
    final (fa, fb) = t.speedRange;
    String ax(int i) =>
        '${Units.plainNum(c.envMin[i], d: 2)}  →  ${Units.plainNum(c.envMax[i], d: 2)}';
    final warns = <(String, String)>[
      if (c.rapidPlunges > 0)
        (
          tr('Bajada en rápido (G0) dentro del material'),
          c.rapidPlunges == 1
              ? tr('1 vez, primera en la línea {l}', {'l': c.firstPlungeLine})
              : tr('{n} veces, primera en la línea {l}', {'n': c.rapidPlunges, 'l': c.firstPlungeLine}),
        ),
      if (c.noSpindle)
        (tr('El programa no enciende el husillo'), tr('No hay M3 ni M4')),
      if (c.units == null)
        (tr('No declara unidades'), tr('Se interpretan como mm (falta G20/G21)')),
      if (c.wcsCount > 1)
        (
          tr('Usa {n} sistemas de coordenadas (G54…)', {'n': c.wcsCount}),
          tr('Se dibujan todos sobre el mismo origen: no se aplica su desplazamiento'),
        ),
      if (c.units == null &&
          (c.envMax[0] - c.envMin[0]) < 12 &&
          (c.envMax[1] - c.envMin[1]) < 12)
        (
          tr('Tamaño muy pequeño para mm'),
          tr('¿Está en pulgadas? Sin G20/G21 no se puede saber'),
        ),
      if (c.cutterComp)
        (
          tr('Compensación de radio (G41/G42)'),
          tr('El material se talla desplazando la fresa un radio; las líneas muestran el trazado programado'),
        ),
      if (c.usesFlow)
        (
          tr('Lógica de programa no soportada'),
          tr('El recorrido puede estar incompleto'),
        ),
    ];
    final tools = <int, CncTool>{};
    for (final e in c.tools) {
      tools.putIfAbsent(e.number, () => e);
    }
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            tr('Ficha del programa'),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              c.units == 'in'
                  ? (Units.isImperial ? tr('Programado en pulgadas') : tr('Programado en pulgadas (mostrado en mm)'))
                  : (Units.isImperial ? tr('Programado en mm (mostrado en pulgadas)') : tr('Programado en mm')),
              style: const TextStyle(color: DT.muted),
            ),
          ),
          _section(tr('AVISOS')),
          if (warns.isEmpty)
            Row(
              children: [
                const Icon(Icons.check_circle_outline, size: 18, color: DT.mint),
                const SizedBox(width: 8),
                Text(tr('Sin avisos'), style: const TextStyle(color: DT.mint)),
              ],
            )
          else
            for (final (k, v) in warns)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: DT.orangeSoft,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(k, style: const TextStyle(fontSize: 13.5)),
                          Text(
                            v,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: DT.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          _section(tr('RESUMEN')),
          if (s.seconds != null)
            _row(tr('Tiempo estimado'), '≈ ${formatDuration(s.seconds!)}'),
          _row(tr('Recorrido de corte'), _len(c.cutMm)),
          _row(tr('Recorrido en rápido'), _len(c.rapidMm)),
          _row(tr('Líneas'), '${c.lineCount}'),
          _section(Units.tru('LÍMITES (mm)')),
          _row('X', ax(0)),
          _row('Y', ax(1)),
          _row('Z', ax(2)),
          _section(tr('HERRAMIENTAS')),
          if (tools.isEmpty)
            Text(
              tr('El programa no cambia de herramienta'),
              style: const TextStyle(color: DT.muted),
            )
          else
            for (final e in tools.values)
              InkWell(
                onTap: () => _editDiameter(context, e.number),
                child: _row(
                  'T${e.number} · Ø ${Units.isImperial ? Units.fine(sim.diameterOf(e.number)) : '${sim.diameterOf(e.number).toStringAsFixed(sim.diameterOf(e.number) % 1 == 0 ? 0 : 2)} mm'}${sim.assumed.contains(e.number) ? ' ${tr('(supuesto)')}' : ''}',
                  '${e.number < c.toolSeconds.length && c.toolSeconds[e.number] > 0 ? formatDuration(c.toolSeconds[e.number] * (s.secondsFromSlicer ? s.timeScale : 1)) : ''}'
                      '${e.number < c.toolCutMm.length && c.toolCutMm[e.number] > 0 ? ' · ${_len(c.toolCutMm[e.number])}' : ''}',
                ),
              ),
          _section(tr('PARÁMETROS')),
          if (fb > 0)
            _row(
              tr('Avance'),
              Units.feedRange(fa * 60, fb * 60),
            ),
          if (c.spindleMax > 0)
            _row(
              tr('Husillo'),
              c.spindleMin == c.spindleMax
                  ? '${c.spindleMax.round()} rpm'
                  : '${c.spindleMin.round()} – ${c.spindleMax.round()} rpm',
            ),
          _row(tr('Refrigerante'), c.coolant ? tr('Sí (M7/M8)') : tr('No')),
        ],
      ),
    );
  }
}

/// Barras con el tiempo de cada capa; tocar una barra lleva a esa capa.
class LayerTimeChart extends StatelessWidget {
  const LayerTimeChart({
    super.key,
    required this.seconds,
    required this.onLayer,
  });
  final List<double> seconds;
  final void Function(int) onLayer;

  @override
  Widget build(BuildContext context) {
    var maxI = 0;
    for (var i = 1; i < seconds.length; i++) {
      if (seconds[i] > seconds[maxI]) maxI = i;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, c) => GestureDetector(
            onTapUp: (d) => onLayer(
              (d.localPosition.dx / c.maxWidth * seconds.length).floor().clamp(
                0,
                seconds.length - 1,
              ),
            ),
            child: CustomPaint(
              size: Size(c.maxWidth, 70),
              painter: _ChartPainter(seconds, maxI),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          tr('Más lenta: capa {n} ({t})', {'n': maxI + 1, 't': formatDuration(seconds[maxI])}),
          style: const TextStyle(color: DT.muted, fontSize: 12.5),
        ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.v, this.maxI);
  final List<double> v;
  final int maxI;
  @override
  void paint(Canvas canvas, Size size) {
    final bins = math.min(v.length, size.width ~/ 2);
    final per = v.length / bins;
    final vals = List<double>.filled(bins, 0);
    for (var i = 0; i < v.length; i++) {
      final b = math.min(bins - 1, (i / per).floor());
      vals[b] = math.max(vals[b], v[i]);
    }
    final mx = vals.reduce(math.max);
    if (mx <= 0) return;
    final w = size.width / bins;
    final p = Paint()..color = DT.orange.withValues(alpha: 0.75);
    for (var b = 0; b < bins; b++) {
      final h = size.height * vals[b] / mx;
      canvas.drawRect(
        Rect.fromLTWH(b * w, size.height - h, math.max(1, w - 0.6), h),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.v != v;
}

/// Miniatura que el laminador guardó en el archivo (PNG, JPG o QOI).
class ThumbView extends StatefulWidget {
  const ThumbView({super.key, required this.bytes, required this.format});
  final Uint8List bytes;
  final int format;
  @override
  State<ThumbView> createState() => _ThumbViewState();
}

class _ThumbViewState extends State<ThumbView> {
  ui.Image? _qoi;

  @override
  void initState() {
    super.initState();
    if (widget.format == 2) {
      final q = decodeQoi(widget.bytes);
      if (q != null) {
        ui.decodeImageFromPixels(
          q.rgba,
          q.width,
          q.height,
          ui.PixelFormat.rgba8888,
          (img) {
            if (mounted) setState(() => _qoi = img);
          },
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (widget.format == 2) {
      if (_qoi == null) return const SizedBox.shrink();
      child = RawImage(image: _qoi, fit: BoxFit.contain);
    } else {
      child = Image.memory(
        widget.bytes,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    return Container(
      height: 150,
      margin: const EdgeInsets.only(top: 16),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DT.border),
      ),
      padding: const EdgeInsets.all(8),
      child: child,
    );
  }
}
