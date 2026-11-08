import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../io/loader.dart' show extraFilesDir;
import '../l10n/l10n.dart';
import '../model/mesh.dart';
import '../model/mesh_check.dart';
import '../model/mesh_info.dart';
import '../model/material.dart';
import '../model/scene.dart';
import '../render/camera.dart';
import '../render/gpu_mesh.dart';
import '../render/lod.dart';
import '../model/rig.dart';
import 'glass.dart';
import 'threemf_tools.dart' show ThreeMfController;
import 'rig_player.dart';
import 'stl_tools.dart' show datumSheet, fmtNum, sheetLabel, sheetRow, sheetTitle;
import 'theme.dart';
import '../model/unit_system.dart';

/// Giro que lleva el eje vertical del archivo (`x`, `y` o `z`) al eje Z de Datum.
vm.Matrix4 upMatrix(String up) => switch (up) {
  'y' => vm.Matrix4.fromList([1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1]),
  'x' => vm.Matrix4.fromList([0, 0, 1, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 0, 1]),
  _ => vm.Matrix4.identity(),
};

/// Estado de un archivo de malla abierto (glTF, OBJ, PLY): orientación, texturas, piezas ocultas y medida.
class MeshFileController extends ChangeNotifier {
  MeshFileController(this.scene, this.info, this.path) {
    options.edges = false;
    options.capClip = false;
    up = info.up;
    scene.root.transform.setFrom(upMatrix(up));
    final r = info.rig;
    if (r is Rig && (r.animations.isNotEmpty || r.prims.isNotEmpty)) {
      player = RigPlayer(scene, r, onFrame: notifyListeners);
    }
    _buildLod();
  }

  /// Animaciones del archivo (glTF), si las hay.
  RigPlayer? player;

  /// Variante de material elegida (−1 = la del archivo por defecto).
  int variant = -1;

  /// Cambia el material de cada pieza según la variante (`KHR_materials_variants`).
  void selectVariant(int v) {
    variant = v;
    for (final e in info.variantParts.entries) {
      if (e.key >= scene.parts.length) continue;
      final mi = e.value[v];
      if (mi == null || mi >= info.variantMaterials.length) continue;
      scene.parts[e.key].material = info.variantMaterials[mi] as SurfaceMaterial;
    }
    options.clip = options.clip;
    notifyListeners();
  }

  // Sección: plano alineado con un eje del mundo (−1 = sin sección).
  int sectionAxis = -1;
  double sectionT = 0.5;
  bool sectionFlip = false;

  void setSection(int axis, {double? t, bool? flip}) {
    sectionAxis = axis;
    if (t != null) sectionT = t;
    if (flip != null) sectionFlip = flip;
    _applySection();
    notifyListeners();
  }

  void toggleCap() {
    options.capClip = !options.capClip;
    notifyListeners();
  }

  void clearSection() {
    sectionAxis = -1;
    _applySection();
    notifyListeners();
  }

  void _applySection() {
    if (sectionAxis < 0) {
      options.clip = null;
      return;
    }
    final b = scene.bounds();
    final pos = b.min[sectionAxis] + (b.max[sectionAxis] - b.min[sectionAxis]) * sectionT;
    final n = [0.0, 0.0, 0.0]..[sectionAxis] = sectionFlip ? -1 : 1;
    options.clip = vm.Vector4(n[0], n[1], n[2], sectionFlip ? -pos : pos);
  }

  /// Revisión de la malla (agujeros, aristas no-manifold, cascos, volumen).
  MeshReport? report;
  bool reviewing = false;

