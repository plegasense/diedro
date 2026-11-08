import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../l10n/l10n.dart';
import '../model/brep.dart';
import '../model/pmi.dart';
import '../model/scene.dart';
import '../model/units.dart';
import '../render/camera.dart';
import '../render/gpu_mesh.dart';
import '../render/picking.dart';
import 'glass.dart';
import 'theme.dart';
import '../model/unit_system.dart';

/// Una cara o arista tocada con la herramienta de medir.
class PickedEntity {
  PickedEntity({
    required this.instance,
    required this.isEdge,
    required this.index,
    this.face,
    this.edge,
    required this.point,
  });
  final Instance instance;
  final bool isEdge;
  final int index;
  final FaceInfo? face;
  final EdgeInfo? edge;

  /// Punto tocado, en el mundo.
  final vm.Vector3 point;

  Part get part => instance.part;

  /// Eje o normal en el mundo, si la entidad tiene dirección.
  vm.Vector3? get direction {
    final m = instance.world;
    if (face != null &&
        (face!.kind == SurfaceKind.plane ||
            face!.kind == SurfaceKind.cylinder ||
            face!.kind == SurfaceKind.cone)) {
      return (m.getRotation() * face!.axis).normalized();
    }
    if (edge != null) {
      if (edge!.kind == CurveKind.line) {
        return (m.getRotation() * (edge!.end - edge!.start)).normalized();
      }
      if (edge!.kind == CurveKind.circle || edge!.kind == CurveKind.arc) {
        return (m.getRotation() * edge!.axis).normalized();
      }
    }
    return null;
  }

  /// Punto de referencia en el mundo (punto de un plano, de un eje o centro).
  vm.Vector3? get origin {
    final m = instance.world;
    if (face != null && face!.kind != SurfaceKind.other) {
      return m.transformed3(face!.point.clone());
    }
    if (edge != null) {
      return m.transformed3(
        (edge!.kind == CurveKind.line ? edge!.start : edge!.center).clone(),
      );
    }
    return null;
  }
}

/// Resultado de relacionar dos entidades.
class MeasureResult {
  MeasureResult(this.lines, this.a, this.b);
  final List<(String, String)> lines; // (etiqueta, valor)
  final vm.Vector3? a, b; // puntos para dibujar la cota

  /// Valor que se escribe sobre la cota: la distancia mínima entre las dos entidades.
  String? get main {
    for (final l in lines) {
      if (l.$1 == tr('Distancia mínima') || l.$1 == tr('Mínima entre superficies')) {
        return l.$2;
      }
    }
    return lines.isEmpty ? null : lines.first.$2;
  }
}

/// Estado de las herramientas de revisión CAD: medir, sección, explosión, transparencia.
class CadController extends ChangeNotifier {
  CadController(this.scene) : _fileUnit = LengthUnit.fromFile(scene.cad?.unit ?? 'MM');
  final LengthUnit _fileUnit;
  final Scene scene;
  final RenderOptions options = RenderOptions();
  /// Unidad de las cotas: la del archivo; en imperial, las métricas se muestran en pulgadas.
  LengthUnit get unit => Units.forFile(_fileUnit);

  // ---- Medición
  bool measuring = false;
  final List<PickedEntity> picks = [];
  MeasureResult? result;
  final Map<int, List<Hole>> _holes = {};

  // ---- Anotaciones del archivo (PMI)
  List<PmiItem> get pmi => scene.cad?.pmi ?? const [];
  bool showAllPmi = false;
  PmiItem? selectedPmi;

  void toggleAllPmi() {
    showAllPmi = !showAllPmi;
    _syncPmi();
    notifyListeners();
  }

  void selectPmi(PmiItem? item) {
    selectedPmi = item;
    picks.clear();
    result = null;
    _syncPmi();
    notifyListeners();
  }

  static Float32List _verts(Float32List segs) {
    final out = Float32List(segs.length ~/ 6 * 12);
    for (var i = 0, o = 0; i < segs.length; i += 6, o += 12) {
      out[o] = segs[i];
      out[o + 1] = segs[i + 1];
      out[o + 2] = segs[i + 2];
      out[o + 5] = 1;
      out[o + 6] = segs[i + 3];
      out[o + 7] = segs[i + 4];
      out[o + 8] = segs[i + 5];
      out[o + 11] = 1;
    }
    return out;
  }

  Float32List? _allPmiVerts;

