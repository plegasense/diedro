// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/threemf.dart';
import 'mesh_data.dart';
import 'threemf_model.dart';
import 'zip_lite.dart';
import '../l10n/l10n.dart';

/// Tipos de nodo (primer número de `NodeData.tag`).
const int kTagPlate = 1; // [1, placa]
const int kTagObject = 2; // [2, pieza]
const int kTagPart = 3; // [3, pieza, rol, filamento, volumen]

const _unitMm = {
  'micron': 0.001,
  'millimeter': 1.0,
  'centimeter': 10.0,
  'inch': 25.4,
  'foot': 304.8,
  'meter': 1000.0,
};

/// Lee un 3MF: el estándar (núcleo y extensiones de materiales y producción) y los
/// proyectos de Bambu Studio, OrcaSlicer y PrusaSlicer con sus placas, filamentos y pintura.
SceneData parse3mf(String path) {
  final zip = ZipLite.open(path);
  try {
    return _Loader(zip, path).run();
  } finally {
    zip.close();
  }
}

/// Un trozo de malla ya situado en una pieza: objeto del `.model`, rango de triángulos,
/// rol y extrusor.
class _Unit {
  _Unit(this.raw, this.file, this.first, this.last, this.matrix, this.name);
  final RawObject raw;
  final String file;
  final int first, last; // triángulos [first, last)
  final List<double> matrix; // respecto a la pieza
  String name;
  TmfRole role = TmfRole.normal;
  int extruder = 0;
  String key(int ext) => '$file|${raw.id}|$first|$last|$ext';
}

class _Group {
  Float32List a = Float32List(1800);
  int n = 0; // triángulos
  double vol = 0;
  final mn = [double.infinity, double.infinity, double.infinity];
  final mx = [-double.infinity, -double.infinity, -double.infinity];

  void tri(
    double ax,
    double ay,
    double az,
    double bx,
    double by,
    double bz,
    double cx,
    double cy,
    double cz,
  ) {
    if ((n + 1) * 18 > a.length) {
      final b = Float32List(a.length * 2);
      b.setRange(0, n * 18, a);
      a = b;
    }
    final ux = bx - ax, uy = by - ay, uz = bz - az;
    final vx = cx - ax, vy = cy - ay, vz = cz - az;
    var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    final len = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 0) {
      nx /= len;
      ny /= len;
      nz /= len;
    }
    final o = n * 18;
    a[o] = ax;
    a[o + 1] = ay;
    a[o + 2] = az;
    a[o + 3] = nx;
    a[o + 4] = ny;
    a[o + 5] = nz;
    a[o + 6] = bx;
    a[o + 7] = by;
    a[o + 8] = bz;
    a[o + 9] = nx;
    a[o + 10] = ny;
    a[o + 11] = nz;
    a[o + 12] = cx;
    a[o + 13] = cy;
    a[o + 14] = cz;
    a[o + 15] = nx;
    a[o + 16] = ny;
    a[o + 17] = nz;
    n++;
    vol += (ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx)) / 6;
    void b3(double x, double y, double z) {
      if (x < mn[0]) mn[0] = x;
      if (y < mn[1]) mn[1] = y;
      if (z < mn[2]) mn[2] = z;
      if (x > mx[0]) mx[0] = x;
      if (y > mx[1]) mx[1] = y;
      if (z > mx[2]) mx[2] = z;
    }

    b3(ax, ay, az);
    b3(bx, by, bz);
    b3(cx, cy, cz);
  }

  Float32List take() => Float32List.sublistView(a, 0, n * 18);
}

class _Loader {
  _Loader(this.zip, this.path);
  final ZipLite zip;
  final String path;
  final project = ThreeMfProject();
  final models = <String, RawModel>{};
  late String mainName;
  late RawModel main;

  final meshes = <MeshData>[];
  final _meshTris = <int>[];
  final nodes = <NodeData>[];
  // Caché de piezas ya generadas: clave de la unidad → (grupo → índice de malla, volumen).
  final _cache = <String, Map<int, (int, double)>>{};
  final _cacheBounds = <String, (List<double>, List<double>)>{};

  String? _text(String name) => zip.text(name);

  String _norm(String p) => p.startsWith('/') ? p.substring(1) : p;

  RawModel _model(String name) {
    final n = _norm(name);
    var m = models[n];
    if (m != null) return m;
    var real = n;
    if (!zip.has(real)) {
      real = zip.entries.keys.firstWhere(
        (k) => k.toLowerCase() == n.toLowerCase(),
        orElse: () => '',
      );
    }
    if (real.isEmpty) throw FormatException(tr('Falta el modelo {n}', {'n': n}));
    final p = ModelParser();
    zip.stream(real, p.feed);
    p.finish();
    m = p.model;
    models[n] = m;
    return m;
  }

  String _findMain() {
    final rels = _text('_rels/.rels');
    if (rels != null) {
      for (final m in RegExp(r'<Relationship\b[^>]*>').allMatches(rels)) {
        final t = m.group(0)!;
        final type = RegExp(r'Type="([^"]*)"').firstMatch(t)?.group(1) ?? '';
        final target = RegExp(r'Target="([^"]*)"').firstMatch(t)?.group(1);
        if (target != null && type.toLowerCase().endsWith('/3dmodel')) {
          return _norm(target);
        }
      }
    }
    for (final k in zip.entries.keys) {
      if (k.toLowerCase() == '3d/3dmodel.model') return k;
    }
    for (final k in zip.entries.keys) {
      if (k.toLowerCase().endsWith('.model') && !k.toLowerCase().startsWith('2d/')) return k;
    }
    throw FormatException(tr('El 3MF no contiene ningún modelo'));
  }