  Future<void> review() async {
    if (reviewing) return;
    reviewing = true;
    notifyListeners();
    try {
      // todas las piezas con geometría, desplegadas en triángulos sueltos
      var tris = 0;
      for (final p in scene.parts) {
        tris += p.mesh.triangleCount;
      }
      if (tris > 3000000) {
        report = null;
        return;
      }
      final out = Float32List(tris * 18);
      var o = 0;
      for (final p in scene.parts) {
        final m = p.mesh, v = m.vertices, ix = m.indices;
        final nt = m.triangleCount;
        for (var t = 0; t < nt; t++) {
          for (var k = 0; k < 3; k++) {
            final vi = (ix == null ? t * 3 + k : ix[t * 3 + k]) * 6;
            out[o] = v[vi];
            out[o + 1] = v[vi + 1];
            out[o + 2] = v[vi + 2];
            o += 6;
          }
        }
      }
      report = await checkMesh(out);
    } finally {
      reviewing = false;
      notifyListeners();
    }
  }

  /// Versión simplificada para girar modelos enormes (más de 400 mil triángulos).
  Scene? get lodScene => _lod?.scene;
  LodScene? _lod;

  Future<void> _buildLod() async {
    _lod = await buildLodScene(scene);
    if (_lod != null) notifyListeners();
  }

  @override
  void dispose() {
    player?.dispose();
    super.dispose();
  }
  final Scene scene;
  final MeshFileInfo info;
  final String path;
  final RenderOptions options = RenderOptions();

  late String up;
  bool textures = true;
  bool measuring = false;
  final points = <vm.Vector3>[];
  final hidden = <SceneNode>{};

  bool get hasAppearance =>
      scene.textures.isNotEmpty || info.hasColors || info.materials.any((m) => m.alpha != 'opaco');

  void setUp(String u) {
    up = u;
    scene.root.transform.setFrom(upMatrix(u));
    _lod?.sync();
    if (sectionAxis >= 0) _applySection();
    points.clear();
    _lines();
    notifyListeners();
  }

  void cycleUp() => setUp(up == 'z' ? 'y' : (up == 'y' ? 'x' : 'z'));

  void toggleTextures() {
    textures = !textures;
    options.plainMaterials = !textures;
    notifyListeners();
  }

  void toggleMeasure() {
    measuring = !measuring;
    points.clear();
    _lines();
    notifyListeners();
  }

  void addPoint(vm.Vector3 p) {
    if (points.length >= 2) points.clear();
    points.add(p);
    _lines();
    notifyListeners();
  }

  void toggleNode(SceneNode n) {
    n.visible = !n.visible;
    n.visible ? hidden.remove(n) : hidden.add(n);
    _lod?.sync();
    notifyListeners();
  }

  void showAll() {
    for (final n in hidden) {
      n.visible = true;
    }
    hidden.clear();
    _lod?.sync();
    notifyListeners();
  }

  String? get measureText {
    if (points.length < 2) return null;
    final d = points[1] - points[0];
    String f(double v) => Units.len(v);
    return tr('Distancia {d}  ·  ΔX {x}  ·  ΔY {y}  ·  ΔZ {z}   (unidades del archivo)', {'d': f(d.length), 'x': f(d.x.abs()), 'y': f(d.y.abs()), 'z': f(d.z.abs())});
  }

  void _lines() {
    if (points.isEmpty) {
      options.pmiLines = const [];
      return;
    }
    final b = scene.bounds();
    final r = b.radius * 0.02;
    final s = <double>[];
    for (final p in points) {
      s.addAll([p.x - r, p.y, p.z, p.x + r, p.y, p.z]);
      s.addAll([p.x, p.y - r, p.z, p.x, p.y + r, p.z]);
      s.addAll([p.x, p.y, p.z - r, p.x, p.y, p.z + r]);
    }
    if (points.length == 2) s.addAll([...points[0].storage, ...points[1].storage]);
    final v = Float32List(s.length ~/ 3 * 6);
    var o = 0;
    for (var i = 0; i + 2 < s.length; i += 3) {
      v[o++] = s[i];
      v[o++] = s[i + 1];
      v[o++] = s[i + 2];
      v[o++] = 0;
      v[o++] = 0;
      v[o++] = 1;
    }
    options.pmiLines = [LineBuf(v, DT.mint)];
  }

