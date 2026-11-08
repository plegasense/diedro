import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../model/document.dart';
import '../model/unit_system.dart';
import '../model/units.dart';
import '../model/vector_info.dart';
import 'stl_tools.dart';
import 'theme.dart';

String _mmText(double mm) => Units.far(mm);

/// Hoja «Archivo» de un SVG o un HPGL: de dónde viene, qué tamaño dice tener y qué no se ha dibujado.
Future<void> showVectorSheet(BuildContext context, DrawingDocument d) {
  final v = d.info;
  if (v == null) return Future.value();
  final isHpgl = v.format.startsWith('HPGL');
  final rows = <Widget>[
    sheetTitle(
      isHpgl ? v.format : 'SVG',
      sub: v.generator != null
          ? tr('Generado con {g}', {'g': v.generator})
          : null,
    ),
  ];
  if (!isHpgl) {
    rows.add(
      sheetRow(
        tr('Tamaño'),
        v.declaredWidthMm != null
            ? Units.tru('{w} × {h} mm declarado', {
                'w': Units.number(v.declaredWidthMm!),
                'h': Units.number(v.declaredHeightMm ?? 0),
              })
            : tr('sin tamaño físico'),
        color: v.declaredWidthMm != null ? null : DT.orangeSoft,
      ),
    );
  }
  rows.add(
    Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Text(
        v.unitNote,
        style: const TextStyle(color: DT.muted, fontSize: 12.5),
      ),
    ),
  );

  if (isHpgl) {
    rows.add(sheetLabel(tr('RECORRIDO DEL PLÓTER')));
    rows
      ..add(sheetRow(tr('Con pluma bajada'), _mmText(v.drawMm)))
      ..add(
        sheetRow(
          tr('Con pluma levantada'),
          tr('{d} ({p} %)', {
            'd': _mmText(v.travelMm),
            'p': (v.travelShare * 100).round(),
          }),
          color: v.travelShare > 0.3 ? DT.orangeSoft : null,
        ),
      )
      ..add(sheetRow(tr('Levantadas de pluma'), '${v.lifts}'));
    if (v.pens.isNotEmpty) {
      rows.add(sheetLabel(tr('PLUMAS')));
      for (final p in v.pens) {
        final w = p.widthMm != null ? ' · ${Units.fine(p.widthMm!)}' : '';
        rows.add(
          sheetRow(
            tr('Pluma {n}{w}', {'n': p.number, 'w': w}),
            p.strokes == 1
                ? tr('{d} · {n} trazo', {'d': _mmText(p.drawMm), 'n': p.strokes})
                : tr('{d} · {n} trazos', {'d': _mmText(p.drawMm), 'n': p.strokes}),
          ),
        );
      }
    }
    if (v.labels > 0) rows.add(sheetRow(tr('Rótulos (LB)'), '${v.labels}'));
    if (v.encodedPolylines) {
      rows.add(sheetRow(tr('Polilíneas codificadas (PE)'), tr('sí')));
    }
  } else if (v.counts.isNotEmpty) {
    rows.add(sheetLabel(tr('CONTENIDO')));
    for (final e in v.counts.entries) {
      if (e.value > 0) rows.add(sheetRow(e.key, '${e.value}'));
    }
  }

  if (v.warnings.isNotEmpty) {
    rows.add(sheetLabel(tr('QUÉ NO SE PUEDE DAR POR BUENO')));
    for (final w in v.warnings) {
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2, right: 8),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: DT.orangeSoft,
                ),
              ),
              Expanded(child: Text(w, style: const TextStyle(height: 1.3))),
            ],
          ),
        ),
      );
    }
  }
  return datumSheet(context, ListView(shrinkWrap: true, children: rows));
}

/// Texto corto para la cabecera: «Inkscape 1.2» o «HPGL/2».
String vectorBadge(VectorInfo v) =>
    v.generator != null ? v.generator! : v.format;

/// Longitud con la unidad que corresponda a los números del archivo.
String unitLen(LengthUnit u, double mm) => u.length(mm);