  SceneData run() {
    mainName = _findMain();
    main = _model(mainName);
    final md = main.metadata;
    project
      ..application = md['Application'] ?? ''
      ..title = md['Title'] ?? md['ProfileTitle'] ?? ''
      ..designer = md['Designer'] ?? ''
      ..description = md['Description'] ?? ''
      ..license = md['License'] ?? md['LicenseTerms'] ?? ''
      ..copyright = md['CopyRight'] ?? md['Copyright'] ?? ''
      ..created = md['CreationDate'] ?? ''
      ..modified = md['ModificationDate'] ?? ''
      ..unit = main.unit
      ..unitToMm = _unitMm[main.unit] ?? 1.0;
    final app = project.application;
    project.generator = app.startsWith('BambuStudio')
        ? 'Bambu Studio'
        : app.startsWith('OrcaSlicer')
        ? 'OrcaSlicer'
        : app.startsWith('PrusaSlicer')
        ? 'PrusaSlicer'
        : app.startsWith('Slic3r')
        ? 'Slic3r'
        : app.startsWith('Cura')
        ? 'Cura'
        : app;
    if (main.requiredExtensions.isNotEmpty) {
      project.extensions.addAll(main.requiredExtensions.split(RegExp(r'\s+')));
    }

    final bambu = zip.has('Metadata/model_settings.config');
    final prusa = zip.has('Metadata/Slic3r_PE_model.config');
    final cfg = _Config(zip, project);
    if (bambu) {
      cfg.readBambu();
    } else if (prusa) {
      cfg.readPrusa();
    }
    for (final k in zip.entries.keys) {
      final l = k.toLowerCase();
      if (l.startsWith('auxiliaries/') && (l.endsWith('.webp') || l.endsWith('.png') || l.endsWith('.jpg'))) {
        if (!l.contains('.thumbnails')) project.pictures.add(k);
      }
      if (l.endsWith('.gcode')) project.hasGcode = true;
    }

    return _build(cfg, bambu, prusa);
  }

  // ---- geometría

  /// Reúne las mallas de un objeto del `.model` en unidades.
  void _collect(
    String file,
    String id,
    List<double> m,
    List<_Unit> out,
    String name,
    int depth,
  ) {
    if (depth > 24) return;
    final mod = _model(file);
    final o = mod.objects[id];
    if (o == null) return;
    final nm = o.name.isEmpty ? name : o.name;
    if (o.pos != null && ((o.tri?.isNotEmpty ?? false) || o.beams != null)) {
      out.add(_Unit(o, file, 0, (o.tri?.length ?? 0) ~/ 3, m, nm));
    }
    if (o.hasLattice) project.extensions.add('beamlattice');
    if (o.hasSlices) {
      project.notes.add(tr('Contiene cortes (extensión de capas): se muestra solo la malla.'));
    }
    for (final c in o.comps) {
      final f = c.path == null || c.path!.isEmpty ? file : _norm(c.path!);
      _collect(f, c.objectId, mul4(m, c.m), out, nm, depth + 1);
    }
  }