  /// Piezas con geometría, para la lista.
  List<SceneNode> get partNodes {
    final out = <SceneNode>[];
    void walk(SceneNode n) {
      if (n.part != null) out.add(n);
      for (final c in n.children) {
        walk(c);
      }
    }

    walk(scene.root);
    return out;
  }
}

String _mb(int bytes) => bytes >= 1 << 20 ? '${fmtNum(bytes / (1 << 20), d: 1)} MB' : '${fmtNum(bytes / 1024, d: 0)} kB';

/// Chips de la cabecera de un archivo de malla.
List<Widget> meshChips(MeshFileController c, Bounds b) {
  final i = c.info;
  final out = <Widget>[
    InfoChip(Icons.description_outlined, tr(i.format)),
    InfoChip(Icons.change_history, _count(c.scene.triangleCount, tr('triángulos'))),
  ];
  final e = [for (var k = 0; k < 3; k++) b.max[k] - b.min[k]];
  out.add(InfoChip(Icons.straighten, '${_n(e[0])} × ${_n(e[1])} × ${_n(e[2])}'));
  if (c.scene.textures.isNotEmpty) {
    out.add(InfoChip(Icons.image_outlined, c.scene.textures.length == 1 ? tr('{n} textura', {'n': 1}) : tr('{n} texturas', {'n': c.scene.textures.length})));
  } else if (i.hasColors) {
    out.add(InfoChip(Icons.palette_outlined, tr('color por vértice')));
  }
  if (i.animations.isNotEmpty) {
    out.add(InfoChip(Icons.play_circle_outline_rounded, i.animations.length == 1 ? tr('{n} animación', {'n': 1}) : tr('{n} animaciones', {'n': i.animations.length})));
  }
  if (i.missing.isNotEmpty) {
    out.add(InfoChip(Icons.warning_amber_rounded, i.missing.length == 1 ? tr('Faltan {n} archivo', {'n': 1}) : tr('Faltan {n} archivos', {'n': i.missing.length}), color: DT.orangeSoft));
  }
  return out;
}

String _n(double v) => fmtNum(v, d: v.abs() >= 100 ? 0 : (v.abs() >= 1 ? 1 : 3));
String _count(int n, String w) => n >= 1000000 ? '${fmtNum(n / 1e6, d: 2)} M $w' : (n >= 1000 ? '${fmtNum(n / 1000, d: 1)} k $w' : '$n $w');

