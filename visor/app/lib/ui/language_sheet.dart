import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../model/unit_system.dart';
import 'stl_tools.dart' show datumSheet, sheetTitle;
import 'theme.dart';

/// Hoja para elegir el idioma de la interfaz: Automático (el del dispositivo) o uno de la lista.
Future<void> showLanguageSheet(BuildContext context) {
  return datumSheet(
    context,
    ValueListenableBuilder<String>(
      valueListenable: L.choice,
      builder: (ctx, current, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sheetTitle(
            tr('Idioma'),
            sub: tr('Por defecto se usa el del dispositivo.'),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final c in ['auto', ...L.names.keys])
                    InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Units.setLang(c),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            Icon(
                              c == current
                                  ? Icons.radio_button_checked_rounded
                                  : Icons.radio_button_off_rounded,
                              color: c == current ? DT.orange : DT.muted,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              c == 'auto' ? tr('Automático') : L.names[c]!,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
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