  SceneData _build(_Config cfg, bool bambu, bool prusa) {
    final scale = project.unitToMm;
    final unitScale = <double>[scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, scale, 0, 0, 0, 0, 1];

    // Placa de cada objeto de construcción (Bambu).
    final plateOf = <String, int>{};
    for (final p in project.plates) {
      for (final oid in cfg.plateObjects[p.index] ?? const <String>[]) {
        plateOf[oid] = p.index;
      }
    }

    // Piezas
    final objs = <TmfObjectInfo>[];
    final itemUnits = <int, List<_Unit>>{};
    final itemMatrix = <int, List<double>>{};
    var ni = 0;
    var items = main.items;
    if (items.isEmpty) {
      // Sin <build>: se muestran todos los objetos que no cuelgan de otro.
      final child = <String>{
        for (final o in main.objects.values)
          for (final c in o.comps) c.objectId,
      };
      items = [
        for (final o in main.objects.values)
          if (!child.contains(o.id)) RawItem(o.id, kIdentity4, true, null, null),
      ];
    }
    for (final it in items) {
      final file = it.path != null && it.path!.isNotEmpty ? _norm(it.path!) : mainName;
      final ro = _model(file).objects[it.objectId];
      if (ro == null) continue;
      final units = <_Unit>[];
      _collect(file, it.objectId, kIdentity4, units, tr('Pieza {n}', {'n': ni + 1}), 0);
      if (units.isEmpty) continue;
      final info = TmfObjectInfo(ni, '')..id = it.objectId;
      info
        ..printable = it.printable
        ..partNumber = it.partNumber;
      final c = cfg.objects[it.objectId];
      info.name = (c?.name.isNotEmpty ?? false)
          ? c!.name
          : (ro.name.isNotEmpty ? ro.name : (it.partNumber ?? tr('Pieza {n}', {'n': ni + 1})));
      info.extruder = c?.extruder ?? 1;
      if (c != null) info.overrides.addAll(c.overrides);
      info.plate = plateOf[it.objectId] ?? -1;
      if (ro.type == 'support' || ro.type == 'solidsupport' || ro.type == 'other') {
        for (final u in units) {
          u.role = TmfRole.other;
        }
      }
      // Rol y extrusor de cada volumen según la configuración del programa.
      if (c != null) {
        if (bambu) {
          // Los volúmenes de Bambu son los componentes: su id es el id del objeto del componente.
          for (final u in units) {
            final pc = c.parts[u.raw.id];
            if (pc != null) {
              u.role = pc.role;
              u.extruder = pc.extruder;
              if (pc.name.isNotEmpty) u.name = pc.name;
            }
          }
        }
      }
      // PrusaSlicer: una sola malla con volúmenes por rango de triángulos.
      if (prusa && c != null && c.volumes.isNotEmpty && units.length == 1) {
        final base = units.first;
        units.clear();
        for (final v in c.volumes) {
          final total = base.raw.tri!.length ~/ 3;
          final lo = v.first.clamp(0, total);
          final hi = (v.last + 1).clamp(lo, total);
          if (hi <= lo) continue;
          units.add(
            _Unit(base.raw, base.file, lo, hi, base.matrix, v.name.isEmpty ? base.name : v.name)
              ..role = v.role
              ..extruder = v.extruder,
          );
        }
      }
      itemUnits[ni] = units;
      itemMatrix[ni] = mul4(unitScale, it.m);
      objs.add(info);
      ni++;
    }
    if (objs.isEmpty) throw FormatException(tr('El 3MF no contiene geometría'));

    // Filamentos de la paleta: sin datos del programa, un solo «material» neutro.
    final hasSlots = project.filaments.isNotEmpty;
    int slotColor(int slot) {
      if (slot >= 1 && slot <= project.filaments.length) {
        return project.filaments[slot - 1].color;
      }
      return 0xFFB7CACD;
    }

    // ---- nodos
    final plateNode = <int, int>{};
    int addNode(String name, int parent, int part, List<double> m, int? color, List<int>? tag) {
      nodes.add(NodeData(name, parent, part, m, color, tag: tag));
      return nodes.length - 1;
    }

    final usesPlates = project.plates.isNotEmpty;
    for (final p in project.plates) {
      plateNode[p.index] = addNode(
        p.name.isEmpty ? tr('Placa {n}', {'n': p.number}) : p.name,
        -1,
        -1,
        kIdentity4,
        null,
        [kTagPlate, p.index],
      );
    }

    for (final o in objs) {
      final units = itemUnits[o.index]!;
      final im = itemMatrix[o.index]!;
      final parent = usesPlates && o.plate >= 0 ? (plateNode[o.plate] ?? -1) : -1;
      o.node = addNode(o.name, parent, -1, im, null, [kTagObject, o.index]);
      if (o.plate >= 0 && usesPlates) project.plates[o.plate].objects.add(o.index);
      final omn = [double.infinity, double.infinity, double.infinity];
      final omx = [-double.infinity, -double.infinity, -double.infinity];
      for (var ui = 0; ui < units.length; ui++) {
        final u = units[ui];
        final ext = u.extruder > 0 ? u.extruder : o.extruder;
        final key = u.key(ext);
        var groups = _cache[key];
        if (groups == null) {
          groups = {};
          final built = _emit(u, ext, hasSlots);
          final bmn = [double.infinity, double.infinity, double.infinity];
          final bmx = [-double.infinity, -double.infinity, -double.infinity];
          for (final e in built.entries) {
            final g = e.value;
            if (g.n == 0) continue;
            meshes.add(
              MeshData(
                u.name,
                g.take(),
                List.of(g.mn),
                List.of(g.mx),
                color: _groupColor(e.key, hasSlots, u.role, slotColor),
              ),
            );
            _meshTris.add(g.n);
            groups[e.key] = (meshes.length - 1, g.vol);
            for (var k = 0; k < 3; k++) {
              bmn[k] = math.min(bmn[k], g.mn[k]);
              bmx[k] = math.max(bmx[k], g.mx[k]);
            }
          }
          _cache[key] = groups;
          _cacheBounds[key] = (bmn, bmx);
        }
        final partInfo = TmfPartInfo(u.name, u.role, u.extruder, 0);
        var tris = 0;
        var vol = 0.0;
        final pm = u.matrix;
        final full = mul4(im, pm);
        final fdet = _det3(full).abs();
        for (final e in groups.entries) {
          final (mi, v) = e.value;
          tris += _meshTris[mi];
          final vmm = v.abs() * fdet;
          vol += vmm;
          if (u.role == TmfRole.normal) {
            final slot = hasSlots ? e.key : 0;
            o.volumeBySlot[slot] = (o.volumeBySlot[slot] ?? 0) + vmm;
          }
          addNode(
            u.name,
            o.node,
            mi,
            pm,
            meshes[mi].color,
            [kTagPart, o.index, u.role.index, hasSlots ? e.key : 0, ui],
          );
        }
        final bb = _cacheBounds[key]!;
        if (u.role == TmfRole.normal && bb.$1[0].isFinite) {
          _grow(omn, omx, bb.$1, bb.$2, full);
        }
        o.parts.add(
          TmfPartInfo(partInfo.name, partInfo.role, partInfo.extruder, tris)..volumeMm3 = vol,
        );
        if (u.role == TmfRole.normal) o.triangles += tris;
      }
      if (omn[0].isInfinite) {
        // Sin volúmenes normales: caja de todos los volúmenes.
        for (final u in units) {
          final bb = _cacheBounds[u.key(u.extruder > 0 ? u.extruder : o.extruder)];
          if (bb != null && bb.$1[0].isFinite) {
            _grow(omn, omx, bb.$1, bb.$2, mul4(im, u.matrix));
          }
        }
      }
      o.min = omn;
      o.max = omx;
    }

    cfg.finish(objs);
    project.objects.addAll(objs);

    // Origen de cada placa (Bambu: cuadrícula con separación del 20 % de la cama).
    _plateOrigins();
    for (final o in objs) {
      if (o.plate < 0 && project.plates.isNotEmpty) {
        // Pieza fuera de toda placa: se asigna la placa que contiene su centro.
        final cx = (o.min[0] + o.max[0]) / 2, cy = (o.min[1] + o.max[1]) / 2;
        for (final p in project.plates) {
          if (cx >= p.originX &&
              cx <= p.originX + project.bedX &&
              cy >= p.originY &&
              cy <= p.originY + project.bedY) {
            o.plate = p.index;
          }
        }
      }
    }

    if (main.hasComposite) {
      project.notes.add(tr('Materiales compuestos o multipropiedad: se muestra el color base.'));
    }
    if (main.textured.isNotEmpty) {
      project.notes.add(tr('Contiene texturas de imagen: no se aplican (se ve el color base).'));
    }
    final notes = project.notes.toSet().toList();
    project.notes
      ..clear()
      ..addAll(notes);

    return SceneData(
      path.split('/').last,
      meshes,
      const [],
      nodes: nodes,
      extra: project,
    );
  }