/// Hoja con todo lo que trae el archivo: origen, geometría, materiales, texturas, extensiones, avisos.
Future<void> showMeshInfoSheet(
  BuildContext context,
  MeshFileController c, {
  required Future<void> Function() onAddFiles,
}) {
  final i = c.info;
  final kids = <Widget>[sheetTitle(c.scene.name, sub: tr(i.format))];
  void row(String k, String v) {
    if (v.trim().isNotEmpty) kids.add(sheetRow(k, v));
  }

  row(tr('Creado con'), i.generator);
  row(tr('Título'), i.title);
  row(tr('Autor'), i.author);
  row(tr('Licencia'), i.license);
  row(tr('Derechos'), i.copyright);
  kids.add(sheetLabel(tr('GEOMETRÍA')));
  row(tr('Triángulos'), '${c.scene.triangleCount}');
  if (i.vertices > 0) row(tr('Vértices'), '${i.vertices}');
  if (i.polygonsNonTri > 0) row(tr('Polígonos con más de 3 lados'), tr('{n} (triangulados)', {'n': i.polygonsNonTri}));
  row(tr('Piezas'), '${c.scene.parts.length}');
  row(tr('Normales'), i.hasNormals ? tr('del archivo') : (i.normalsComputed ? tr('calculadas (el archivo no las trae)') : '—'));
  row(tr('Coordenadas de textura'), i.hasUv ? tr('sí') : tr('no'));
  row(tr('Color por vértice'), i.hasColors ? tr('sí') : tr('no'));
  if (i.skins > 0) row(tr('Esqueletos'), '${i.skins}');
  if (i.morphTargets > 0) row(tr('Formas de morfo'), '${i.morphTargets}');
  row(tr('Eje vertical'), i.upGuessed ? tr('{u} (supuesto por la forma)', {'u': c.up.toUpperCase()}) : tr('{u} (según el formato)', {'u': c.up.toUpperCase()}));
  if (i.scalarName.isNotEmpty) {
    row(
      tr('Campo escalar'),
      i.scalarMax > i.scalarMin
          ? tr('«{n}» {a} – {b} (pintado como color)', {'n': i.scalarName, 'a': fmtNum(i.scalarMin, d: 3), 'b': fmtNum(i.scalarMax, d: 3)})
          : '«${i.scalarName}»',
    );
  }

  kids.add(sheetLabel(tr('REVISIÓN DE LA MALLA')));
  kids.add(_ReviewBlock(c));

  if (i.materials.isNotEmpty) {
    kids.add(sheetLabel(tr('MATERIALES ({n})', {'n': i.materials.length})));
    for (final m in i.materials.take(40)) {
      kids.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: Color(m.color | 0xFF000000),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x55FFFFFF)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${m.name}${m.texture != null ? ' · ${m.texture}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                [
                  if (m.alpha != 'opaco') tr(m.alpha),
                  if (m.doubleSided) tr('2 caras'),
                  if (m.unlit) tr('sin luz'),
                  if (m.emissive) tr('emisivo'),
                ].join(' · '),
                style: const TextStyle(color: DT.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    if (i.materials.length > 40) {
      kids.add(Text(tr('… y {n} más', {'n': i.materials.length - 40}), style: const TextStyle(color: DT.muted)));
    }
  }
  if (i.textures.isNotEmpty) {
    kids.add(sheetLabel(tr('TEXTURAS ({n})', {'n': i.textures.length})));
    var gpu = 0;
    for (final t in c.scene.textures) {
      gpu += t.bytes;
    }
    for (final t in i.textures) {
      SceneTexture? st;
      for (final x in c.scene.textures) {
        if (x.name == t.name) st = x;
      }
      kids.add(
        sheetRow(
          t.name,
          t.missing ? tr('falta') : (st != null && st.width > 0 ? '${st.width} × ${st.height} · ${_mb(t.bytes)}' : _mb(t.bytes)),
          color: t.missing ? DT.orangeSoft : null,
        ),
      );
    }
    if (gpu > 0) kids.add(sheetRow(tr('Memoria de texturas'), _mb(gpu)));
  }
  if (i.animations.isNotEmpty) {
    kids.add(sheetLabel(tr('ANIMACIONES')));
    for (final a in i.animations) {
      kids.add(sheetRow(a.name, tr('{s} s · {n} canales', {'s': fmtNum(a.seconds, d: 2), 'n': a.channels})));
    }
  }
  if (i.extensionsUsed.isNotEmpty || i.extensionsRequired.isNotEmpty) {
    kids.add(sheetLabel(tr('EXTENSIONES')));
    kids.add(
      Text(
        i.extensionsUsed.map((e) => i.extensionsRequired.contains(e) ? tr('{e} (obligatoria)', {'e': e}) : e).join(' · '),
        style: const TextStyle(color: DT.muted, fontSize: 13),
      ),
    );
  }
  if (i.missing.isNotEmpty) {
    kids.add(sheetLabel(tr('ARCHIVOS QUE FALTAN')));
    for (final m in i.missing) {
      kids.add(Text('· $m', style: const TextStyle(color: DT.orangeSoft)));
    }
    kids.add(
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FilledButton.tonalIcon(
          onPressed: () async {
            Navigator.of(context).pop();
            await onAddFiles();
          },
          icon: const Icon(Icons.attach_file_rounded),
          label: Text(tr('Añadir los archivos que faltan')),
        ),
      ),
    );
    kids.add(
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          tr('El modelo cita texturas o materiales que no están junto al archivo. Elígelos en la carpeta donde los tengas.'),
          style: const TextStyle(color: DT.muted, fontSize: 12),
        ),
      ),
    );
  }
  if (i.warnings.isNotEmpty) {
    kids.add(sheetLabel(tr('AVISOS')));
    for (final w in i.warnings) {
      kids.add(Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(w, style: const TextStyle(color: DT.orangeSoft, fontSize: 13))));
    }
  }
  return datumSheet(context, SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids)));
}

