import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../io/zip_lite.dart';
import '../l10n/l10n.dart';
import '../model/mesh.dart';
import '../model/scene.dart';
import '../model/threemf.dart';
import '../render/gpu_mesh.dart';
import '../render/lod.dart';
import 'glass.dart';
import 'stl_tools.dart' show datumSheet, fmtNum, sheetLabel, sheetRow, sheetTitle;
import 'theme.dart';
import '../model/unit_system.dart';

/// Etiquetas de nodo escritas por el lector (`threemf_loader.dart`).
const _kPlate = 1, _kObject = 2, _kPart = 3;

class _PartRef {
  _PartRef(this.node, this.obj, this.role, this.slot);
  final SceneNode node;
  final int obj;
  final TmfRole role;
  final int slot;
}

/// Estado de un proyecto 3MF abierto: qué placa se ve, qué piezas y filamentos están ocultos.
class ThreeMfController extends ChangeNotifier {
  ThreeMfController(this.scene, this.project, this.path) {
    options.edges = false;
    _index(scene.root);
    plate = project.plates.length > 1 ? -1 : (project.plates.isEmpty ? -1 : 0);
    apply(notify: false);
    _buildLod();
  }

  final Scene scene;
  final ThreeMfProject project;
  final String path;
  final RenderOptions options = RenderOptions();

  /// -1 = todas las placas a la vez.
  int plate = -1;
  bool showAux = false;
  bool showBed = true;
  bool measuring = false;
  final points = <vm.Vector3>[];
  final hiddenSlots = <int>{};
  final hiddenObjects = <int>{};
  int? isolated;

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

  void clearSection() {
    sectionAxis = -1;
    _applySection();
    notifyListeners();
  }

  void toggleCap() {
    options.capClip = !options.capClip;
    notifyListeners();
  }

  void _applySection() {
    if (sectionAxis < 0) {
      options.clip = null;
      return;
    }
    final b = viewBounds();
    final pos = b.min[sectionAxis] + (b.max[sectionAxis] - b.min[sectionAxis]) * sectionT;
    final n = [0.0, 0.0, 0.0]..[sectionAxis] = sectionFlip ? -1 : 1;
    options.clip = vm.Vector4(n[0], n[1], n[2], sectionFlip ? -pos : pos);
  }

  final _plateNode = <int, SceneNode>{};
  final _objectNode = <int, SceneNode>{};
  final _parts = <_PartRef>[];
  final _bytes = <String, Uint8List?>{};

  void _index(SceneNode n) {
    final t = n.tag;
    if (t != null && t.isNotEmpty) {
      if (t[0] == _kPlate) _plateNode[t[1]] = n;
      if (t[0] == _kObject) _objectNode[t[1]] = n;
      if (t[0] == _kPart) {
        _parts.add(_PartRef(n, t[1], TmfRole.values[t[2]], t[3]));
      }
    }
    for (final c in n.children) {
      _index(c);
    }
  }

  /// Versión simplificada de la escena (≈120 mil triángulos) para girar proyectos enormes.
  Scene? get lodScene => _lod?.scene;
  LodScene? _lod;

  Future<void> _buildLod() async {
    _lod = await buildLodScene(scene);
    if (_lod != null) notifyListeners();
  }

  bool get multiPlate => project.plates.length > 1;
  bool get hasAux => _parts.any((p) => p.role != TmfRole.normal);

  /// Bytes de un archivo del ZIP (miniaturas, fotos), con caché.
  Uint8List? entry(String? name) {
    if (name == null) return null;
    return _bytes.putIfAbsent(name, () {
      try {
        final z = ZipLite.open(path);
        try {
          return z.has(name) ? z.read(name) : null;
        } finally {
          z.close();
        }
      } catch (_) {
        return null;
      }
    });
  }

  String? plateThumb(int i) {
    final p = project.plates[i];
    final base = p.thumbnail;
    if (base == null) return null;
    final small = base.replaceFirst(RegExp(r'\.png$'), '_small.png');
    final z = entry(small);
    return z != null ? small : base;
  }

  // ---- visibilidad