  void _plateOrigins() {
    final n = project.plates.length;
    if (n == 0) return;
    final bx = project.bedX > 0 ? project.bedX : 256.0;
    final by = project.bedY > 0 ? project.bedY : 256.0;
    final v = math.sqrt(n.toDouble());
    final r = v.roundToDouble();
    final cols = v > r ? r.toInt() + 1 : r.toInt();
    for (final p in project.plates) {
      final row = p.index ~/ cols, col = p.index % cols;
      p.originX = col * bx * 1.2;
      p.originY = -row * by * 1.2;
    }
  }

  static double _det3(List<double> m) =>
      m[0] * (m[5] * m[10] - m[6] * m[9]) -
      m[4] * (m[1] * m[10] - m[2] * m[9]) +
      m[8] * (m[1] * m[6] - m[2] * m[5]);

  static void _grow(List<double> mn, List<double> mx, List<double> bmn, List<double> bmx, List<double> m) {
    for (var i = 0; i < 8; i++) {
      final x = (i & 1) == 0 ? bmn[0] : bmx[0];
      final y = (i & 2) == 0 ? bmn[1] : bmx[1];
      final z = (i & 4) == 0 ? bmn[2] : bmx[2];
      final wx = m[0] * x + m[4] * y + m[8] * z + m[12];
      final wy = m[1] * x + m[5] * y + m[9] * z + m[13];
      final wz = m[2] * x + m[6] * y + m[10] * z + m[14];
      if (wx < mn[0]) mn[0] = wx;
      if (wy < mn[1]) mn[1] = wy;
      if (wz < mn[2]) mn[2] = wz;
      if (wx > mx[0]) mx[0] = wx;
      if (wy > mx[1]) mx[1] = wy;
      if (wz > mx[2]) mx[2] = wz;
    }
  }

  int? _groupColor(int key, bool hasSlots, TmfRole role, int Function(int) slotColor) {
    switch (role) {
      case TmfRole.negative:
        return 0xFFE5484D;
      case TmfRole.modifier:
        return 0xFF4C8DFF;
      case TmfRole.blocker:
        return 0xFFFB923C;
      case TmfRole.enforcer:
        return 0xFF34D399;
      case TmfRole.other:
        return 0xFF8A97A0;
      case TmfRole.normal:
        break;
    }
    if (hasSlots) return slotColor(key);
    return key == 0 ? null : (0xFF000000 | (key & 0xFFFFFF));
  }