/// Resultado de la revisión de la malla (se calcula al pedirlo).
class _ReviewBlock extends StatelessWidget {
  const _ReviewBlock(this.c);
  final MeshFileController c;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final r = c.report;
        if (r == null) {
          return Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 4),
            child: Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: c.reviewing ? null : c.review,
                  icon: c.reviewing
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.fact_check_outlined),
                  label: Text(c.reviewing ? tr('Revisando…') : tr('Revisar la malla')),
                ),
              ],
            ),
          );
        }
        final closed = r.holes.isEmpty && r.nonManifoldEdges == 0 && r.boundaryEdges == 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sheetRow(tr('Estanca'), closed ? tr('sí') : tr('no'), color: closed ? DT.mint : DT.orangeSoft),
            if (r.holes.isNotEmpty) sheetRow(tr('Agujeros'), '${r.holes.length}', color: DT.orangeSoft),
            if (r.nonManifoldEdges > 0) sheetRow(tr('Aristas no-manifold'), '${r.nonManifoldEdges}', color: DT.orangeSoft),
            if (r.inconsistentEdges > 0) sheetRow(tr('Aristas con normales opuestas'), '${r.inconsistentEdges}', color: DT.orangeSoft),
            if (r.degenerate > 0) sheetRow(tr('Triángulos sin área'), '${r.degenerate}'),
            sheetRow(tr('Cascos sueltos'), '${r.shells.length}'),
            sheetRow(tr('Superficie'), tr('{n} (unidades² del archivo)', {'n': fmtNum(r.area, d: 3)})),
            if (closed) sheetRow(tr('Volumen'), tr('{n} (unidades³ del archivo)', {'n': fmtNum(r.volume.abs(), d: 3)})),
            sheetRow(tr('Revisado en'), '${r.milliseconds} ms'),
          ],
        );
      },
    );
  }
}

