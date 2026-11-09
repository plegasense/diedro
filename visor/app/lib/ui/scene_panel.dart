// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'package:flutter/material.dart';

import '../model/scene.dart';
import '../model/units.dart';
import 'theme.dart';
import '../l10n/l10n.dart';

/// Panel lateral: árbol de ensamblaje con búsqueda y lista de materiales.
class ScenePanel extends StatefulWidget {
  const ScenePanel({
    super.key,
    required this.scene,
    required this.selected,
    required this.onChanged,
    required this.onFocus,
    this.unit = LengthUnit.mm,
    this.onCopyBom,
  });
  final LengthUnit unit;
  final VoidCallback? onCopyBom;
  final Scene scene;
  final Set<SceneNode> selected;
  final VoidCallback onChanged;
  final VoidCallback onFocus;

  @override
  State<ScenePanel> createState() => _ScenePanelState();
}

class _ScenePanelState extends State<ScenePanel> {
  String _query = '';
  final Set<SceneNode> _collapsed = {};

  void _notify() {
    setState(() {});
    widget.onChanged();
  }

  List<(SceneNode, int)> _rows() {
    final out = <(SceneNode, int)>[];
    final q = _query.trim().toLowerCase();
    void walk(SceneNode n, int depth) {
      final match = q.isEmpty || n.name.toLowerCase().contains(q);
      if (n != widget.scene.root && match) out.add((n, depth));
      if (q.isEmpty && _collapsed.contains(n)) return;
      for (final c in n.children) {
        walk(c, q.isEmpty ? depth + 1 : 0);
      }
    }

    walk(widget.scene.root, -1);
    return out;
  }

  void _setVisible(SceneNode n, bool v) {
    n.visible = v;
    for (final c in n.children) {
      _setVisible(c, v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.scene;
    return SafeArea(
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: TextField(
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded, color: DT.muted),
                  hintText: tr('Buscar por nombre'),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            TabBar(
              tabs: [
                Tab(text: tr('Árbol')),
                Tab(text: tr('Lista de piezas')),
              ],
            ),
            Expanded(child: TabBarView(children: [_tree(), _bom(scene)])),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      _setVisible(scene.root, true);
                      _notify();
                    },
                    icon: const Icon(Icons.visibility),
                    label: Text(tr('Mostrar todo')),
                  ),
                  TextButton.icon(
                    onPressed: widget.selected.isEmpty
                        ? null
                        : () {
                            _setVisible(scene.root, false);
                            for (final n in widget.selected) {
                              for (SceneNode? p = n; p != null; p = p.parent) {
                                p.visible = true;
                              }
                              _setVisible(n, true);
                            }
                            _notify();
                            widget.onFocus();
                          },
                    icon: const Icon(Icons.filter_center_focus),
                    label: Text(tr('Aislar')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tree() {
    final rows = _rows();
    if (rows.isEmpty)
      return Center(
        child: Text(tr('Sin resultados'), style: const TextStyle(color: Colors.white54)),
      );
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, i) {
        final (n, depth) = rows[i];
        final isSel = widget.selected.contains(n);
        final hasKids = n.children.isNotEmpty;
        return InkWell(
          onTap: () {
            widget.selected
              ..clear()
              ..add(n);
            _notify();
          },
          child: Container(
            color: isSel ? DT.orange.withValues(alpha: 0.16) : null,
            padding: EdgeInsets.only(left: 8.0 + depth * 14, right: 4),
            height: 40,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: hasKids
                      ? GestureDetector(
                          onTap: () => setState(
                            () => _collapsed.contains(n)
                                ? _collapsed.remove(n)
                                : _collapsed.add(n),
                          ),
                          child: Icon(
                            _collapsed.contains(n)
                                ? Icons.chevron_right
                                : Icons.expand_more,
                            size: 20,
                          ),
                        )
                      : null,
                ),
                Icon(
                  hasKids ? Icons.folder_outlined : Icons.view_in_ar_outlined,
                  size: 18,
                  color: Colors.white54,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(n.name, overflow: TextOverflow.ellipsis)),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    n.visible ? Icons.visibility : Icons.visibility_off,
                    size: 18,
                  ),
                  onPressed: () {
                    _setVisible(n, !n.visible);
                    _notify();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _bom(Scene scene) {
    final groups = <String, List<Instance>>{};
    for (final i in scene.instances(onlyVisible: false)) {
      groups.putIfAbsent(i.part.id.toString(), () => []).add(i);
    }
    final q = _query.trim().toLowerCase();
    final entries =
        groups.values
            .where(
              (l) => q.isEmpty || l.first.part.name.toLowerCase().contains(q),
            )
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    final total = scene.instances(onlyVisible: false).length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('{n} piezas distintas · {t} en total', {'n': groups.length, 't': total}),
                  style: const TextStyle(color: Colors.white60),
                ),
              ),
              if (widget.onCopyBom != null)
                TextButton.icon(
                  onPressed: widget.onCopyBom,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(tr('Copiar')),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final list = entries[i];
              return ListTile(
                dense: true,
                title: Text(
                  list.first.part.name,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(() {
                  final sz = list.first.part.mesh.bounds.size;
                  final u = widget.unit;
                  return u.dims(sz);
                }()),
                trailing: Text(
                  '×${list.length}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onTap: () {
                  widget.selected
                    ..clear()
                    ..addAll(list.map((e) => e.node));
                  _notify();
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
