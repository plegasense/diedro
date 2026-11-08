import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'glass.dart';
import 'logo.dart';
import 'recents.dart';
import 'language_sheet.dart';
import 'units_sheet.dart';
import '../model/unit_system.dart';
import 'theme.dart';
import '../l10n/l10n.dart';

const _drawingExts = {'dxf', 'svg', 'plt', 'hpgl', 'hgl', 'hpg'};
const _cloudExts = {'xyz', 'pts', 'pcd'};
const _pathExts = {'gcode', 'bgcode', 'nc', 'ngc', 'tap', 'gco', 'gc', 'cnc'};

IconData iconForExt(String ext) => _drawingExts.contains(ext)
    ? Icons.architecture
    : _cloudExts.contains(ext)
    ? Icons.grain
    : _pathExts.contains(ext)
    ? Icons.route_outlined
    : Icons.view_in_ar_outlined;

String kindForExt(String ext) => _drawingExts.contains(ext)
    ? tr('Dibujo 2D')
    : _cloudExts.contains(ext)
    ? tr('Nube de puntos')
    : _pathExts.contains(ext)
    ? 'G-code'
    : const {'step', 'stp', 'stpz', 'iges', 'igs', 'brep'}.contains(ext)
    ? tr('CAD · B-rep')
    : tr('Malla 3D');

/// Formatos compatibles, agrupados para la hoja informativa.
List<(String, IconData, String)> get _formatGroups => [
  (
    tr('Piezas y ensamblajes'),
    Icons.view_in_ar_outlined,
    'STEP · STP · STPZ · IGES · BREP · STL · 3MF · OBJ · PLY · glTF · GLB · VRML',
  ),
  (tr('Planos y dibujos'), Icons.architecture, 'DXF · SVG · HPGL · PLT'),
  (
    tr('Fabricación'),
    Icons.route_outlined,
    tr('G-code · BGCODE · NC · NGC · TAP · 3MF de impresora'),
  ),
  (tr('Nubes de puntos'), Icons.grain, 'XYZ · PTS · PCD · PLY'),
];