  void _syncPmi() {
    final lines = <LineBuf>[];
    if (showAllPmi) {
      _allPmiVerts ??= () {
        var total = 0;
        for (final p in pmi) {
          total += p.segments.length;
        }
        final all = Float32List(total);
        var at = 0;
        for (final p in pmi) {
          all.setAll(at, p.segments);
          at += p.segments.length;
        }
        return _verts(all);
      }();
      lines.add(LineBuf(_allPmiVerts!, DT.mint));
    }
    final sel = selectedPmi;
    if (sel != null && sel.hasGraphic) {
      lines.add(LineBuf(_verts(sel.segments), DT.orange));
    }
    options.pmiLines = lines;
    final hl = <Highlight>[];
    if (sel != null) {
      final byPart = <int, List<int>>{};
      for (final r in sel.refs) {
        if (r.isEdge) {
          final node = _nodeOfPart(r.part);
          if (node != null) hl.add(Highlight(node, edge: r.index));
        } else {
          (byPart[r.part] ??= []).add(r.index);
        }
      }
      byPart.forEach((part, faces) {
        final node = _nodeOfPart(part);
        if (node != null) hl.add(Highlight(node, faces: faces));
      });
    }
    options.highlights = hl;
  }

  SceneNode? _nodeOfPart(int partId) {
    for (final i in scene.instances(onlyVisible: false)) {
      if (i.part.id == partId) return i.node;
    }
    return null;
  }

  // ---- Sección
  int sectionAxis = -1; // 0 X, 1 Y, 2 Z
  double sectionT = 0.5;
  bool sectionFlip = false;

  void toggleMeasure() {
    measuring = !measuring;
    clearPicks();
    notifyListeners();
  }

  void clearPicks() {
    picks.clear();
    result = null;
    _syncHighlights();
  }

  List<Hole> holesOf(Part part) {
    final brep = part.brep;
    final cad = scene.cad;
    if (brep == null || cad == null) return const [];
    return _holes.putIfAbsent(
      part.id,
      () => findHoles(cad, part.id, brep.faceCount),
    );
  }

  Hole? holeContaining(Part part, int face) {
    for (final h in holesOf(part)) {
      if (h.faces.contains(face)) return h;
    }
    return null;
  }

  /// Toca un punto de la pantalla con la herramienta de medir.
  void tapMeasure(OrbitCamera cam, Offset p, Size size) {
    final cad = scene.cad;
    if (cad == null) return;
    final hit = pickHit(
      scene,
      cam,
      p.dx,
      p.dy,
      size.width,
      size.height,
      explode: options.explode,
    );
    if (hit == null) {
      clearPicks();
      notifyListeners();
      return;
    }
    final brep = hit.instance.part.brep;
    if (brep == null || hit.triangle >= brep.faceOfTriangle.length) return;

    // ¿Hay una arista cerca del dedo y no tapada por la cara tocada?
    final edgeIdx = _nearestEdge(cam, hit, p, size);
    PickedEntity picked;
    if (edgeIdx != null) {
      picked = PickedEntity(
        instance: hit.instance,
        isEdge: true,
        index: edgeIdx,
        edge: cad.edgeInfo(hit.instance.part.id, edgeIdx),
        point: hit.world,
      );
    } else {
      final f = brep.faceOfTriangle[hit.triangle];
      picked = PickedEntity(
        instance: hit.instance,
        isEdge: false,
        index: f,
        face: cad.faceInfo(hit.instance.part.id, f),
        point: hit.world,
      );
    }
    // Tocar de nuevo la misma entidad la quita de la selección.
    final dup = picks.indexWhere(
      (q) =>
          q.instance.node == picked.instance.node &&
          q.isEdge == picked.isEdge &&
          q.index == picked.index,
    );
    if (dup >= 0 && picks.length < 2) {
      picks.removeAt(dup);
      result = null;
      _syncHighlights();
      notifyListeners();
      return;
    }
    if (picks.length >= 2) picks.clear();
    picks.add(picked);
    result = picks.length == 2 ? _relate(picks[0], picks[1]) : null;
    _syncHighlights();
    notifyListeners();
  }

  int? _nearestEdge(OrbitCamera cam, Hit hit, Offset tap, Size size) {
    final brep = hit.instance.part.brep;
    if (brep == null || brep.edgeSegments.isEmpty) return null;
    final mvp =
        cam.projection(size.width / size.height) *
        cam.viewMatrix() *
        hit.instance.world;
    final seg = brep.edgeSegments;
    final ids = brep.edgeOfSegment;
    double best = 14 * 14;
    int? bestEdge;
    Offset toScreen(double x, double y, double z, List<double> depth) {
      final v = vm.Vector4(x, y, z, 1)..applyMatrix4(mvp);
      depth[0] = v.w;
      return Offset(
        (v.x / v.w * 0.5 + 0.5) * size.width,
        (1 - (v.y / v.w * 0.5 + 0.5)) * size.height,
      );
    }

    final d0 = [0.0], d1 = [0.0];
    final eyeDist = (hit.world - cam.eye).length;
    final tol = scene.bounds().radius * 0.03;
    for (var i = 0; i < ids.length; i++) {
      final b = i * 6;
      final a = toScreen(seg[b], seg[b + 1], seg[b + 2], d0);
      final c = toScreen(seg[b + 3], seg[b + 4], seg[b + 5], d1);
      final dx = c.dx - a.dx, dy = c.dy - a.dy;
      final l2 = dx * dx + dy * dy;
      var t = l2 == 0
          ? 0.0
          : (((tap.dx - a.dx) * dx + (tap.dy - a.dy) * dy) / l2).clamp(
              0.0,
              1.0,
            );
      final px = a.dx + dx * t - tap.dx, py = a.dy + dy * t - tap.dy;
      final d2 = px * px + py * py;
      if (d2 < best) {
        // La arista no debe quedar por detrás de la superficie tocada.
        final depth = d0[0] + (d1[0] - d0[0]) * t;
        if (depth <= eyeDist + tol * 2 || cam.ortho) {
          best = d2;
          bestEdge = ids[i];
        }
      }
    }
    return bestEdge;
  }