  bool objectVisible(int o) =>
      !hiddenObjects.contains(o) && (isolated == null || isolated == o);

  void apply({bool notify = true}) {
    final hasPlates = project.plates.isNotEmpty;
    for (final e in _plateNode.entries) {
      e.value.visible = plate < 0 || e.key == plate;
    }
    for (final o in project.objects) {
      final n = _objectNode[o.index];
      if (n == null) continue;
      var vis = objectVisible(o.index);
      if (hasPlates && plate >= 0 && o.plate != plate) vis = false;
      n.visible = vis;
    }
    for (final p in _parts) {
      p.node.visible =
          (p.role == TmfRole.normal || showAux) &&
          !(p.slot > 0 && hiddenSlots.contains(p.slot));
    }
    _bedLines();
    _lod?.sync();
    if (notify) notifyListeners();
  }

  void selectPlate(int i) {
    plate = i;
    isolated = null;
    apply();
  }

  void toggleObject(int o) {
    hiddenObjects.contains(o) ? hiddenObjects.remove(o) : hiddenObjects.add(o);
    apply();
  }

  void isolate(int? o) {
    isolated = isolated == o ? null : o;
    apply();
  }

  void toggleSlot(int s) {
    hiddenSlots.contains(s) ? hiddenSlots.remove(s) : hiddenSlots.add(s);
    apply();
  }

  void toggleAux() {
    showAux = !showAux;
    apply();
  }

  void toggleMeasure() {
    measuring = !measuring;
    points.clear();
    apply();
  }

  void addPoint(vm.Vector3 p) {
    if (points.length >= 2) points.clear();
    points.add(p);
    apply();
  }

  /// Distancia y diferencias por eje entre los dos puntos tocados (en mm).
  String? get measureText {
    if (points.length < 2) return null;
    final d = points[1] - points[0];
    String f(double v) => Units.len(v);
    return tr('Distancia {d}  ·  ΔX {x}  ·  ΔY {y}  ·  ΔZ {z}', {'d': f(d.length), 'x': f(d.x.abs()), 'y': f(d.y.abs()), 'z': f(d.z.abs())});
  }

  void toggleBed() {
    showBed = !showBed;
    apply();
  }

  // ---- geometría de placas

  bool get bedKnown => project.bedX > 0 && project.bedY > 0;

  /// Caja de lo que hay en una placa (o de todo si [i] < 0). Piezas normales.
  Bounds contentBounds(int i) {
    final mn = [double.infinity, double.infinity, double.infinity];
    final mx = [-double.infinity, -double.infinity, -double.infinity];
    for (final o in project.objects) {
      if (i >= 0 && o.plate != i) continue;
      if (!o.min[0].isFinite) continue;
      for (var k = 0; k < 3; k++) {
        mn[k] = math.min(mn[k], o.min[k]);
        mx[k] = math.max(mx[k], o.max[k]);
      }
    }
    if (!mn[0].isFinite) return Bounds([0, 0, 0], [1, 1, 1]);
    return Bounds(mn, mx);
  }

  /// Caja para encuadrar la vista: la cama de la placa si se conoce; si no, el contenido.
  Bounds viewBounds() {
    if (plate >= 0 && bedKnown) {
      final p = project.plates[plate];
      final c = contentBounds(plate);
      return Bounds(
        [
          math.min(p.originX, c.min[0]),
          math.min(p.originY, c.min[1]),
          0,
        ],
        [
          math.max(p.originX + project.bedX, c.max[0]),
          math.max(p.originY + project.bedY, c.max[1]),
          math.max(c.max[2], 1),
        ],
      );
    }
    return contentBounds(plate);
  }

  /// ¿Cabe la placa en la cama? Devuelve los mm que sobran por el peor lado (0 = cabe).
  double overflow(int i) {
    if (!bedKnown || project.plates.isEmpty) return 0;
    final p = project.plates[i];
    var worst = 0.0;
    for (final o in project.objects) {
      if (o.plate != i || !o.printable) continue;
      worst = math.max(worst, p.originX - o.min[0]);
      worst = math.max(worst, o.max[0] - (p.originX + project.bedX));
      worst = math.max(worst, p.originY - o.min[1]);
      worst = math.max(worst, o.max[1] - (p.originY + project.bedY));
      if (project.bedZ > 0) worst = math.max(worst, o.max[2] - project.bedZ);
    }
    return worst < 0.5 ? 0 : worst;
  }

