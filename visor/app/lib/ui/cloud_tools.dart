import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../model/cloud_info.dart';
import '../model/pointcloud.dart';
import '../render/camera.dart';
import 'stl_tools.dart';
import 'theme.dart';
import '../model/unit_system.dart';

/// Estado de las herramientas de una nube de puntos: medir entre dos puntos y vista.
class CloudController extends ChangeNotifier {
  CloudController(this.cloud);
  final PointCloud cloud;
  bool measuring = false;

  /// Hasta dos puntos medidos, en coordenadas relativas al origen de la nube.
  final List<List<double>> picks = [];

  void toggleMeasure() {
    measuring = !measuring;
    if (!measuring) picks.clear();
    notifyListeners();
  }

  void clearPicks() {
    picks.clear();
    notifyListeners();
  }

  void changed() => notifyListeners();

  /// Elige el punto de la nube más cercano a la cámara dentro de un radio de 18 px del toque.
  /// Con nubes grandes se mira un punto de cada k para que sea inmediato.
  bool tap(OrbitCamera cam, Offset p, Size viewport) {
    final v = cloud.points.vertices;
    final total = v.length ~/ 6;
    if (total == 0) return false;
    final step = math.max(1, (total / 1500000).ceil());
    final m = (cam.projection(viewport.width / viewport.height) * cam.viewMatrix()).storage;
    final w = viewport.width, h = viewport.height;
    const r2 = 18.0 * 18.0;
    var best = -1;
    var bestW = double.infinity;
    for (var i = 0; i < total; i += step) {
      final o = i * 6;
      final x = v[o], y = v[o + 1], z = v[o + 2];
      final cw = m[3] * x + m[7] * y + m[11] * z + m[15];
      if (cw <= 1e-9) continue;
      final sx = (m[0] * x + m[4] * y + m[8] * z + m[12]) / cw * 0.5 + 0.5;
      final sy = (m[1] * x + m[5] * y + m[9] * z + m[13]) / cw * 0.5 + 0.5;
      final dx = sx * w - p.dx, dy = (1 - sy) * h - p.dy;
      if (dx * dx + dy * dy > r2) continue;
      if (cw < bestW) {
        bestW = cw;
        best = i;
      }
    }
    if (best < 0) return false;
    if (picks.length >= 2) picks.clear();
    picks.add([v[best * 6].toDouble(), v[best * 6 + 1].toDouble(), v[best * 6 + 2].toDouble()]);
    notifyListeners();
    return true;
  }

  String _num(double v) {
    final a = v.abs();
    return fmtNum(v, d: a >= 100 ? 1 : (a >= 1 ? 2 : 3));
  }

  String get unit => Units.cloudLabel(cloud.info);

  /// Resultado de la medición con dos puntos: distancia, horizontal, desnivel y pendiente.
  List<(String, String)> get result {
    if (picks.length < 2) return const [];
    final a = picks[0], b = picks[1];
    final dx = b[0] - a[0], dy = b[1] - a[1], dz = b[2] - a[2];
    final horiz = math.sqrt(dx * dx + dy * dy);
    final d3 = math.sqrt(dx * dx + dy * dy + dz * dz);
    final u = Units.cloudLabel(cloud.info);
    final k = Units.cloudFactor(cloud.info);
    return [
      (tr('Distancia'), '${_num(d3 * k)}$u'),
      (tr('Horizontal'), '${_num(horiz * k)}$u'),
      (tr('Desnivel'), '${dz >= 0 ? '+' : ''}${_num(dz * k)}$u'),
      if (horiz > 1e-9) (tr('Pendiente'), '${fmtNum(dz / horiz * 100, d: 1)} % · ${fmtNum(math.atan2(dz.abs(), horiz) * 180 / math.pi, d: 1)}°'),
    ];
  }
}

/// Marcas de la medición proyectadas sobre la vista.
class CloudOverlayPainter extends CustomPainter {
  CloudOverlayPainter(this.cam, this.ctl, Listenable repaint) : super(repaint: repaint);
  final OrbitCamera cam;
  final CloudController ctl;