  void _syncHighlights() {
    options.highlights = [
      for (final p in picks)
        Highlight(
          p.instance.node,
          faces: p.isEdge
              ? const []
              : (holeContaining(p.part, p.index)?.faces ?? [p.index]),
          edge: p.isEdge ? p.index : null,
        ),
    ];
  }

  // ---- Descripción de una entidad
  String describe(PickedEntity e) {
    if (e.edge != null) {
      final x = e.edge!;
      switch (x.kind) {
        case CurveKind.line:
          return tr('Arista recta · {l}', {'l': unit.length(x.length)});
        case CurveKind.circle:
          return tr('Circunferencia · Ø {d}', {'d': unit.length(x.radius * 2)});
        case CurveKind.arc:
          return tr('Arco · R {r} · {l}', {'r': unit.length(x.radius), 'l': unit.length(x.length)});
        case CurveKind.other:
          return tr('Arista · {l}', {'l': unit.length(x.length)});
      }
    }
    final f = e.face!;
    switch (f.kind) {
      case SurfaceKind.plane:
        return tr('Plano · {a}', {'a': unit.area(f.area)});
      case SurfaceKind.cylinder:
        if (f.concave) {
          final h = holeContaining(e.part, e.index);
          final depth = h == null ? f.length : h.depth;
          return tr('Agujero · Ø {d} · prof. {p}', {'d': unit.length(f.radius * 2), 'p': unit.length(depth)});
        }
        return tr('Cilindro · Ø {d}', {'d': unit.length(f.radius * 2)});
      case SurfaceKind.cone:
        return f.concave ? tr('Avellanado · cono') : tr('Cono');
      case SurfaceKind.sphere:
        return tr('Esfera · Ø {d}', {'d': unit.length(f.radius * 2)});
      case SurfaceKind.torus:
        return tr('Toroide · R {r}', {'r': unit.length(f.radius)});
      case SurfaceKind.other:
        return tr('Superficie · {a}', {'a': unit.area(f.area)});
    }
  }

  // ---- Relación entre dos entidades
  MeasureResult _relate(PickedEntity a, PickedEntity b) {
    final lines = <(String, String)>[];
    final cad = scene.cad!;
    final dist = cad.distance(
      a.part.id,
      a.isEdge,
      a.index,
      a.instance.world,
      b.part.id,
      b.isEdge,
      b.index,
      b.instance.world,
    );
    final da = a.direction, db = b.direction;
    final oa = a.origin, ob = b.origin;
    final kindA = a.face?.kind, kindB = b.face?.kind;
    var shown = false;

    if (da != null && db != null && oa != null && ob != null) {
      final cross = da.cross(db).length;
      final parallel = cross < 1e-3;
      final angle = math.acos(da.dot(db).abs().clamp(0.0, 1.0)) * 180 / math.pi;
      final isPlaneA = kindA == SurfaceKind.plane;
      final isPlaneB = kindB == SurfaceKind.plane;
      final axisA =
          kindA == SurfaceKind.cylinder ||
          (a.edge != null && a.edge!.kind != CurveKind.line);
      final axisB =
          kindB == SurfaceKind.cylinder ||
          (b.edge != null && b.edge!.kind != CurveKind.line);
      if (isPlaneA && isPlaneB && parallel) {
        lines.add((
          tr('Distancia entre planos'),
          unit.length(((ob - oa).dot(da)).abs()),
        ));
        shown = true;
      } else if ((isPlaneA && axisB) || (axisA && isPlaneB)) {
        final plane = isPlaneA ? a : b;
        final other = isPlaneA ? b : a;
        final n = plane.direction!;
        if (n.dot(other.direction!).abs() < 1e-3) {
          lines.add((
            tr('Eje a plano'),
            unit.length(((other.origin! - plane.origin!).dot(n)).abs()),
          ));
          shown = true;
        }
      } else if (axisA && axisB && parallel) {
        final d = ob - oa;
        final perp = d - da * d.dot(da);
        lines.add((tr('Distancia entre ejes'), unit.length(perp.length)));
        shown = true;
      }
      // Ángulo solo entre entidades comparables: plano–plano, eje–eje o recta–recta.
      final lineA = a.edge != null && a.edge!.kind == CurveKind.line;
      final lineB = b.edge != null && b.edge!.kind == CurveKind.line;
      final comparable =
          (isPlaneA && isPlaneB) || ((axisA || lineA) && (axisB || lineB));
      if (comparable && !parallel) {
        lines.add((tr('Ángulo'), '${angle.toStringAsFixed(1).ldec}°'));
      }
    }
    if (dist != null) {
      lines.add((
        shown ? tr('Mínima entre superficies') : tr('Distancia mínima'),
        unit.length(dist.distance),
      ));
    }
    if (lines.isEmpty) lines.add((tr('Medida'), tr('No disponible')));
    return MeasureResult(lines, dist?.a, dist?.b);
  }