/// Pantalla de inicio: logo animado, abrir archivo y recientes.
class HomeView extends StatefulWidget {
  const HomeView({
    super.key,
    required this.onPick,
    required this.onOpenPath,
    required this.playIntro,
  });
  final VoidCallback onPick;
  final void Function(String path) onOpenPath;
  final bool playIntro;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.playIntro ? 2200 : 500),
  )..forward();
  List<RecentFile> _recents = [];

  @override
  void initState() {
    super.initState();
    RecentsStore.load().then((r) {
      if (mounted) setState(() => _recents = r);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Animation<double> _slot(
    double a,
    double b, [
    Curve curve = Curves.easeOutCubic,
  ]) => CurvedAnimation(
    parent: _c,
    curve: Interval(a, b, curve: curve),
  );

  void _showFormats() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Glass(
            radius: 26,
            color: const Color(0xE6101B1F),
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Formatos compatibles'),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                for (final (title, icon, formats) in _formatGroups)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: DT.orange.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Icon(icon, color: DT.orangeSoft, size: 21),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14.5,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                formats,
                                style: const TextStyle(
                                  color: DT.muted,
                                  fontSize: 12.5,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return tr('ahora');
    if (d.inMinutes < 60) return tr('hace {n} min', {'n': d.inMinutes});
    if (d.inHours < 24) return tr('hace {n} h', {'n': d.inHours});
    return tr('hace {n} d', {'n': d.inDays});
  }

  @override
  Widget build(BuildContext context) {
    final logoT = _slot(0.0, 0.62, Curves.easeInOutCubic);
    final wordT = _slot(0.40, 0.72);
    final bodyT = _slot(0.62, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Fondo: cuadrícula de puntos de plano técnico con luz cálida tras el logo.
        FadeTransition(
          opacity: bodyT,
          child: const CustomPaint(painter: _DotGridPainter()),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.45),
              radius: 0.8,
              colors: [Color(0x2EFB923C), Color(0x0A5EEAD4), Color(0x00000000)],
              stops: [0.0, 0.5, 1.0],
            ),
          ),
        ),
        SafeArea(
          child: LayoutBuilder(
            builder: (context, c) {
              final compact = c.maxHeight < 640;
              final recents = _recents.take(3).toList();
              return Column(
                children: [
                  const Spacer(flex: 3),
                  AnimatedBuilder(
                    animation: _c,
                    builder: (_, __) => Transform.translate(
                      offset: Offset(0, (1 - logoT.value) * 14),
                      child: Opacity(
                        opacity: Curves.easeOut.transform(
                          (logoT.value * 2).clamp(0.0, 1.0),
                        ),
                        child: DatumLogo(
                          size: compact ? 150 : 210,
                          explode: logoT.value,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: compact ? 26 : 40),
                  FadeTransition(
                    opacity: wordT,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.25),
                        end: Offset.zero,
                      ).animate(wordT),
                      child: const Text(
                        'Datum',
                        style: TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.w300,
                          letterSpacing: 9,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(flex: 3),
                  FadeTransition(
                    opacity: bodyT,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.08),
                        end: Offset.zero,
                      ).animate(bodyT),
                      child: Center(
                        child: ConstrainedBox(
                          // En tabletas y pantallas anchas el contenido no se estira de lado a lado.
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Column(
                              children: [
                                if (recents.isNotEmpty) ...[
                                  for (final r in recents)
                                    _RecentRow(
                                      r,
                                      ago: _ago(r.openedAt),
                                      onTap: () => widget.onOpenPath(r.path),
                                    ),
                                  const SizedBox(height: 14),
                                ],
                                SizedBox(
                                  width: double.infinity,
                                  height: 58,
                                  child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: DT.orange,
                                      foregroundColor: DT.ink,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      textStyle: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    onPressed: widget.onPick,
                                    icon: const Icon(Icons.folder_open_rounded),
                                    label: Text(tr('Abrir archivo')),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                TextButton(
                                  onPressed: _showFormats,
                                  style: TextButton.styleFrom(
                                    foregroundColor: DT.text.withValues(
                                      alpha: 0.55,
                                    ),
                                  ),
                                  child: Text(
                                    tr('Ver formatos compatibles'),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                ValueListenableBuilder<UnitSystem>(
                                  valueListenable: Units.notifier,
                                  builder: (ctx, s, _) => TextButton.icon(
                                    onPressed: () => showUnitsSheet(context),
                                    style: TextButton.styleFrom(
                                      foregroundColor: DT.text.withValues(alpha: 0.55),
                                    ),
                                    icon: const Icon(Icons.straighten_rounded, size: 16),
                                    label: Text(
                                      tr('Unidades: {u}', {'u': Units.label(s)}),
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                ),
                                ValueListenableBuilder<String>(
                                  valueListenable: L.choice,
                                  builder: (ctx, c, _) => TextButton.icon(
                                    onPressed: () => showLanguageSheet(context),
                                    style: TextButton.styleFrom(
                                      foregroundColor: DT.text.withValues(alpha: 0.55),
                                    ),
                                    icon: const Icon(Icons.translate_rounded, size: 16),
                                    label: Text(
                                      tr('Idioma: {l}', {'l': c == 'auto' ? tr('Automático') : L.names[c]}),
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow(this.r, {required this.ago, required this.onTap});
  final RecentFile r;
  final String ago;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: const Color(0x0FFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: DT.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: DT.orange.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(iconForExt(r.ext), color: DT.orangeSoft, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  r.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(ago, style: const TextStyle(color: DT.muted, fontSize: 12)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Cuadrícula de puntos que se desvanece hacia los bordes.
class _DotGridPainter extends CustomPainter {
  const _DotGridPainter();
  @override
  void paint(Canvas canvas, Size size) {
    const gap = 26.0;
    final c = Offset(size.width / 2, size.height * 0.34);
    final maxD = math.sqrt(
      size.width * size.width / 4 + size.height * size.height * 0.2,
    );
    final paint = Paint();
    for (var y = gap / 2; y < size.height; y += gap) {
      for (var x = gap / 2; x < size.width; x += gap) {
        final d = (Offset(x, y) - c).distance / maxD;
        final a = (1 - d).clamp(0.0, 1.0);
        if (a <= 0.02) continue;
        paint.color = Color.fromRGBO(234, 243, 244, 0.13 * a * a);
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter old) => false;
}