  void _bedLines() {
    final list = <LineBuf>[];
    if (points.isNotEmpty) {
      const r = 3.0;
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
      list.add(LineBuf(v, DT.mint));
    }
    if (!showBed || !bedKnown || project.plates.isEmpty) {
      options.pmiLines = list;
      return;
    }
    for (final p in project.plates) {
      if (plate >= 0 && p.index != plate) continue;
      final over = overflow(p.index) > 0 || p.outside;
      final x0 = p.originX, y0 = p.originY;
      final x1 = x0 + project.bedX, y1 = y0 + project.bedY;
      final s = <double>[];
      void seg(double ax, double ay, double az, double bx, double by, double bz) =>
          s.addAll([ax, ay, az, bx, by, bz]);
      seg(x0, y0, 0, x1, y0, 0);
      seg(x1, y0, 0, x1, y1, 0);
      seg(x1, y1, 0, x0, y1, 0);
      seg(x0, y1, 0, x0, y0, 0);
      if (plate >= 0 && project.bedZ > 0) {
        final h = project.bedZ;
        seg(x0, y0, h, x1, y0, h);
        seg(x1, y0, h, x1, y1, h);
        seg(x1, y1, h, x0, y1, h);
        seg(x0, y1, h, x0, y0, h);
        seg(x0, y0, 0, x0, y0, h);
        seg(x1, y0, 0, x1, y0, h);
        seg(x1, y1, 0, x1, y1, h);
        seg(x0, y1, 0, x0, y1, h);
      }
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
      list.add(LineBuf(v, over ? DT.orange : const Color(0xFF3F7F78)));
    }
    options.pmiLines = list;
  }

  /// Texto de lo que se ha tocado: pieza, volumen, filamento y medidas.
  String? describe(SceneNode n) {
    final t = n.tag;
    if (t == null || t.length < 2 || t[0] == _kPlate) return null;
    final o = project.objects.where((x) => x.index == t[1]).firstOrNull;
    if (o == null) return null;
    final size = [for (var k = 0; k < 3; k++) o.max[k] - o.min[k]];
    final b = StringBuffer(o.name);
    if (t[0] == _kPart && (o.parts.length > 1 || n.name != o.name)) {
      b.write(' › ${n.name}');
      final role = TmfRole.values[t[2]];
      if (role != TmfRole.normal) b.write(' (${tr(_roleName[role]!).toLowerCase()})');
      final slot = t[3];
      if (slot > 0 && slot <= project.filaments.length) {
        final f = project.filaments[slot - 1];
        b.write(' · ${tr('filamento {n}', {'n': slot})}${f.type.isNotEmpty ? ' ${f.type}' : ''}');
      }
    }
    b.write(' · ${Units.dims(size)}');
    return b.toString();
  }

  // ---- cifras

  List<TmfObjectInfo> objectsOf(int i) => [
    for (final o in project.objects)
      if (i < 0 || o.plate == i || project.plates.isEmpty) o,
  ];

  /// Volumen por filamento de una placa (mm³).
  Map<int, double> volumeBySlot(int i) {
    final m = <int, double>{};
    for (final o in objectsOf(i)) {
      if (!o.printable) continue;
      for (final e in o.volumeBySlot.entries) {
        m[e.key] = (m[e.key] ?? 0) + e.value;
      }
    }
    return m;
  }

  /// Gramos de material macizo (cota máxima) de un filamento con el volumen dado.
  double solidGrams(int slot, double mm3) {
    final f = slot >= 1 && slot <= project.filaments.length
        ? project.filaments[slot - 1]
        : null;
    final d = (f != null && f.density > 0) ? f.density : 1.24;
    return mm3 / 1000 * d;
  }