  /// Genera la geometría de una unidad repartida por filamento (o por color si el archivo
  /// no trae filamentos).
  Map<int, _Group> _emit(_Unit u, int ext, bool hasSlots) {
    final raw = u.raw;
    final pos = raw.pos!;
    final tri = raw.tri ?? Uint32List(0);
    final out = <int, _Group>{};
    _Group grp(int k) => out.putIfAbsent(k, _Group.new);
    final paint = raw.paint;
    final cx = raw.complex;
    final decoder = PaintDecoder((ax, ay, az, bx, by, bz, cx2, cy, cz, st) {
      final slot = st > 0 ? st : ext;
      grp(hasSlots ? slot : 0).tri(ax, ay, az, bx, by, bz, cx2, cy, cz);
    });
    final p1 = raw.triP1, p2 = raw.triP2, p3 = raw.triP3, tp = raw.triPid;
    final model = _model(u.file);
    final objPid = raw.pid;
    final colorKey = <int, int>{};
    int colorOf(int tIdx) {
      // sin filamentos: color del material (por triángulo o por objeto)
      String? pid;
      int a = -1, b = -1, c = -1;
      if (p1 != null && p1[tIdx] >= 0) {
        pid = tp![tIdx] >= 0 ? '${tp[tIdx]}' : objPid;
        a = p1[tIdx];
        b = p2![tIdx] >= 0 ? p2[tIdx] : a;
        c = p3![tIdx] >= 0 ? p3[tIdx] : a;
      } else if (objPid != null) {
        pid = objPid;
        a = b = c = raw.pindex;
      }
      if (pid == null) return 0;
      final list = model.colors[pid];
      if (list == null || a < 0 || a >= list.length) return 0;
      int col(int i) => i >= 0 && i < list.length ? list[i] : list[a];
      final ca = list[a], cb = col(b), cc = col(c);
      if (ca == cb && cb == cc) return 0x1000000 | (ca & 0xFFFFFF);
      int ch(int sh) => ((((ca >> sh) & 255) + ((cb >> sh) & 255) + ((cc >> sh) & 255)) ~/ 3);
      return 0x1000000 | (ch(16) << 16) | (ch(8) << 8) | ch(0);
    }

    for (var t = u.first; t < u.last; t++) {
      final ia = tri[t * 3] * 3, ib = tri[t * 3 + 1] * 3, ic = tri[t * 3 + 2] * 3;
      if (ia + 2 >= pos.length || ib + 2 >= pos.length || ic + 2 >= pos.length) continue;
      final ax = pos[ia].toDouble(), ay = pos[ia + 1].toDouble(), az = pos[ia + 2].toDouble();
      final bx = pos[ib].toDouble(), by = pos[ib + 1].toDouble(), bz = pos[ib + 2].toDouble();
      final cx2 = pos[ic].toDouble(), cy = pos[ic + 1].toDouble(), cz = pos[ic + 2].toDouble();
      final st = paint == null ? 0 : paint[t];
      if (st == 255 && cx != null && cx[t] != null) {
        decoder.decode(cx[t]!, [ax, ay, az], [bx, by, bz], [cx2, cy, cz]);
        continue;
      }
      if (hasSlots) {
        grp(st > 0 && st < 255 ? st : ext).tri(ax, ay, az, bx, by, bz, cx2, cy, cz);
      } else {
        final key = colorKey.putIfAbsent(t, () => colorOf(t));
        grp(key).tri(ax, ay, az, bx, by, bz, cx2, cy, cz);
        if (colorKey.length > 4096) colorKey.clear();
      }
    }
    final bm = raw.beams;
    if (bm != null && u.first == 0) _beams(bm, pos, grp(hasSlots ? ext : 0));
    if (!hasSlots && out.length > 48) return _quantize(out);
    return out;
  }

  /// Vigas de una retícula como prismas de seis caras (cónicos si los radios difieren).
  void _beams(Float32List bm, Float32List pos, _Group g) {
    const sides = 6;
    final cs = [for (var k = 0; k < sides; k++) math.cos(2 * math.pi * k / sides)];
    final sn = [for (var k = 0; k < sides; k++) math.sin(2 * math.pi * k / sides)];
    for (var i = 0; i + 7 < bm.length; i += 8) {
      final a = bm[i].toInt() * 3, b = bm[i + 1].toInt() * 3;
      if (a + 2 >= pos.length || b + 2 >= pos.length) continue;
      final r1 = bm[i + 2].toDouble(), r2 = bm[i + 3].toDouble();
      final ax = pos[a].toDouble(), ay = pos[a + 1].toDouble(), az = pos[a + 2].toDouble();
      final bx = pos[b].toDouble(), by = pos[b + 1].toDouble(), bz = pos[b + 2].toDouble();
      var dx = bx - ax, dy = by - ay, dz = bz - az;
      final len = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (len < 1e-9) continue;
      dx /= len;
      dy /= len;
      dz /= len;
      // dos ejes perpendiculares a la viga
      var ux = dy.abs() < 0.9 ? 0.0 : 1.0, uy = dy.abs() < 0.9 ? 1.0 : 0.0, uz = 0.0;
      var px = dy * uz - dz * uy, py = dz * ux - dx * uz, pz = dx * uy - dy * ux;
      final pl = math.sqrt(px * px + py * py + pz * pz);
      px /= pl;
      py /= pl;
      pz /= pl;
      ux = dy * pz - dz * py;
      uy = dz * px - dx * pz;
      uz = dx * py - dy * px;
      List<double> ring(double cx, double cy, double cz, double r, int k) => [
        cx + r * (cs[k] * px + sn[k] * ux),
        cy + r * (cs[k] * py + sn[k] * uy),
        cz + r * (cs[k] * pz + sn[k] * uz),
      ];
      for (var k = 0; k < sides; k++) {
        final k2 = (k + 1) % sides;
        final a0 = ring(ax, ay, az, r1, k), a1 = ring(ax, ay, az, r1, k2);
        final b0 = ring(bx, by, bz, r2, k), b1 = ring(bx, by, bz, r2, k2);
        g.tri(a0[0], a0[1], a0[2], a1[0], a1[1], a1[2], b1[0], b1[1], b1[2]);
        g.tri(a0[0], a0[1], a0[2], b1[0], b1[1], b1[2], b0[0], b0[1], b0[2]);
        g.tri(ax, ay, az, a1[0], a1[1], a1[2], a0[0], a0[1], a0[2]);
        g.tri(bx, by, bz, b0[0], b0[1], b0[2], b1[0], b1[1], b1[2]);
      }
    }
  }

  /// Demasiados colores sueltos: se agrupan a 4 bits por canal (o 3 si siguen siendo muchos).
  Map<int, _Group> _quantize(Map<int, _Group> src) {
    for (final bits in [4, 3]) {
      final sh = 8 - bits;
      final out = <int, _Group>{};
      for (final e in src.entries) {
        final c = e.key;
        int q(int v) {
          final x = (v >> sh);
          return (x << sh) | (x << sh >> bits);
        }

        final k = e.key == 0
            ? 0
            : 0x1000000 |
                  (q((c >> 16) & 255) << 16) |
                  (q((c >> 8) & 255) << 8) |
                  q(c & 255);
        final g = out.putIfAbsent(k, _Group.new);
        final s = e.value;
        for (var t = 0; t < s.n; t++) {
          final o = t * 18;
          g.tri(
            s.a[o], s.a[o + 1], s.a[o + 2], //
            s.a[o + 6], s.a[o + 7], s.a[o + 8],
            s.a[o + 12], s.a[o + 13], s.a[o + 14],
          );
        }
      }
      if (out.length <= 160 || bits == 3) return out;
    }
    return src;
  }
}

