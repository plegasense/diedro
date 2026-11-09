// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'package:flutter/material.dart';

import '../model/lines.dart';
import 'theme.dart';
import '../l10n/l10n.dart';

/// Panel de capas de un dibujo 2D: visibilidad por capa.
class LayersPanel extends StatefulWidget {
  const LayersPanel({super.key, required this.lines, required this.onChanged});
  final LineSet lines;
  final VoidCallback onChanged;

  @override
  State<LayersPanel> createState() => _LayersPanelState();
}

class _LayersPanelState extends State<LayersPanel> {
  @override
  Widget build(BuildContext context) {
    final groups = widget.lines.groups;
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('Capas'),
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${groups.length}',
                  style: const TextStyle(color: DT.muted),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: groups.length,
              itemBuilder: (context, i) {
                final g = groups[i];
                return ListTile(
                  dense: true,
                  leading: Icon(
                    g.visible ? Icons.visibility : Icons.visibility_off,
                    size: 20,
                  ),
                  title: Text(g.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(tr('{n} segmentos', {'n': g.vertexCount ~/ 2})),
                  onTap: () {
                    setState(() => g.visible = !g.visible);
                    widget.onChanged();
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      for (final g in groups) {
                        g.visible = true;
                      }
                    });
                    widget.onChanged();
                  },
                  icon: const Icon(Icons.visibility),
                  label: Text(tr('Todas')),
                ),
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      for (final g in groups) {
                        g.visible = false;
                      }
                    });
                    widget.onChanged();
                  },
                  icon: const Icon(Icons.visibility_off),
                  label: Text(tr('Ninguna')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