  double totalSolidGrams(int i) {
    var g = 0.0;
    for (final e in volumeBySlot(i).entries) {
      g += solidGrams(e.key, e.value);
    }
    return g;
  }
}

// ----------------------------------------------------------------- textos

String tmfDuration(double seconds) {
  final m = (seconds / 60).round();
  if (m < 60) return '$m min';
  final h = m ~/ 60;
  final r = m % 60;
  if (h < 48) return r == 0 ? '$h h' : '$h h $r min';
  final d = h ~/ 24;
  return '$d d ${h % 24} h';
}

String _val(String k, String v) {
  String yn(String x) => (x == '1' || x == 'true') ? tr('Sí') : tr('No');
  switch (k) {
    case 'layer_height' || 'initial_layer_print_height' || 'first_layer_height':
      final x = double.tryParse(v);
      return Units.isImperial && x != null ? Units.fine(x) : '${v.ldec} mm';
    case 'enable_support' || 'support_material' || 'enable_prime_tower' || 'gap_fill_enabled':
      return yn(v);
    case 'brim_type':
      return switch (v) {
        'auto_brim' => tr('Automático'),
        'no_brim' => tr('Sin borde'),
        'outer_only' => tr('Solo exterior'),
        'inner_only' => tr('Solo interior'),
        'outer_and_inner' => tr('Exterior e interior'),
        'painted' => tr('Pintado'),
        _ => v,
      };
    case 'support_type':
      return switch (v) {
        'normal(auto)' => tr('Normal (auto)'),
        'tree(auto)' => tr('Árbol (auto)'),
        'normal(manual)' => tr('Normal (manual)'),
        'tree(manual)' => tr('Árbol (manual)'),
        _ => v,
      };
    case 'print_sequence':
      return v == 'by object' ? tr('Pieza a pieza') : tr('Capa a capa');
    case 'brim_width':
      final x = double.tryParse(v);
      return v == '0' ? tr('Sin borde') : (Units.isImperial && x != null ? Units.mm(x) : '$v mm');
    case 'raft_layers':
      return v == '0' ? tr('Sin balsa') : tr('{n} capas', {'n': v});
    default:
      return v;
  }
}

const _labels = {
  'layer_height': 'Altura de capa',
  'initial_layer_print_height': 'Primera capa',
  'wall_loops': 'Perímetros',
  'top_shell_layers': 'Capas superiores',
  'bottom_shell_layers': 'Capas inferiores',
  'sparse_infill_density': 'Relleno',
  'sparse_infill_pattern': 'Patrón de relleno',
  'enable_support': 'Soportes',
  'support_type': 'Tipo de soporte',
  'support_style': 'Estilo de soporte',
  'brim_type': 'Borde de adherencia',
  'brim_width': 'Ancho del borde',
  'raft_layers': 'Balsa',
  'curr_bed_type': 'Placa de cama',
  'print_sequence': 'Orden de impresión',
  'enable_prime_tower': 'Torre de purga',
  'perimeters': 'Perímetros',
  'fill_density': 'Relleno',
  'fill_pattern': 'Patrón de relleno',
  'support_material': 'Soportes',
  'top_solid_layers': 'Capas superiores',
  'bottom_solid_layers': 'Capas inferiores',
  'infill_wall_overlap': 'Solape relleno-pared',
  'skeleton_infill_density': 'Relleno de esqueleto',
  'skin_infill_density': 'Relleno de piel',
  'gap_fill_enabled': 'Relleno de huecos',
  'seam_position': 'Posición de la costura',
  'outer_wall_speed': 'Velocidad pared exterior',
  'ironing_type': 'Planchado',
};

String _label(String k) {
  final l = _labels[k];
  return l == null ? k : tr(l);
}

const _roleName = {
  TmfRole.normal: 'Pieza',
  TmfRole.modifier: 'Modificador',
  TmfRole.negative: 'Volumen negativo (vacía)',
  TmfRole.blocker: 'Bloqueador de soportes',
  TmfRole.enforcer: 'Forzador de soportes',
  TmfRole.other: 'No se imprime',
};