// ---- configuración de los programas

class _CfgPart {
  _CfgPart(this.name, this.role, this.extruder);
  final String name;
  final TmfRole role;
  final int extruder;
}

class _CfgVolume {
  _CfgVolume(this.first, this.last, this.name, this.role, this.extruder);
  final int first, last;
  final String name;
  final TmfRole role;
  final int extruder;
}

class _CfgObject {
  String name = '';
  int extruder = 1;
  final overrides = <String, String>{};
  final parts = <String, _CfgPart>{};
  final volumes = <_CfgVolume>[];
}

class _Config {
  _Config(this.zip, this.project);
  final ZipLite zip;
  final ThreeMfProject project;
  final objects = <String, _CfgObject>{};
  final plateObjects = <int, List<String>>{};

  static String? _a(String tag, String name) =>
      RegExp('(?:^|\\s)$name="([^"]*)"').firstMatch(tag)?.group(1);

  static String _unesc(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  static TmfRole _bambuRole(String s) => switch (s) {
    'modifier_part' => TmfRole.modifier,
    'negative_part' => TmfRole.negative,
    'support_blocker' => TmfRole.blocker,
    'support_enforcer' => TmfRole.enforcer,
    _ => TmfRole.normal,
  };

  static TmfRole _prusaRole(String s) => switch (s) {
    'ParameterModifier' => TmfRole.modifier,
    'NegativeVolume' => TmfRole.negative,
    'SupportBlocker' => TmfRole.blocker,
    'SupportEnforcer' => TmfRole.enforcer,
    _ => TmfRole.normal,
  };

  // Ajustes de objeto que el usuario entiende y que cambian la impresión.
  static const _interesting = {
    'layer_height',
    'sparse_infill_density',
    'sparse_infill_pattern',
    'wall_loops',
    'enable_support',
    'support_type',
    'support_style',
    'brim_type',
    'brim_width',
    'raft_layers',
    'top_shell_layers',
    'bottom_shell_layers',
    'infill_wall_overlap',
    'skeleton_infill_density',
    'skin_infill_density',
    // PrusaSlicer
    'perimeters',
    'fill_density',
    'fill_pattern',
    'support_material',
    'top_solid_layers',
    'bottom_solid_layers',
    'gap_fill_enabled',
  };

  void readBambu() {
    final ms = zip.text('Metadata/model_settings.config') ?? '';
    for (final om in RegExp(r'<object\b([^>]*)>(.*?)</object>', dotAll: true).allMatches(ms)) {
      final id = _a(om.group(1)!, 'id');
      if (id == null) continue;
      final body = om.group(2)!;
      final o = _CfgObject();
      final head = body.split('<part').first;
      for (final m in RegExp(r'<metadata\s+key="([^"]*)"\s+value="([^"]*)"').allMatches(head)) {
        final k = m.group(1)!, v = _unesc(m.group(2)!);
        if (k == 'name') {
          o.name = v;
        } else if (k == 'extruder') {
          o.extruder = int.tryParse(v) ?? 1;
        } else if (_interesting.contains(k)) {
          o.overrides[k] = v;
        }
      }
      for (final pm in RegExp(r'<part\b([^>]*)>(.*?)</part>', dotAll: true).allMatches(body)) {
        final pid = _a(pm.group(1)!, 'id');
        if (pid == null) continue;
        var name = '';
        var ext = 0;
        for (final m in RegExp(r'<metadata\s+key="([^"]*)"\s+value="([^"]*)"').allMatches(pm.group(2)!)) {
          if (m.group(1) == 'name') name = _unesc(m.group(2)!);
          if (m.group(1) == 'extruder') ext = int.tryParse(m.group(2)!) ?? 0;
        }
        o.parts[pid] = _CfgPart(name, _bambuRole(_a(pm.group(1)!, 'subtype') ?? ''), ext);
      }
      objects[id] = o;
    }
    for (final pm in RegExp(r'<plate>(.*?)</plate>', dotAll: true).allMatches(ms)) {
      final b = pm.group(1)!;
      String? kv(String k) =>
          RegExp('key="$k"\\s+value="([^"]*)"').firstMatch(b)?.group(1);
      final idx = (int.tryParse(kv('plater_id') ?? '') ?? (project.plates.length + 1)) - 1;
      final p = TmfPlate(idx)
        ..name = _unesc(kv('plater_name') ?? '')
        ..thumbnail = kv('thumbnail_file')
        ..topView = kv('top_file')
        ..gcodeEntry = kv('gcode_file');
      project.plates.add(p);
      plateObjects[idx] = [
        for (final m in RegExp(r'key="object_id"\s+value="(\d+)"').allMatches(b)) m.group(1)!,
      ];
    }
    project.plates.sort((a, b) => a.index.compareTo(b.index));
    _bambuProject();
    _bambuSlice();
    // La lista queda numerada 0..n-1; el número del programa se conserva en `number`.
    final remap = <int, int>{};
    for (var i = 0; i < project.plates.length; i++) {
      final pl = project.plates[i];
      remap[pl.index] = i;
      pl.number = pl.index + 1;
      pl.index = i;
    }
    final old = Map.of(plateObjects);
    plateObjects.clear();
    old.forEach((k, v) {
      final n = remap[k];
      if (n != null) plateObjects[n] = v;
    });
  }

  void _bambuProject() {
    final raw = zip.text('Metadata/project_settings.config');
    if (raw == null) return;
    Map<String, dynamic> j;
    try {
      j = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    String s(String k) {
      final v = j[k];
      if (v == null) return '';
      if (v is List) return v.isEmpty ? '' : '${v.first}';
      return '$v';
    }

    List<String> l(String k) {
      final v = j[k];
      if (v is List) return [for (final e in v) '$e'];
      return v == null ? <String>[] : ['$v'];
    }

    project.printer = s('printer_model').isNotEmpty ? s('printer_model') : s('printer_settings_id');
    project.processName = s('print_settings_id');
    project.nozzle = double.tryParse(s('nozzle_diameter')) ?? 0;
    final area = l('printable_area');
    _bed(area);
    project.bedZ = double.tryParse(s('printable_height')) ?? 0;
    final cols = l('filament_colour');
    final types = l('filament_type');
    final prof = l('filament_settings_id');
    final dens = l('filament_density');
    final diam = l('filament_diameter');
    final temp = l('nozzle_temperature');
    final cost = l('filament_cost');
    for (var i = 0; i < cols.length; i++) {
      project.filaments.add(
        TmfFilament(
          i + 1,
          _hex(cols[i]) ?? 0xFFB7CACD,
          type: i < types.length ? types[i] : '',
          profile: i < prof.length ? prof[i] : '',
        )
          ..density = i < dens.length ? double.tryParse(dens[i]) ?? 0 : 0
          ..diameter = i < diam.length ? double.tryParse(diam[i]) ?? 1.75 : 1.75
          ..nozzleTemp = i < temp.length ? int.tryParse(temp[i]) ?? 0 : 0
          ..cost = i < cost.length ? double.tryParse(cost[i]) ?? 0 : 0,
      );
    }
    for (final k in const [
      'layer_height',
      'initial_layer_print_height',
      'wall_loops',
      'top_shell_layers',
      'bottom_shell_layers',
      'sparse_infill_density',
      'sparse_infill_pattern',
      'enable_support',
      'support_type',
      'support_style',
      'brim_type',
      'raft_layers',
      'curr_bed_type',
      'seam_position',
      'outer_wall_speed',
      'ironing_type',
      'enable_prime_tower',
    ]) {
      final v = s(k);
      if (v.isNotEmpty) project.settings[k] = v;
    }
    if (s('print_sequence').isNotEmpty) project.settings['print_sequence'] = s('print_sequence');
  }

  void _bed(List<String> area) {
    var mx = 0.0, my = 0.0;
    for (final p in area) {
      final xy = p.split('x');
      if (xy.length == 2) {
        mx = math.max(mx, double.tryParse(xy[0]) ?? 0);
        my = math.max(my, double.tryParse(xy[1]) ?? 0);
      }
    }
    if (mx > 0 && my > 0) {
      project.bedX = mx;
      project.bedY = my;
    }
  }

  void _bambuSlice() {
    final raw = zip.text('Metadata/slice_info.config');
    if (raw == null) return;
    for (final pm in RegExp(r'<plate>(.*?)</plate>', dotAll: true).allMatches(raw)) {
      final b = pm.group(1)!;
      String? kv(String k) =>
          RegExp('key="$k"\\s+value="([^"]*)"').firstMatch(b)?.group(1);
      final idx = (int.tryParse(kv('index') ?? '') ?? 1) - 1;
      final plate = project.plates.where((p) => p.index == idx).firstOrNull;
      if (plate == null) continue;
      final pred = double.tryParse(kv('prediction') ?? '');
      if (pred == null) continue;
      plate
        ..sliced = true
        ..seconds = pred
        ..grams = double.tryParse(kv('weight') ?? '') ?? 0
        ..supportUsed = kv('support_used') == 'true'
        ..outside = kv('outside') == 'true'
        ..pauses = int.tryParse(kv('pause_count') ?? '') ?? 0
        ..nozzle = double.tryParse(kv('nozzle_diameters') ?? '') ?? 0;
      for (final fm in RegExp(r'<filament\b([^>]*)/?>').allMatches(b)) {
        final t = fm.group(1)!;
        plate.uses.add(
          TmfUse(
            int.tryParse(_a(t, 'id') ?? '') ?? 0,
            _a(t, 'type') ?? '',
            _hex(_a(t, 'color') ?? '') ?? 0xFFB7CACD,
            double.tryParse(_a(t, 'used_g') ?? '') ?? 0,
            double.tryParse(_a(t, 'used_m') ?? '') ?? 0,
          ),
        );
      }
      // Capas con más de un color (de las listas de filamentos por rango de capas).
      var multi = 0, layers = 0;
      for (final lm in RegExp(r'<layer_filament_list\s+filament_list="([^"]*)"\s+layer_ranges="([^"]*)"').allMatches(b)) {
        final fl = lm.group(1)!.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).length;
        for (final r in lm.group(2)!.split(',')) {
          final ab = r.trim().split(RegExp(r'\s+'));
          if (ab.length == 2) {
            final n = (int.tryParse(ab[1]) ?? 0) - (int.tryParse(ab[0]) ?? 0) + 1;
            layers += n;
            if (fl > 1) multi += n;
          }
        }
      }
      if (layers > 0) plate.colorChanges = multi;
      if (plate.gcodeEntry == null) {
        final g = 'Metadata/plate_${idx + 1}.gcode';
        if (zip.has(g)) plate.gcodeEntry = g;
      }
    }
  }

  void readPrusa() {
    final raw = zip.text('Metadata/Slic3r_PE_model.config') ?? '';
    for (final om in RegExp(r'<object\b([^>]*)>(.*?)</object>', dotAll: true).allMatches(raw)) {
      final id = _a(om.group(1)!, 'id');
      if (id == null) continue;
      final body = om.group(2)!;
      final o = _CfgObject();
      final head = body.split('<volume').first;
      for (final m in RegExp(r'<metadata\s+type="object"\s+key="([^"]*)"\s+value="([^"]*)"').allMatches(head)) {
        final k = m.group(1)!, v = _unesc(m.group(2)!);
        if (k == 'name') {
          o.name = v;
        } else if (k == 'extruder') {
          o.extruder = int.tryParse(v) ?? 1;
        } else if (_interesting.contains(k)) {
          o.overrides[k] = v;
        }
      }
      for (final vm in RegExp(r'<volume\b([^>]*)>(.*?)</volume>', dotAll: true).allMatches(body)) {
        var name = '';
        var ext = 0;
        var role = TmfRole.normal;
        for (final m in RegExp(r'<metadata\s+type="volume"\s+key="([^"]*)"\s+value="([^"]*)"').allMatches(vm.group(2)!)) {
          final k = m.group(1)!, v = _unesc(m.group(2)!);
          if (k == 'name') name = v;
          if (k == 'extruder') ext = int.tryParse(v) ?? 0;
          if (k == 'volume_type') role = _prusaRole(v);
        }
        o.volumes.add(
          _CfgVolume(
            int.tryParse(_a(vm.group(1)!, 'firstid') ?? '') ?? 0,
            int.tryParse(_a(vm.group(1)!, 'lastid') ?? '') ?? 0,
            name,
            role,
            ext,
          ),
        );
      }
      objects[id] = o;
    }
    _prusaProject();
    final cg = zip.text('Metadata/Prusa_Slicer_custom_gcode_per_print_z.xml');
    if (cg != null) {
      for (final m in RegExp(r'<code\b([^>]*)/?>').allMatches(cg)) {
        final t = m.group(1)!;
        if ((_a(t, 'type') == '0' || _a(t, 'type') == '4') && _a(t, 'print_z') != null) {
          // type 0 = cambio de color (M600), 4 = cambio de extrusor
          final z = double.tryParse(_a(t, 'print_z')!);
          if (z != null) project.colorChangeZ.add(z);
        }
      }
    }
  }

  void _prusaProject() {
    final raw = zip.text('Metadata/Slic3r_PE.config');
    if (raw == null) return;
    final kv = <String, String>{};
    for (final line in const LineSplitter().convert(raw)) {
      if (!line.startsWith(';')) continue;
      final i = line.indexOf('=');
      if (i < 0) continue;
      kv[line.substring(1, i).trim()] = line.substring(i + 1).trim();
    }
    String s(String k) => kv[k] ?? '';
    String first(String k) => s(k).split(RegExp(r'[,;]')).first.trim();
    project.printer = s('printer_model').isNotEmpty ? s('printer_model') : s('printer_settings_id');
    project.processName = s('print_settings_id');
    project.nozzle = double.tryParse(first('nozzle_diameter')) ?? 0;
    _bed(s('bed_shape').split(','));
    project.bedZ = double.tryParse(s('max_print_height')) ?? 0;
    final cols = s('filament_colour').split(';');
    final ecols = s('extruder_colour').split(';');
    final types = s('filament_type').split(';');
    final dens = s('filament_density').split(',');
    final diam = s('filament_diameter').split(',');
    final temp = s('temperature').split(',');
    final n = cols.where((e) => e.isNotEmpty).length;
    for (var i = 0; i < n; i++) {
      var c = _hex(cols[i]);
      if (c == null && i < ecols.length) c = _hex(ecols[i]);
      project.filaments.add(
        TmfFilament(i + 1, c ?? 0xFFB7CACD, type: i < types.length ? types[i].replaceAll('"', '') : '')
          ..density = i < dens.length ? double.tryParse(dens[i]) ?? 0 : 0
          ..diameter = i < diam.length ? double.tryParse(diam[i]) ?? 1.75 : 1.75
          ..nozzleTemp = i < temp.length ? int.tryParse(temp[i]) ?? 0 : 0,
      );
    }
    const map = {
      'layer_height': 'layer_height',
      'first_layer_height': 'initial_layer_print_height',
      'perimeters': 'wall_loops',
      'top_solid_layers': 'top_shell_layers',
      'bottom_solid_layers': 'bottom_shell_layers',
      'fill_density': 'sparse_infill_density',
      'fill_pattern': 'sparse_infill_pattern',
      'support_material': 'enable_support',
      'brim_width': 'brim_width',
      'raft_layers': 'raft_layers',
    };
    for (final e in map.entries) {
      final v = s(e.key);
      if (v.isNotEmpty) project.settings[e.value] = v;
    }
  }

  /// Cierra la información de las piezas cuando ya se conoce la geometría.
  void finish(List<TmfObjectInfo> objs) {}

  static int? _hex(String s) {
    var t = s.trim().replaceAll('"', '');
    if (t.startsWith('#')) t = t.substring(1);
    if (t.length == 6 || t.length == 8) {
      final v = int.tryParse(t.substring(0, 6), radix: 16);
      if (v != null) return 0xFF000000 | v;
    }
    return null;
  }
}