  Offset? _project(List<double> p, Size size) {
    final m = cam.projection(size.width / size.height) * cam.viewMatrix();
    final s = m.storage;
    final w = s[3] * p[0] + s[7] * p[1] + s[11] * p[2] + s[15];
    if (w <= 1e-9) return null;
    final x = (s[0] * p[0] + s[4] * p[1] + s[8] * p[2] + s[12]) / w;
    final y = (s[1] * p[0] + s[5] * p[1] + s[9] * p[2] + s[13]) / w;
    return Offset((x * 0.5 + 0.5) * size.width, (1 - (y * 0.5 + 0.5)) * size.height);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pts = [for (final p in ctl.picks) _project(p, size)];
    final line = Paint()
      ..color = DT.orange
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    if (pts.length == 2 && pts[0] != null && pts[1] != null) {
      canvas.drawLine(pts[0]!, pts[1]!, line);
      final r = ctl.result;
      if (r.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: r.first.$2,
            style: const TextStyle(color: DT.text, fontSize: 13, fontWeight: FontWeight.w700, backgroundColor: Color(0xCC0A1214)),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final mid = (pts[0]! + pts[1]!) / 2;
        tp.paint(canvas, mid + const Offset(8, -22));
      }
    }
    for (final o in pts) {
      if (o == null) continue;
      canvas.drawCircle(o, 6, Paint()..color = DT.orange);
      canvas.drawCircle(o, 6, Paint()..color = DT.ink..style = PaintingStyle.stroke..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant CloudOverlayPainter old) => true;
}

String _modeName(CloudColorMode m) => switch (m) {
  CloudColorMode.original => tr('Color del archivo'),
  CloudColorMode.height => tr('Altura'),
  CloudColorMode.intensity => tr('Intensidad'),
  CloudColorMode.classification => tr('Clasificación'),
  CloudColorMode.returns => tr('Retornos'),
  CloudColorMode.flat => tr('Liso'),
};

String _countText(num n) => n >= 1e6 ? '${fmtNum(n / 1e6, d: 1)} M' : (n >= 1e4 ? tr('{n} mil', {'n': fmtNum(n / 1e3, d: 0)}) : fmtNum(n.toDouble(), d: 0));

Widget _gradient(List<Color> colors, String lo, String hi) => Padding(
  padding: const EdgeInsets.only(top: 8),
  child: Column(
    children: [
      Container(
        height: 10,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), gradient: LinearGradient(colors: colors)),
      ),
      const SizedBox(height: 4),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(lo, style: const TextStyle(color: DT.muted, fontSize: 12)),
          Text(hi, style: const TextStyle(color: DT.muted, fontSize: 12)),
        ],
      ),
    ],
  ),
);

Widget _dot(Color c) => Container(width: 12, height: 12, decoration: BoxDecoration(color: c, shape: BoxShape.circle));