// ----------------------------------------------------------------- cabecera

List<Widget> tmfChips(ThreeMfController c) {
  final p = c.project;
  final out = <Widget>[];
  final objs = c.objectsOf(c.plate);
  if (c.multiPlate) {
    out.add(
      InfoChip(
        Icons.grid_view_rounded,
        c.plate < 0
            ? tr('{n} placas', {'n': p.plates.length})
            : tr('Placa {n} de {m}', {'n': p.plates[c.plate].number, 'm': p.plates.length}),
      ),
    );
  }
  out.add(
    InfoChip(
      Icons.view_in_ar_outlined,
      objs.length == 1 ? tr('1 pieza') : tr('{n} piezas', {'n': objs.length}),
    ),
  );
  final b = c.contentBounds(c.plate);
  out.add(
    InfoChip(
      Icons.straighten,
      Units.dims([
        b.max[0] - b.min[0],
        b.max[1] - b.min[1],
        b.max[2] - b.min[2],
      ]),
    ),
  );
  if (c.plate >= 0 && c.overflow(c.plate) > 0) {
    out.add(
      InfoChip(
        Icons.warning_amber_rounded,
        Units.tru('Se sale de la cama {n} mm', {'n': Units.number(c.overflow(c.plate), d: 0)}),
        color: DT.orangeSoft,
      ),
    );
  } else if (c.plate >= 0 && c.bedKnown && p.printer.isNotEmpty) {
    out.add(InfoChip(Icons.check_circle_outline_rounded, tr('Cabe en la cama'), color: DT.mint));
  }
  if (c.plate >= 0 && c.plate < p.plates.length && p.plates[c.plate].sliced) {
    final pl = p.plates[c.plate];
    out.add(
      InfoChip(Icons.timer_outlined, '${tmfDuration(pl.seconds)} · ${Units.mass(pl.grams)}', color: DT.mint),
    );
  } else if (p.filaments.isNotEmpty) {
    final g = c.totalSolidGrams(c.plate);
    if (g > 0) out.add(InfoChip(Icons.scale_outlined, tr('hasta {m}', {'m': Units.mass(g)})));
  }
  final used = c.volumeBySlot(c.plate).keys.where((k) => k > 0).length;
  if (used > 1) out.add(InfoChip(Icons.palette_outlined, tr('{n} filamentos', {'n': used})));
  return out;
}

// ----------------------------------------------------------------- tira de placas

class TmfPlateStrip extends StatelessWidget {
  const TmfPlateStrip(this.c, {super.key, this.onSelected});
  final ThreeMfController c;
  final void Function(int plate)? onSelected;

  @override
  Widget build(BuildContext context) {
    final p = c.project;
    Widget card(int i, String label, String sub, Uint8List? img, bool warn) {
      final sel = c.plate == i;
      return GestureDetector(
        onTap: () {
          c.selectPlate(i);
          onSelected?.call(i);
        },
        child: Container(
          width: 92,
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: sel ? const Color(0x33FB923C) : const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: sel ? DT.orange : DT.border, width: sel ? 1.5 : 1),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: img != null
                      ? Image.memory(img, fit: BoxFit.cover, gaplessPlayback: true)
                      : Container(
                          color: const Color(0x14FFFFFF),
                          child: const Icon(Icons.grid_view_rounded, color: DT.muted),
                        ),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (warn)
                    const Padding(
                      padding: EdgeInsets.only(right: 3),
                      child: Icon(Icons.warning_amber_rounded, size: 12, color: DT.orangeSoft),
                    ),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: DT.muted)),
            ],
          ),
        ),
      );
    }

    final cards = <Widget>[
      card(-1, tr('Todas'), tr('{n} placas', {'n': p.plates.length}), null, false),
      for (final pl in p.plates)
        card(
          pl.index,
          pl.name.isEmpty ? tr('Placa {n}', {'n': pl.number}) : pl.name,
          pl.sliced
              ? tmfDuration(pl.seconds)
              : (c.objectsOf(pl.index).length == 1 ? tr('1 pieza') : tr('{n} piezas', {'n': c.objectsOf(pl.index).length})),
          c.entry(c.plateThumb(pl.index)),
          c.overflow(pl.index) > 0 || pl.outside,
        ),
    ];
    return SizedBox(
      height: 134,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: cards),
    );
  }
}