/// Hoja con las piezas del modelo: mostrar u ocultar cada una.
Future<void> showMeshPartsSheet(BuildContext context, MeshFileController c, {required void Function(Bounds) onFocus}) {
  return datumSheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) {
        final nodes = c.partNodes;
        final kids = <Widget>[
          sheetTitle(tr('Piezas'), sub: tr('{n} con geometría', {'n': nodes.length})),
          Row(
            children: [
              Text(tr('Eje vertical'), style: const TextStyle(color: DT.muted)),
              const SizedBox(width: 12),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'z', label: Text('Z')),
                  ButtonSegment(value: 'y', label: Text('Y')),
                  ButtonSegment(value: 'x', label: Text('X')),
                ],
                selected: {c.up},
                onSelectionChanged: (v) {
                  c.setUp(v.first);
                  onFocus(c.scene.bounds());
                },
              ),
              const Spacer(),
              if (c.hidden.isNotEmpty) TextButton(onPressed: c.showAll, child: Text(tr('Mostrar todo'))),
            ],
          ),
          const SizedBox(height: 6),
        ];
        for (final n in nodes.take(400)) {
          final hid = !n.visible;
          final m = n.part!.mesh;
          kids.add(
            InkWell(
              onTap: () {
                // encuadra la pieza en su posición actual
                for (final i in c.scene.instances(onlyVisible: false)) {
                  if (i.node == n) {
                    final b = m.bounds;
                    final mn = vm.Vector3(b.min[0], b.min[1], b.min[2]), mx = vm.Vector3(b.max[0], b.max[1], b.max[2]);
                    final pts = [
                      for (var k = 0; k < 8; k++)
                        i.world.transformed3(vm.Vector3((k & 1) == 0 ? mn.x : mx.x, (k & 2) == 0 ? mn.y : mx.y, (k & 4) == 0 ? mn.z : mx.z)),
                    ];
                    final lo = [for (var a = 0; a < 3; a++) pts.map((p) => p.storage[a]).reduce((x, y) => x < y ? x : y)];
                    final hi = [for (var a = 0; a < 3; a++) pts.map((p) => p.storage[a]).reduce((x, y) => x > y ? x : y)];
                    onFocus(Bounds(lo, hi));
                    Navigator.of(ctx).pop();
                    return;
                  }
                }
              },
              child: Opacity(
                opacity: hid ? 0.45 : 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      if (n.part!.material != null)
                        Container(
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.only(right: 10),
                          decoration: BoxDecoration(
                            color: Color(n.part!.material!.baseColor | 0xFF000000),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0x55FFFFFF)),
                          ),
                        ),
                      Expanded(child: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Text(_count(m.triangleCount, tr('tri')), style: const TextStyle(color: DT.muted, fontSize: 12)),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: () => c.toggleNode(n),
                        icon: Icon(hid ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20, color: DT.muted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        if (nodes.length > 400) {
          kids.add(Text(tr('… y {n} más', {'n': nodes.length - 400}), style: const TextStyle(color: DT.muted)));
        }
        return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids));
      },
    ),
  );
}

/// Pide al usuario las texturas o materiales que faltan y los guarda junto al modelo (en una
/// carpeta de la aplicación) para que la próxima lectura los encuentre.
Future<bool> pickMissingFiles(String modelPath) async {
  final res = await FilePicker.pickFiles();
  if (res.isEmpty) return false;
  final dir = Directory(extraFilesDir(modelPath))..createSync(recursive: true);
  var n = 0;
  for (final f in res) {
    final p = f.path;
    if (p == null) continue;
    final name = p.split('/').last;
    try {
      File(p).copySync('${dir.path}/$name');
      n++;
    } catch (_) {}
  }
  return n > 0;
}

/// Hoja de sección: un plano que corta la malla para ver el interior.
Future<void> showMeshFileSectionSheet(BuildContext context, MeshFileController c) {
  return datumSheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sheetTitle(tr('Sección'), sub: tr('Corta el modelo con un plano para ver el interior')),
          Wrap(
            spacing: 6,
            children: [
              for (final (i, n) in const ['X', 'Y', 'Z'].indexed)
                ChoiceChip(
                  label: Text(tr('Plano {n}', {'n': n})),
                  selected: c.sectionAxis == i,
                  onSelected: (_) => c.setSection(i),
                ),
              ChoiceChip(
                label: Text(tr('Sin sección')),
                selected: c.sectionAxis < 0,
                onSelected: (_) => c.clearSection(),
              ),
            ],
          ),
          if (c.sectionAxis >= 0) ...[
            Slider(value: c.sectionT, onChanged: (v) => c.setSection(c.sectionAxis, t: v)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Tapar el corte')),
              subtitle: Text(
                tr('Solo para mallas cerradas (sólidos); en superficies abiertas deja manchas'),
                style: const TextStyle(color: DT.muted, fontSize: 12),
              ),
              value: c.options.capClip,
              onChanged: (_) => c.toggleCap(),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => c.setSection(c.sectionAxis, flip: !c.sectionFlip),
                child: Text(tr('Invertir lado')),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}


/// Sección de un proyecto 3MF (mismo plano y tapa que en las demás mallas).
Future<void> showTmfSectionSheet(BuildContext context, ThreeMfController c) {
  return datumSheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sheetTitle(tr('Sección'), sub: tr('Corta las piezas con un plano para ver el interior')),
          Wrap(
            spacing: 6,
            children: [
              for (final (i, n) in const ['X', 'Y', 'Z'].indexed)
                ChoiceChip(label: Text(tr('Plano {n}', {'n': n})), selected: c.sectionAxis == i, onSelected: (_) => c.setSection(i)),
              ChoiceChip(label: Text(tr('Sin sección')), selected: c.sectionAxis < 0, onSelected: (_) => c.clearSection()),
            ],
          ),
          if (c.sectionAxis >= 0) ...[
            Slider(value: c.sectionT, onChanged: (v) => c.setSection(c.sectionAxis, t: v)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Tapar el corte')),
              subtitle: Text(tr('Solo para mallas cerradas; en superficies abiertas deja manchas'), style: const TextStyle(color: DT.muted, fontSize: 12)),
              value: c.options.capClip,
              onChanged: (_) => c.toggleCap(),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => c.setSection(c.sectionAxis, flip: !c.sectionFlip), child: Text(tr('Invertir lado'))),
            ),
          ],
        ],
      ),
    ),
  );
}