  // ---- Sección
  void setSection(int axis, {double? t, bool? flip}) {
    sectionAxis = axis;
    if (t != null) sectionT = t;
    if (flip != null) sectionFlip = flip;
    _applyClip();
    notifyListeners();
  }

  void clearSection() {
    sectionAxis = -1;
    options.clip = null;
    notifyListeners();
  }

  void _applyClip() {
    if (sectionAxis < 0) {
      options.clip = null;
      return;
    }
    final b = scene.bounds();
    final lo = b.min[sectionAxis], hi = b.max[sectionAxis];
    final d = lo + (hi - lo) * sectionT;
    final n = vm.Vector3.zero()..[sectionAxis] = sectionFlip ? -1.0 : 1.0;
    options.clip = vm.Vector4(n.x, n.y, n.z, sectionFlip ? -d : d);
  }

  void setExplode(double v) {
    options.explode = v;
    notifyListeners();
  }

  void toggleEdges() {
    options.edges = !options.edges;
    notifyListeners();
  }

  void toggleGhost() {
    options.ghostOthers = !options.ghostOthers;
    notifyListeners();
  }

  void changed() => notifyListeners();
}

// =============================================================== Interfaz

/// Tarjeta inferior con la medida en curso.
class CadMeasureCard extends StatelessWidget {
  const CadMeasureCard(this.ctrl, {super.key});
  final CadController ctrl;