// ----------------------------------------------------------------- hojas

Widget _swatch(int argb, {double size = 16}) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(
    color: Color(argb),
    shape: BoxShape.circle,
    border: Border.all(color: const Color(0x55FFFFFF)),
  ),
);

Future<void> showTmfFilamentsSheet(
  BuildContext context,
  ThreeMfController c, {
  void Function(int plate)? onToolpath,
}) {
  return datumSheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) {
        final p = c.project;
        final plate = c.plate >= 0 && c.plate < p.plates.length ? p.plates[c.plate] : null;
        final vols = c.volumeBySlot(c.plate);
        final slots = <int>{...vols.keys.where((k) => k > 0)};
        final kids = <Widget>[
          sheetTitle(
            tr('Filamentos'),
            sub: c.plate < 0 ? tr('Todas las placas') : tr('Placa {n}', {'n': c.project.plates[c.plate].number}),
          ),
        ];
        if (plate != null && plate.sliced) {
          kids.add(sheetLabel(tr('LAMINADO')));
          kids.add(sheetRow(tr('Tiempo estimado'), tmfDuration(plate.seconds)));
          kids.add(sheetRow(tr('Material total'), Units.mass(plate.grams)));
          if (plate.colorChanges > 0) {
            kids.add(sheetRow(tr('Capas con más de un color'), '${plate.colorChanges}'));
          }
          kids.add(sheetRow(tr('Soportes'), plate.supportUsed ? tr('Sí') : tr('No')));
          if (plate.outside) {
            kids.add(sheetRow(tr('Aviso'), tr('Hay piezas fuera de la cama'), color: DT.orangeSoft));
          }
          if (plate.gcodeEntry != null && onToolpath != null) {
            kids.add(
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    onToolpath(plate.number);
                  },
                  icon: const Icon(Icons.route_rounded),
                  label: Text(tr('Ver el recorrido (G-code)')),
                ),
              ),
            );
          }
        }
        kids.add(sheetLabel(tr('FILAMENTOS DEL PROYECTO')));
        if (p.filaments.isEmpty) {
          kids.add(Text(tr('Este archivo no define filamentos.'), style: const TextStyle(color: DT.muted)));
        }
        for (final f in p.filaments) {
          final used = slots.contains(f.slot);
          final hidden = c.hiddenSlots.contains(f.slot);
          TmfUse? real;
          if (plate != null) {
            for (final u in plate.uses) {
              if (u.slot == f.slot) real = u;
            }
          }
          final vol = vols[f.slot] ?? 0;
          final String detail;
          if (real != null) {
            detail = tr('{g} · {m} m (laminado)', {'g': Units.mass(real.grams), 'm': fmtNum(real.meters, d: 1)});
          } else if (vol > 0) {
            detail = tr('hasta {m} macizo · {v}', {'m': Units.mass(c.solidGrams(f.slot, vol)), 'v': Units.volume(vol)});
          } else {
            detail = used ? '' : tr('sin usar en esta vista');
          }
          kids.add(
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: used ? () => c.toggleSlot(f.slot) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Opacity(
                  opacity: used ? (hidden ? 0.45 : 1) : 0.4,
                  child: Row(
                    children: [
                      _swatch(f.color, size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${tr('Filamento {n}', {'n': f.slot})}${f.type.isNotEmpty ? ' · ${f.type}' : ''}',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            if (f.profile.isNotEmpty || f.nozzleTemp > 0)
                              Text(
                                [
                                  if (f.profile.isNotEmpty) f.profile,
                                  if (f.nozzleTemp > 0) '${f.nozzleTemp} °C',
                                ].join(' · '),
                                style: const TextStyle(color: DT.muted, fontSize: 12),
                              ),
                            if (detail.isNotEmpty)
                              Text(detail, style: const TextStyle(color: DT.muted, fontSize: 12)),
                          ],
                        ),
                      ),
                      if (used)
                        Icon(hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20, color: DT.muted),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        if (plate == null || !plate.sliced) {
          kids.add(
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                tr('Sin laminar: el peso es el del material macizo (volumen × densidad del filamento), una cota máxima. El real depende del relleno, las paredes y los soportes.'),
                style: const TextStyle(color: DT.muted, fontSize: 12),
              ),
            ),
          );
        }
        return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids));
      },
    ),
  );
}