/// Coloca la cámara en una vista guardada del archivo. La cámara orbital conserva el punto de mira:
/// se elige el punto de la dirección de la vista más cercano al centro de la escena.
void applyFileView(OrbitCamera cam, MeshFileController c, ViewInfo v) {
  final up = upMatrix(c.up);
  final eye = up.transform3(vm.Vector3(v.position[0], v.position[1], v.position[2]));
  final dir = (up.getRotation() * vm.Vector3(v.direction[0], v.direction[1], v.direction[2]))..normalize();
  final b = c.scene.bounds();
  final center = vm.Vector3(b.center[0], b.center[1], b.center[2]);
  var d = (center - eye).dot(dir);
  if (d < b.radius * 0.1) d = b.radius * 2;
  cam.sceneRadius = math.max(b.radius, 1e-6);
  cam.target = eye + dir * d;
  cam.distance = d;
  final back = -dir;
  cam.yaw = math.atan2(back.y, back.x);
  cam.pitch = math.asin(back.z.clamp(-1.0, 1.0)).clamp(-math.pi / 2 + 0.01, math.pi / 2 - 0.01).toDouble();
  cam.touch();
}

/// Lista de vistas del archivo (cámaras de glTF o `Viewpoint` de VRML).
Future<void> showMeshViewsSheet(BuildContext context, MeshFileController c, OrbitCamera cam) {
  return datumSheet(
    context,
    ListView(
      shrinkWrap: true,
      children: [
        sheetTitle(tr('Vistas del archivo'), sub: c.info.views.length == 1 ? tr('{n} vista guardada por quien lo creó', {'n': 1}) : tr('{n} vistas guardadas por quien lo creó', {'n': c.info.views.length})),
        for (final v in c.info.views)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.videocam_outlined),
            title: Text(v.name),
            onTap: () {
              applyFileView(cam, c, v);
              Navigator.of(context).pop();
            },
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.center_focus_strong_outlined),
          title: Text(tr('Encuadrar todo')),
          onTap: () {
            cam.fit(c.scene.bounds());
            Navigator.of(context).pop();
          },
        ),
      ],
    ),
  );
}


/// Variantes de material del archivo (colores de un zapato, tapicerías…).
Future<void> showMeshVariantsSheet(BuildContext context, MeshFileController c) {
  return datumSheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) => ListView(
        shrinkWrap: true,
        children: [
          sheetTitle(tr('Variantes de material'), sub: tr('El archivo trae {n} formas de vestir el mismo modelo', {'n': c.info.variants.length})),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (i, n) in c.info.variants.indexed)
                ChoiceChip(label: Text(n), selected: c.variant == i, onSelected: (_) => c.selectVariant(i)),
            ],
          ),
        ],
      ),
    ),
  );
}