/// Hoja «Vista»: color, tamaño de punto, clases visibles y recorte por altura.
Future<void> showCloudViewSheet(BuildContext context, CloudController ctl) {
  final c = ctl.cloud;
  return datumSheet(
    context,
    StatefulBuilder(
      builder: (ctx, set) {
        void apply(VoidCallback f) {
          f();
          ctl.changed();
          set(() {});
        }

        final unit = Units.cloudLabel(c.info);
        final uk = Units.cloudFactor(c.info);
        final zMin = c.bounds.min[2], zMax = c.bounds.max[2];
        final zOff = c.origin[2];
        final aMin = c.bounds.min[c.clipAxis], aMax = c.bounds.max[c.clipAxis], aOff = c.origin[c.clipAxis];
        final lo = (c.zClipLo ?? aMin).clamp(aMin, aMax), hi = (c.zClipHi ?? aMax).clamp(aMin, aMax);
        final rows = <Widget>[
          sheetTitle(
            tr('Vista de la nube'),
            sub: c.info.sampled
                ? tr('Se muestran {n} puntos de {t}', {'n': _countText(c.totalLoaded), 't': _countText(c.info.totalPoints)})
                : tr('Se muestran {n} puntos', {'n': _countText(c.totalLoaded)}),
          ),
          sheetLabel(tr('COLOR')),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final m in c.availableModes)
                ChoiceChip(
                  label: Text(_modeName(m)),
                  selected: c.mode == m,
                  onSelected: (_) => apply(() => c.recolor(m)),
                ),
            ],
          ),
        ];
        switch (c.mode) {
          case CloudColorMode.height:
            rows.add(
              _gradient(
                [for (var k = 0; k <= 8; k++) _rgb(PointCloud.ramp(k / 8))],
                '${fmtNum((zMin + zOff) * uk, d: 1)}$unit',
                '${fmtNum((zMax + zOff) * uk, d: 1)}$unit',
              ),
            );
          case CloudColorMode.intensity:
            rows.add(
              _gradient(
                [const Color(0xFF1F1E1D), const Color(0xFFFFFAF0)],
                '${c.info.intensityLo.round()}',
                tr('{h}  (rango del archivo {a}–{b})', {'h': c.info.intensityHi.round(), 'a': c.info.intensityMin, 'b': c.info.intensityMax}),
              ),
            );
          case CloudColorMode.classification:
            final scale = c.info.shownPoints > 0 ? c.info.totalPoints / c.info.shownPoints : 1.0;
            final keys = c.info.classCounts.keys.toList()..sort();
            for (final k in keys) {
              final hidden = c.hiddenClasses.contains(k);
              rows.add(
                InkWell(
                  onTap: () => apply(() => c.toggleClass(k)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18, color: hidden ? DT.muted : DT.text),
                        const SizedBox(width: 10),
                        _dot(Color(0xFF000000 | asprsColor(k))),
                        const SizedBox(width: 10),
                        Expanded(child: Text('${asprsName(k)} ($k)', style: TextStyle(color: hidden ? DT.muted : DT.text))),
                        Text(tr('≈ {n}', {'n': _countText(c.info.classCounts[k]! * scale)}), style: const TextStyle(color: DT.muted, fontSize: 12.5)),
                      ],
                    ),
                  ),
                ),
              );
            }
          case CloudColorMode.returns:
            for (final e in [
              (tr('Retorno único'), const Color(0xFFDCE6EB)),
              (tr('Primero de varios'), const Color(0xFF5EEA80)),
              (tr('Intermedio'), const Color(0xFF61A6FA)),
              (tr('Último de varios'), const Color(0xFFFA913D)),
            ]) {
              rows.add(
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [_dot(e.$2), const SizedBox(width: 10), Text(e.$1)]),
                ),
              );
            }
          case CloudColorMode.original || CloudColorMode.flat:
            break;
        }
        rows
          ..add(sheetLabel(tr('TAMAÑO DE PUNTO')))
          ..add(
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: c.effectiveSize.clamp(1.0, 10.0),
                    min: 1,
                    max: 10,
                    onChanged: (v) => apply(() => c.pointSize = v),
                  ),
                ),
                SizedBox(width: 44, child: Text('${fmtNum(c.effectiveSize, d: 1)} px', style: const TextStyle(color: DT.muted, fontSize: 12.5))),
              ],
            ),
          )
          ..add(sheetLabel(tr('SOMBREADO DE BORDE')))
          ..add(
            Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Oscurece los puntos que tienen otros más cerca: da relieve sin necesitar normales.'),
                    style: TextStyle(color: DT.muted, fontSize: 12.5),
                  ),
                ),
                Switch(value: c.edl, onChanged: (v) => apply(() => c.edl = v)),
              ],
            ),
          )
          ..add(
            c.edl
                ? Slider(value: c.edlStrength, min: 0.2, max: 3, onChanged: (v) => apply(() => c.edlStrength = v))
                : const SizedBox.shrink(),
          )
          ..add(sheetLabel(tr('CORTE Y PERFIL')))
          ..add(
            Wrap(
              spacing: 6,
              children: [
                for (final (i, n) in const ['X', 'Y', 'Z (altura)'].indexed)
                  ChoiceChip(label: Text(tr('Eje {n}', {'n': n == 'Z (altura)' ? tr('Z (altura)') : n})), selected: c.clipAxis == i, onSelected: (_) => apply(() => c.setClip(null, null, axis: i))),
              ],
            ),
          )
          ..add(
            RangeSlider(
              values: RangeValues(lo, hi),
              min: aMin,
              max: aMax > aMin ? aMax : aMin + 1,
              onChanged: (r) => apply(() => c.setClip(r.start <= aMin + 1e-9 ? null : r.start, r.end >= aMax - 1e-9 ? null : r.end)),
            ),
          )
          ..add(
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${fmtNum((lo + aOff) * uk, d: 2)}$unit', style: const TextStyle(color: DT.muted, fontSize: 12.5)),
                Text('${fmtNum((hi + aOff) * uk, d: 2)}$unit', style: const TextStyle(color: DT.muted, fontSize: 12.5)),
              ],
            ),
          );
        if (c.filtered) {
          rows.add(
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => apply(c.showAll), child: Text(tr('Mostrar todo'))),
            ),
          );
        }
        return ListView(shrinkWrap: true, children: rows);
      },
    ),
  );
}

Color _rgb((double, double, double) c) => Color.from(alpha: 1, red: c.$1, green: c.$2, blue: c.$3);