Future<void> showTmfPartsSheet(
  BuildContext context,
  ThreeMfController c, {
  required void Function(Bounds) onFocus,
}) {
  return datumSheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) {
        final p = c.project;
        final kids = <Widget>[
          sheetTitle(
            tr('Piezas'),
            sub: c.plate < 0 ? tr('Todo el proyecto') : tr('Placa {n}', {'n': c.project.plates[c.plate].number}),
          ),
        ];
        final objs = c.objectsOf(c.plate);
        for (final o in objs) {
          final hidden = !c.objectVisible(o.index);
          final size = [for (var k = 0; k < 3; k++) o.max[k] - o.min[k]];
          final slots = o.volumeBySlot.keys.where((k) => k > 0).toList()..sort();
          kids.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Opacity(
                opacity: hidden ? 0.45 : 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () {
                              onFocus(Bounds(o.min, o.max));
                              Navigator.of(ctx).pop();
                            },
                            child: Text(
                              o.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: tr('Ver solo esta pieza'),
                          onPressed: () => c.isolate(o.index),
                          icon: Icon(
                            Icons.filter_center_focus_rounded,
                            size: 20,
                            color: c.isolated == o.index ? DT.orange : DT.muted,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: hidden ? tr('Mostrar') : tr('Ocultar'),
                          onPressed: () => c.toggleObject(o.index),
                          icon: Icon(
                            hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                            size: 20,
                            color: DT.muted,
                          ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 10,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final s in slots)
                          if (s <= p.filaments.length) _swatch(p.filaments[s - 1].color, size: 13),
                        Text(
                          '${tr('{d} · {k} triáng.', {'d': Units.dims(size), 'k': _k(o.triangles)})}'
                          '${o.plate >= 0 && c.multiPlate ? ' · ${tr('placa {n}', {'n': p.plates[o.plate].number})}' : ''}'
                          '${o.printable ? '' : ' · ${tr('no se imprime')}'}',
                          style: const TextStyle(color: DT.muted, fontSize: 12),
                        ),
                      ],
                    ),
                    if (o.overrides.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          tr('Ajustes propios: {a}', {'a': o.overrides.entries.map((e) => '${_label(e.key).toLowerCase()} ${_val(e.key, e.value)}').join(' · ')}),
                          style: const TextStyle(color: DT.orangeSoft, fontSize: 12),
                        ),
                      ),
                    if (o.parts.length > 1 || o.parts.any((x) => x.role != TmfRole.normal))
                      for (final x in o.parts)
                        Padding(
                          padding: const EdgeInsets.only(left: 10, top: 2),
                          child: Text(
                            '${x.role == TmfRole.normal ? '·' : '◇'} ${x.name}'
                            '${x.role == TmfRole.normal ? '' : ' — ${tr(_roleName[x.role]!)}'}'
                            '${x.extruder > 0 && x.role == TmfRole.normal ? ' · ${tr('filamento {n}', {'n': x.extruder})}' : ''}',
                            style: TextStyle(
                              color: x.role == TmfRole.normal ? DT.muted : DT.orangeSoft,
                              fontSize: 12,
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          );
        }
        if (c.hasAux) {
          kids.add(const Divider(height: 22, color: DT.border));
          kids.add(
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Mostrar volúmenes auxiliares')),
              subtitle: Text(
                tr('Modificadores, negativos y bloqueadores de soportes'),
                style: const TextStyle(color: DT.muted, fontSize: 12),
              ),
              value: c.showAux,
              onChanged: (_) => c.toggleAux(),
            ),
          );
        }
        return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids));
      },
    ),
  );
}

