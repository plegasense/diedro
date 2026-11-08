import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../model/unit_system.dart';
import 'stl_tools.dart' show datumSheet, sheetTitle;
import 'theme.dart';

/// Hoja para elegir el sistema de unidades de las medidas: Automático, Métrico o Imperial.
Future<void> showUnitsSheet(BuildContext context) {
  return datumSheet(
    context,
    ValueListenableBuilder<UnitSystem>(
      valueListenable: Units.notifier,
      builder: (ctx, current, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sheetTitle(tr('Unidades'), sub: tr('Cómo se muestran las medidas; los archivos no cambian.')),
          for (final s in UnitSystem.values)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Units.set(s),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      s == current ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                      color: s == current ? DT.orange : DT.muted,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(Units.label(s), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                          Text(
                            switch (s) {
                              UnitSystem.auto => tr('Según el país del dispositivo'),
                              UnitSystem.metric => tr('Milímetros, gramos y metros'),
                              UnitSystem.imperial => tr('Pulgadas, onzas y libras'),
                            },
                            style: const TextStyle(color: DT.muted, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