/// Hoja «Sobre el archivo»: formato, sistema de coordenadas, unidades, densidad y avisos.
Future<void> showCloudInfoSheet(BuildContext context, PointCloud c) {
  final i = c.info;
  final u = Units.cloudLabel(i);
  final uk = Units.cloudFactor(i);
  String coord(List<double>? v) => v == null ? '—' : '${fmtNum(v[0], d: 2)}, ${fmtNum(v[1], d: 2)}, ${fmtNum(v[2], d: 2)}';
  final rows = <Widget>[
    sheetTitle(i.format, sub: i.pointFormat),
    sheetRow(tr('Puntos'), i.sampled ? tr('{a} de {b}', {'a': fmtNum(i.shownPoints.toDouble(), d: 0), 'b': fmtNum(i.totalPoints.toDouble(), d: 0)}) : fmtNum(i.totalPoints.toDouble(), d: 0)),
  ];
  if (i.minAbs != null && i.maxAbs != null) {
    final e = [for (var k = 0; k < 3; k++) i.maxAbs![k] - i.minAbs![k]];
    rows
      ..add(sheetRow(tr('Extensión'), '${fmtNum(e[0] * uk, d: 2)} × ${fmtNum(e[1] * uk, d: 2)} × ${fmtNum(e[2] * uk, d: 2)}$u'))
      ..add(sheetRow(tr('Mínimo'), coord(i.minAbs)))
      ..add(sheetRow(tr('Máximo'), coord(i.maxAbs)));
  }
  if (i.density != null && i.density! > 0) {
    final d = i.density!;
    rows.add(sheetRow(
      tr('Densidad'),
      Units.isImperial
          ? tr('≈ {a} puntos/ft² · separación ≈ {b} in', {'a': fmtNum(Units.densityValue(d), d: Units.densityValue(d) < 10 ? 2 : 0), 'b': fmtNum(Units.spacingValue(d), d: 1)})
          : tr('≈ {a} puntos/m² · separación ≈ {b} cm', {'a': fmtNum(d, d: d < 10 ? 2 : 0), 'b': fmtNum(100 / math.sqrt(d), d: 1)}),
    ));
  }
  rows
    ..add(sheetLabel(tr('SISTEMA DE COORDENADAS')))
    ..add(sheetRow(tr('Sistema'), i.crs ?? tr('sin indicar'), color: i.crs == null ? DT.orangeSoft : null))
    ..add(sheetRow(tr('Unidad'), i.unit.isEmpty ? tr('sin indicar') : (i.geographic ? tr('grados') : i.unit)));
  if (i.epsg != null) rows.add(sheetRow('EPSG', '${i.epsg}'));
  if (i.scale != null) rows.add(sheetRow(tr('Precisión (escala)'), '${fmtNum(i.scale![0] * uk, d: 4)}$u'));
  rows.add(sheetLabel(tr('CONTENIDO')));
  rows
    ..add(sheetRow(tr('Color'), i.hasRgb ? tr('sí') : tr('no')))
    ..add(sheetRow(tr('Intensidad'), i.hasIntensity ? '${i.intensityMin}–${i.intensityMax}' : tr('no')))
    ..add(sheetRow(tr('Clasificación'), i.hasClass ? tr('{n} clases', {'n': i.classCounts.length}) : tr('no')))
    ..add(sheetRow(tr('Retornos'), i.hasReturns ? tr('sí') : tr('no')))
    ..add(sheetRow(tr('Tiempo GPS'), i.hasGps ? (i.gpsMin != null ? '${fmtNum(i.gpsMin!, d: 0)} – ${fmtNum(i.gpsMax ?? i.gpsMin!, d: 0)}' : tr('sí')) : tr('no')));
  if (i.software != null || i.system != null || i.date != null) {
    rows.add(sheetLabel(tr('ORIGEN')));
    if (i.software != null) rows.add(sheetRow(tr('Software'), i.software!));
    if (i.system != null) rows.add(sheetRow(tr('Equipo'), i.system!));
    if (i.date != null) rows.add(sheetRow(tr('Fecha'), i.date!));
  }
  if (i.warnings.isNotEmpty) {
    rows.add(sheetLabel(tr('QUÉ NO SE PUEDE DAR POR BUENO')));
    for (final w in i.warnings) {
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(padding: EdgeInsets.only(top: 2, right: 8), child: Icon(Icons.warning_amber_rounded, size: 16, color: DT.orangeSoft)),
              Expanded(child: Text(w, style: const TextStyle(height: 1.3))),
            ],
          ),
        ),
      );
    }
  }
  return datumSheet(context, ListView(shrinkWrap: true, children: rows));
}