String _k(int n) => n >= 1000 ? '${fmtNum(n / 1000, d: 1)} k' : '$n';

Future<void> showTmfProjectSheet(BuildContext context, ThreeMfController c) {
  final p = c.project;
  final kids = <Widget>[
    sheetTitle(p.title.isNotEmpty ? p.title : tr('Proyecto 3MF'), sub: p.application.isNotEmpty ? p.application : null),
  ];
  final cover = p.pictures.isNotEmpty ? c.entry(p.pictures.first) : null;
  if (cover != null) {
    kids.add(
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(height: 150, width: double.infinity, child: Image.memory(cover, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox())),
        ),
      ),
    );
  }
  void row(String k, String v) {
    if (v.trim().isNotEmpty) kids.add(sheetRow(k, v));
  }

  row(tr('Diseñador'), p.designer);
  row(tr('Licencia'), p.license);
  row(tr('Derechos'), p.copyright);
  row(tr('Creado'), p.created);
  row(tr('Modificado'), p.modified);
  if (p.description.isNotEmpty && !p.description.contains('<')) row(tr('Descripción'), p.description);
  row(tr('Unidad del archivo'), _unitName(p.unit));

  if (p.printer.isNotEmpty || p.settings.isNotEmpty) {
    kids.add(sheetLabel(tr('IMPRESIÓN')));
    row(tr('Impresora'), p.printer);
    if (p.nozzle > 0) row(tr('Boquilla'), Units.fine(p.nozzle));
    if (c.bedKnown) {
      row(tr('Cama'), '${Units.number(p.bedX, d: 0)} × ${Units.number(p.bedY, d: 0)}${p.bedZ > 0 ? ' × ${Units.number(p.bedZ, d: 0)}' : ''} ${Units.symbol}');
    }
    row(tr('Perfil'), p.processName);
    for (final e in p.settings.entries) {
      var v = _val(e.key, e.value);
      if (e.key == 'sparse_infill_pattern' || e.key == 'fill_pattern') v = e.value;
      row(_label(e.key), v);
    }
  }
  if (p.colorChangeZ.isNotEmpty) {
    kids.add(sheetLabel(tr('CAMBIOS DE COLOR POR ALTURA')));
    kids.add(Text(p.colorChangeZ.map((z) => Units.fine(z)).join(' · '), style: const TextStyle(color: DT.muted)));
  }
  if (p.extensions.isNotEmpty) {
    kids.add(sheetLabel(tr('EXTENSIONES DEL FORMATO')));
    kids.add(Text(p.extensions.map(_extName).join(' · '), style: const TextStyle(color: DT.muted)));
  }
  if (p.notes.isNotEmpty) {
    kids.add(sheetLabel(tr('AVISOS')));
    for (final n in p.notes) {
      kids.add(Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(n, style: const TextStyle(color: DT.orangeSoft, fontSize: 13))));
    }
  }
  return datumSheet(context, SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: kids)));
}

String _unitName(String u) => switch (u) {
  'micron' => tr('micras'),
  'millimeter' => tr('milímetros'),
  'centimeter' => tr('centímetros'),
  'meter' => tr('metros'),
  'inch' => tr('pulgadas'),
  'foot' => tr('pies'),
  _ => u,
};

String _extName(String e) => switch (e) {
  'p' => tr('producción'),
  'm' => tr('materiales'),
  'beamlattice' => tr('retícula de vigas'),
  's' => tr('cortes'),
  _ => e,
};

/// Leyenda breve de filamentos para la esquina del visor.
class TmfLegend extends StatelessWidget {
  const TmfLegend(this.c, {super.key});
  final ThreeMfController c;
  @override
  Widget build(BuildContext context) {
    final used = c.volumeBySlot(c.plate).keys.where((k) => k > 0 && k <= c.project.filaments.length).toList()..sort();
    if (used.length < 2) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      children: [for (final s in used) _swatch(c.project.filaments[s - 1].color, size: 14)],
    );
  }
}

/// Tipografía tabular para cifras en tarjetas.
const kTabular = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