  @override
  Widget build(BuildContext context) {
    final picks = ctrl.picks;
    return Glass(
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      color: const Color(0xE6101B1F),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: picks.isEmpty
                ? Text(
                    tr('Toca una cara, un agujero o una arista'),
                    style: const TextStyle(color: DT.muted, fontSize: 14),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < picks.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            '${i == 0 ? 'A' : 'B'} · ${ctrl.describe(picks[i])}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: i == 0 ? DT.orangeSoft : DT.text,
                            ),
                          ),
                        ),
                      if (picks.length == 1)
                        Text(
                          tr('Toca otra para medir entre las dos'),
                          style: const TextStyle(color: DT.muted, fontSize: 12.5),
                        ),
                      if (ctrl.result != null) ...[
                        const Divider(height: 14, color: DT.border),
                        for (final (label, value) in ctrl.result!.lines)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    label,
                                    style: const TextStyle(
                                      color: DT.muted,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                Text(
                                  value,
                                  style: const TextStyle(
                                    color: DT.mint,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
          IconButton(
            tooltip: tr('Cerrar'),
            onPressed: ctrl.toggleMeasure,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

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

/// Hoja de vistas estándar y proyección.
Future<void> showViewsSheet(
  BuildContext context, {
  required bool ortho,
  required void Function(double yaw, double pitch) onView,
  required VoidCallback onToggleOrtho,
}) {
  final views = <(String, IconData, double, double)>[
    (tr('Isométrica'), Icons.view_in_ar_outlined, -0.785, 0.615),
    (tr('Frontal'), Icons.crop_square_rounded, -1.5708, 0),
    (tr('Posterior'), Icons.flip_to_back_rounded, 1.5708, 0),
    (tr('Izquierda'), Icons.chevron_left_rounded, 3.1416, 0),
    (tr('Derecha'), Icons.chevron_right_rounded, 0, 0),
    (tr('Superior'), Icons.vertical_align_top_rounded, -1.5708, 1.5),
    (tr('Inferior'), Icons.vertical_align_bottom_rounded, -1.5708, -1.5),
  ];
  return _sheet(
    context,
    StatefulBuilder(
      builder: (ctx, set) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(tr('Vistas')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (name, icon, yaw, pitch) in views)
                ActionChip(
                  avatar: Icon(icon, size: 18),
                  label: Text(name),
                  onPressed: () {
                    onView(yaw, pitch);
                    Navigator.of(ctx).pop();
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Vista ortográfica')),
            subtitle: Text(
              tr('Sin perspectiva: las medidas se ven a escala'),
              style: const TextStyle(color: DT.muted, fontSize: 12.5),
            ),
            value: ortho,
            onChanged: (_) {
              onToggleOrtho();
              Navigator.of(ctx).pop();
            },
          ),
        ],
      ),
    ),
  );
}

/// Hoja de sección: eje, posición y sentido.
Future<void> showSectionSheet(BuildContext context, CadController c) {
  return _sheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(
            tr('Sección'),
            sub: tr('Corta la pieza con un plano para ver el interior'),
          ),
          Wrap(
            spacing: 8,
            children: [
              for (var a = 0; a < 3; a++)
                ChoiceChip(
                  label: Text(tr('Plano {n}', {'n': ['X', 'Y', 'Z'][a]})),
                  selected: c.sectionAxis == a,
                  onSelected: (_) => c.setSection(a),
                ),
            ],
          ),
          if (c.sectionAxis >= 0) ...[
            const SizedBox(height: 10),
            Text(
              tr('Posición {a} = {v}', {
                'a': ['X', 'Y', 'Z'][c.sectionAxis],
                'v': c.unit.length(c.scene.bounds().min[c.sectionAxis] + (c.scene.bounds().max[c.sectionAxis] - c.scene.bounds().min[c.sectionAxis]) * c.sectionT),
              }),
              style: const TextStyle(
                color: DT.mint,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            Slider(
              value: c.sectionT,
              onChanged: (v) => c.setSection(c.sectionAxis, t: v),
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () =>
                      c.setSection(c.sectionAxis, flip: !c.sectionFlip),
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: Text(tr('Invertir lado')),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    c.clearSection();
                    Navigator.of(ctx).pop();
                  },
                  child: Text(tr('Quitar sección')),
                ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

/// Hoja de explosión del conjunto.
Future<void> showExplodeSheet(BuildContext context, CadController c) {
  return _sheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(
            tr('Explosionar'),
            sub: tr('Separa las piezas desde el centro del conjunto'),
          ),
          Text(
            c.options.explode == 0
                ? tr('Montado')
                : tr('Separación ×{n}', {'n': c.options.explode.toStringAsFixed(2).ldec}),
            style: const TextStyle(color: DT.mint, fontWeight: FontWeight.w700),
          ),
          Slider(
            value: c.options.explode.clamp(0.0, 2.0),
            max: 2.0,
            onChanged: c.setExplode,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => c.setExplode(0),
              child: Text(tr('Montar')),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Hoja de información: tamaño, volumen, masa, origen del archivo y fiabilidad.
Future<void> showInfoSheet(
  BuildContext context,
  CadController c,
  Set<SceneNode> selected,
) {
  final cad = c.scene.cad!;
  final inst = c.scene.instances(onlyVisible: false);
  final target = selected.isEmpty
      ? null
      : c.scene.instancesOf(selected).map((i) => i.part).toSet().toList();
  final parts = target ?? c.scene.parts;
  final u = c.unit;
  // -1 = material y densidad que declara el archivo (si todas las piezas lo traen).
  final fromFile =
      parts.isNotEmpty &&
      parts.every((p) => (p.brep?.materialDensity ?? 0) > 0);
  var material = fromFile ? -1 : 0;
  // Con muchas piezas, las propiedades exactas se calculan tras abrir la hoja.
  var ready = parts.length <= 12;
  var scheduled = false;
  return _sheet(
    context,
    StatefulBuilder(
      builder: (ctx, set) {
        if (!ready && !scheduled) {
          scheduled = true;
          Future.delayed(const Duration(milliseconds: 120), () {
            for (final p in parts) {
              cad.props(p.id);
            }
            ready = true;
            try {
              set(() {});
            } catch (_) {}
          });
        }
        double vol = 0, area = 0;
        bool? ok;
        for (final p in ready ? parts : <Part>[]) {
          final pp = cad.props(p.id);
          final count = inst.where((i) => i.part == p).length;
          vol += pp.volume * count;
          area += pp.area * count;
          final m = pp.volumeMatches;
          if (m != null) ok = (ok ?? true) && m;
        }
        final b = parts.length == 1
            ? parts.first.mesh.bounds
            : c.scene.bounds();
        final s = b.size;
        var grams = 0.0;
        if (material < 0) {
          for (final p in parts) {
            final count = inst.where((i) => i.part == p).length;
            grams +=
                cad.props(p.id).volume *
                count /
                1000.0 *
                p.brep!.materialDensity;
          }
        } else {
          grams = vol / 1000.0 * kMaterials[material].$2;
        }
        final names = {
          for (final p in parts)
            if ((p.brep?.materialName ?? '').isNotEmpty &&
                p.brep!.materialName != 'Generic')
              p.brep!.materialName,
        }.toList();
        Widget row(String k, String v, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Text(k, style: const TextStyle(color: DT.muted)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  v,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: color,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title(
              parts.length == 1
                  ? parts.first.name
                  : (selected.isEmpty
                        ? c.scene.name
                        : tr('{n} piezas', {'n': parts.length})),
              sub: selected.isEmpty && parts.length != 1
                  ? tr('Conjunto completo')
                  : null,
            ),
            row(
              tr('Tamaño'),
              '${u.length(s[0])} × ${u.length(s[1])} × ${u.length(s[2])}',
            ),
            row(tr('Volumen'), ready ? u.volume(vol) : tr('Calculando…')),
            row(tr('Superficie'), ready ? u.area(area) : tr('Calculando…')),
            row(
              material < 0 ? tr('Masa (según el archivo)') : tr('Masa estimada'),
              ready ? Units.mass(grams) : tr('Calculando…'),
            ),
            if (material < 0 && names.isNotEmpty)
              row(
                tr('Material'),
                names.length > 2
                    ? '${names.take(2).join(', ')} +${names.length - 2}'
                    : names.join(', '),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                if (fromFile)
                  ChoiceChip(
                    label: Text(tr('Archivo')),
                    selected: material < 0,
                    onSelected: (_) => set(() => material = -1),
                  ),
                for (var i = 0; i < kMaterials.length; i++)
                  ChoiceChip(
                    label: Text(kMaterials[i].$1),
                    selected: material == i,
                    onSelected: (_) => set(() => material = i),
                  ),
              ],
            ),
            const Divider(height: 24, color: DT.border),
            row(tr('Unidad del archivo'), u.name),
            if (cad.origin.isNotEmpty) row(tr('Creado con'), cad.origin),
            if (cad.schema.isNotEmpty)
              row(tr('Formato'), cad.schema.split(' ').first),
            if (ok != null)
              row(
                tr('Comprobación de volumen'),
                ok ? tr('Coincide con el archivo') : tr('No coincide con el archivo'),
                color: ok ? DT.mint : DT.orangeSoft,
              ),
          ],
        );
      },
    ),
  );
}

/// Lista de agujeros de la pieza o del conjunto.
Future<void> showHolesSheet(
  BuildContext context,
  CadController c, {
  required void Function(PickedEntity) onPick,
}) {
  final cad = c.scene.cad!;
  final u = c.unit;
  final rows = <(Instance, Hole)>[];
  final seen = <Part>{};
  for (final inst in c.scene.instances(onlyVisible: false)) {
    if (!seen.add(inst.part)) continue;
    for (final h in c.holesOf(inst.part)) {
      rows.add((inst, h));
    }
  }
  return _sheet(
    context,
    SizedBox(
      height: math.min(420, 120.0 + rows.length * 62),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(tr('Agujeros'), sub: tr('{n} encontrados', {'n': rows.length})),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      tr('No hay agujeros cilíndricos'),
                      style: const TextStyle(color: DT.muted),
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (ctx, i) {
                      final (inst, h) = rows[i];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: DT.orange.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.radio_button_unchecked_rounded,
                            color: DT.orangeSoft,
                          ),
                        ),
                        title: Text('Ø ${u.length(h.diameter)}'),
                        subtitle: Text(
                          h.full
                              ? tr('Profundidad {d}', {'d': u.length(h.depth)})
                              : tr('Profundidad {d} · parcial', {'d': u.length(h.depth)}),
                          style: const TextStyle(
                            color: DT.muted,
                            fontSize: 12.5,
                          ),
                        ),
                        onTap: () {
                          final f = h.faces.first;
                          onPick(
                            PickedEntity(
                              instance: inst,
                              isEdge: false,
                              index: f,
                              face: cad.faceInfo(inst.part.id, f),
                              point: inst.world.transformed3(h.start.clone()),
                            ),
                          );
                          Navigator.of(ctx).pop();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

/// Hoja con las cotas, tolerancias y referencias que trae el archivo.
Future<void> showPmiSheet(BuildContext context, CadController c) {
  var filter = -1; // -1 todas, 0 cotas, 1 tolerancias, 2 referencias
  final u = c.unit;
  return _sheet(
    context,
    StatefulBuilder(
      builder: (ctx, set) {
        final items = [
          for (final p in c.pmi)
            if (filter < 0 || p.kind.index == filter) p,
        ];
        int count(int k) => c.pmi.where((p) => p.kind.index == k).length;
        return SizedBox(
          height: math.min(560, MediaQuery.of(ctx).size.height * 0.7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title(
                tr('Cotas y tolerancias'),
                sub: tr('Las del archivo, tal como las definió quien lo creó'),
              ),
              Wrap(
                spacing: 6,
                children: [
                  ChoiceChip(
                    label: Text(tr('Todas {n}', {'n': c.pmi.length})),
                    selected: filter == -1,
                    onSelected: (_) => set(() => filter = -1),
                  ),
                  if (count(0) > 0)
                    ChoiceChip(
                      label: Text(tr('Cotas {n}', {'n': count(0)})),
                      selected: filter == 0,
                      onSelected: (_) => set(() => filter = 0),
                    ),
                  if (count(1) > 0)
                    ChoiceChip(
                      label: Text(tr('Tolerancias {n}', {'n': count(1)})),
                      selected: filter == 1,
                      onSelected: (_) => set(() => filter = 1),
                    ),
                  if (count(2) > 0)
                    ChoiceChip(
                      label: Text(tr('Referencias {n}', {'n': count(2)})),
                      selected: filter == 2,
                      onSelected: (_) => set(() => filter = 2),
                    ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(tr('Dibujarlas sobre el modelo')),
                value: c.showAllPmi,
                onChanged: (_) {
                  c.toggleAllPmi();
                  set(() {});
                },
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (ctx, i) {
                    final p = items[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: DT.orange.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Icon(
                          switch (p.kind) {
                            PmiKind.dimension => Icons.straighten_rounded,
                            PmiKind.tolerance => Icons.adjust_rounded,
                            PmiKind.datum => Icons.flag_outlined,
                          },
                          color: DT.orangeSoft,
                          size: 20,
                        ),
                      ),
                      title: Text(
                        p.describe(u),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${p.name}${p.refs.isEmpty ? '' : ' · ${p.refs.length == 1 ? tr('{n} cara', {'n': 1}) : tr('{n} caras', {'n': p.refs.length})}'}',
                        style: const TextStyle(color: DT.muted, fontSize: 12.5),
                      ),
                      onTap: () {
                        c.selectPmi(p);
                        Navigator.of(ctx).pop();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// Tarjeta inferior con la anotación elegida.
class CadPmiCard extends StatelessWidget {
  const CadPmiCard(this.ctrl, {super.key});
  final CadController ctrl;

  @override
  Widget build(BuildContext context) {
    final p = ctrl.selectedPmi!;
    return Glass(
      radius: 22,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      color: const Color(0xE6101B1F),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.describe(ctrl.unit),
                  style: const TextStyle(
                    color: DT.orangeSoft,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  p.name,
                  style: const TextStyle(color: DT.muted, fontSize: 13),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: tr('Cerrar'),
            onPressed: () => ctrl.selectPmi(null),
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

/// Lista de materiales en CSV, para pegarla en una hoja de cálculo.
String bomCsv(Scene scene, LengthUnit unit) {
  final counts = <Part, int>{};
  for (final i in scene.instances(onlyVisible: false)) {
    counts[i.part] = (counts[i.part] ?? 0) + 1;
  }
  final cad = scene.cad;
  final sb = StringBuffer(
    '${tr('Pieza;Cantidad;Largo ({u});Ancho ({u});Alto ({u});Volumen ({u}³)', {'u': unit.symbol})}\n',
  );
  String n(double mm) =>
      unit.fromMm(mm).toStringAsFixed(2).ldec;
  for (final e in counts.entries) {
    final s = e.key.mesh.bounds.size;
    final v = cad == null
        ? ''
        : (cad.props(e.key.id).volume /
                  (unit.mmPerUnit * unit.mmPerUnit * unit.mmPerUnit))
              .toStringAsFixed(2)
              .ldec;
    sb.writeln(
      '"${e.key.name.replaceAll('"', "'")}";${e.value};${n(s[0])};${n(s[1])};${n(s[2])};$v',
    );
  }
  return sb.toString();
}

Future<void> copyBom(BuildContext context, CadController c) async {
  await Clipboard.setData(ClipboardData(text: bomCsv(c.scene, c.unit)));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Lista de materiales copiada (pégala en Excel)')),
      ),
    );
  }
}

/// Cota dibujada sobre el modelo para la medición de dos entidades.
class CadOverlayPainter extends CustomPainter {
  CadOverlayPainter(this.cam, this.ctrl, Listenable repaint)
    : super(repaint: repaint);
  final OrbitCamera cam;
  final CadController ctrl;

  Offset? _project(vm.Vector3 p, Size size) {
    final m = cam.projection(size.width / size.height) * cam.viewMatrix();
    final v = vm.Vector4(p.x, p.y, p.z, 1)..applyMatrix4(m);
    if (v.w <= 0) return null;
    return Offset(
      (v.x / v.w * 0.5 + 0.5) * size.width,
      (1 - (v.y / v.w * 0.5 + 0.5)) * size.height,
    );
  }

  void _label(Canvas canvas, Offset at, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 14,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromCenter(
      center: at,
      width: tp.width + 16,
      height: tp.height + 8,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(10)),
      Paint()..color = const Color(0xE6101B1F),
    );
    tp.paint(canvas, rect.topLeft + const Offset(8, 4));
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Etiqueta de la anotación elegida, junto a su dibujo.
    final sel = ctrl.selectedPmi;
    if (sel != null) {
      vm.Vector3? anchor;
      if (sel.v[10] != 0 || sel.v[11] != 0 || sel.v[12] != 0) {
        anchor = vm.Vector3(sel.v[10], sel.v[11], sel.v[12]);
      } else if (sel.segments.isNotEmpty) {
        var x = 0.0, y = 0.0, z = 0.0;
        final n = sel.segments.length ~/ 3;
        for (var i = 0; i < sel.segments.length; i += 3) {
          x += sel.segments[i];
          y += sel.segments[i + 1];
          z += sel.segments[i + 2];
        }
        anchor = vm.Vector3(x / n, y / n, z / n);
      }
      if (anchor != null) {
        final p = _project(anchor, size);
        if (p != null) {
          _label(
            canvas,
            p.translate(0, -22),
            sel.describe(ctrl.unit),
            DT.orangeSoft,
          );
        }
      }
    }
    final r = ctrl.result;
    if (r == null || r.a == null || r.b == null) return;
    final a = _project(r.a!, size), b = _project(r.b!, size);
    if (a == null || b == null) return;
    final line = Paint()
      ..color = DT.mint
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(a, b, line);
    final dot = Paint()..color = DT.mint;
    canvas.drawCircle(a, 4.5, dot);
    canvas.drawCircle(b, 4.5, dot);
    final main = r.main;
    if (main != null) _label(canvas, Offset.lerp(a, b, 0.5)!, main, DT.mint);
  }

  @override
  bool shouldRepaint(covariant CadOverlayPainter old) => true;
}

/// Cubo de vistas: refleja la orientación de la cámara y cada cara lleva a su vista estándar.
class ViewCube extends StatelessWidget {
  const ViewCube({super.key, required this.cam, required this.onView});
  final OrbitCamera cam;
  final void Function(double yaw, double pitch) onView;

  static const double size = 84;

  // Caras: nombre, normal en el mundo, vista (yaw, pitch).
  static final _faces = <(String, vm.Vector3, double, double)>[
    ('FRONT', vm.Vector3(0, -1, 0), -1.5708, 0),
    ('POST', vm.Vector3(0, 1, 0), 1.5708, 0),
    ('DER', vm.Vector3(1, 0, 0), 0, 0),
    ('IZQ', vm.Vector3(-1, 0, 0), 3.1416, 0),
    ('SUP', vm.Vector3(0, 0, 1), -1.5708, 1.5),
    ('INF', vm.Vector3(0, 0, -1), -1.5708, -1.5),
  ];

  static List<vm.Vector3> _corners(vm.Vector3 n) {
    // Cuatro esquinas de la cara de normal n, en el cubo unidad centrado.
    final u = n.x.abs() > 0.5 ? vm.Vector3(0, 1, 0) : vm.Vector3(1, 0, 0);
    final v = n.cross(u);
    return [n + u + v, n - u + v, n - u - v, n + u - v];
  }

  List<(int, List<Offset>, double)> _project() {
    final view = cam.viewMatrix().getRotation();
    final eye = (cam.eye - cam.target).normalized();
    const s = size * 0.27;
    const c = Offset(size / 2, size / 2);
    final out = <(int, List<Offset>, double)>[];
    for (var i = 0; i < _faces.length; i++) {
      final n = _faces[i].$2;
      final facing = n.dot(eye);
      if (facing <= 0.02) continue;
      final pts = [
        for (final p in _corners(n))
          () {
            final q = view * p;
            return Offset(c.dx + q.x * s, c.dy - q.y * s);
          }(),
      ];
      out.add((i, pts, facing));
    }
    return out;
  }

  static bool _inside(List<Offset> poly, Offset p) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final a = poly[i], b = poly[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: cam,
      builder: (context, _) => GestureDetector(
        onTapUp: (d) {
          final faces = _project()..sort((a, b) => b.$3.compareTo(a.$3));
          for (final f in faces) {
            if (_inside(f.$2, d.localPosition)) {
              onView(_faces[f.$1].$3, _faces[f.$1].$4);
              return;
            }
          }
        },
        child: SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _CubePainter(_project(), _faces)),
        ),
      ),
    );
  }
}

class _CubePainter extends CustomPainter {
  _CubePainter(this.faces, this.names);
  final List<(int, List<Offset>, double)> faces;
  final List<(String, vm.Vector3, double, double)> names;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (i, pts, facing) in faces) {
      final path = Path()..addPolygon(pts, true);
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.lerp(
            const Color(0xCC1A2A30),
            const Color(0xCC2F4A52),
            facing,
          )!,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0x55EAF3F4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      var area = 0.0;
      for (var k = 0; k < pts.length; k++) {
        final p = pts[k], q = pts[(k + 1) % pts.length];
        area += p.dx * q.dy - q.dx * p.dy;
      }
      if (area.abs() / 2 > 420) {
        var cx = 0.0, cy = 0.0;
        for (final p in pts) {
          cx += p.dx;
          cy += p.dy;
        }
        final tp = TextPainter(
          text: TextSpan(
            text: tr(names[i].$1),
            style: TextStyle(
              color: DT.text.withValues(alpha: 0.9),
              fontSize: 7.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(cx / 4 - tp.width / 2, cy / 4 - tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CubePainter old) => true;
}
