// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, FontFeature;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../model/mesh.dart';
import '../model/mesh_check.dart';
import '../model/scene.dart';
import '../l10n/l10n.dart';
import '../model/thickness.dart';
import '../model/units.dart';
import '../render/gpu_mesh.dart';
import 'glass.dart';
import 'theme.dart';
import '../io/iso_run.dart';
import '../model/unit_system.dart';

/// Cama de impresión de una máquina habitual (mm).
class BedPreset {
  const BedPreset(this.name, this.x, this.y, this.z);
  final String name;
  final double x, y, z;
}

const kBeds = <BedPreset>[
  BedPreset('Bambu A1 mini', 180, 180, 180),
  BedPreset('Prusa MINI', 180, 180, 180),
  BedPreset('Ender-3', 220, 220, 250),
  BedPreset('Prusa MK4', 250, 210, 220),
  BedPreset('Bambu A1 · P1 · X1', 256, 256, 256),
  BedPreset('Creality K1 Max', 300, 300, 300),
  BedPreset('Voron 350', 350, 350, 350),
];

/// Material de impresión y su densidad (g/cm³).
const kPrintMaterials = <(String, double)>[
  ('PLA', 1.24),
  ('PETG', 1.27),
  ('ABS', 1.04),
  ('ASA', 1.07),
  ('TPU', 1.21),
  ('Nailon', 1.14),
  ('Resina', 1.10),
];

/// Cómo quedaría la pieza apoyada sobre una de sus seis caras «de caja».
class OrientationInfo {
  OrientationInfo(
    this.label,
    this.axis,
    this.sign,
    this.overhangMm2,
    this.baseMm2,
    this.heightMm,
  );
  final String label;
  final int axis; // 0 X, 1 Y, 2 Z
  final int sign; // +1: se apoya en la cara cuya normal mira a +eje
  final double overhangMm2, baseMm2, heightMm;
}

/// Una orientación de la pieza sobre la cama y si cabe.
class FitResult {
  FitResult(this.label, this.size, this.fits, this.overflow);
  final String label;
  final List<double> size; // mm: ancho, fondo, alto sobre la cama
  final bool fits;
  final double overflow; // mm que sobran en el peor eje (0 si cabe)
}

class StlController extends ChangeNotifier {
  StlController(this.mesh, this.meta, this.name) {
    options.edges = false;
  }
  final Mesh mesh;
  final StlMeta? meta;
  final String name;
  final RenderOptions options = RenderOptions();

  MeshReport? report;
  bool checking = false;

  /// Milímetros por unidad del archivo (por defecto 1 = el archivo está en mm).
  LengthUnit unit = LengthUnit.mm;
  bool unitChosen = false;

  int bed = 3;
  int material = 0;
  double infill = 0.15;
  bool showBed = false;

  double overhangDeg = 45;
  bool overhangView = false;
  Scene? overhangScene;
  double overhangArea = 0, baseArea = 0;
  bool overhangBusy = false;

  // Espesor de pared
  bool thicknessView = false;
  bool thicknessBusy = false;
  double thicknessMm = 0.8; // umbral
  Scene? thicknessScene;
  ThicknessResult? thickness;
  SelfIntersections? selfInt;
  bool selfIntBusy = false;

  Future<void> findSelfInt() async {
    if (selfIntBusy) return;
    selfIntBusy = true;
    notifyListeners();
    final src = TransferableTypedData.fromList([mesh.vertices]);
    try {
      selfInt = await isoRun(() => findSelfIntersections(src.materialize().asFloat32List()));
    } catch (_) {
      selfInt = null;
    }
    selfIntBusy = false;
    notifyListeners();
  }
  Float32List? _triAreas;

  /// Superficie (mm²) con pared más fina que el umbral, entre uno y 1,5 umbrales, y medida en total.
  double thinArea = 0, warnArea = 0, measuredArea = 0;

  // Defectos que se dibujan sobre el modelo.
  bool showDefects = false;
  MeshHole? focusedHole;
  bool showNonManifold = false, showInconsistent = false;

  // Medición entre dos puntos de la superficie.
  bool measuring = false;
  final List<vm.Vector3> points = [];

  // Sección.
  int sectionAxis = -1; // -1 = sin sección
  double sectionT = 0.5;
  bool sectionFlip = false;

  /// Versión simplificada (≈200 mil triángulos) para girar mallas enormes con soltura.
  Scene? lodScene;

  Future<void> _buildLod() async {
    if (mesh.triangleCount < 400000) return;
    final src = TransferableTypedData.fromList([mesh.vertices]);
    final mn = mesh.bounds.min, mx = mesh.bounds.max;
    final d = await isoRun(
      () => decimateMesh(src.materialize().asFloat32List(), mn, mx, 100000),
    );
    final part = Part(
      id: 0,
      name: 'lod',
      mesh: Mesh(vertices: d, bounds: mesh.bounds),
    );
    lodScene = Scene(
      name: 'lod',
      root: SceneNode(name: 'lod', part: part),
      parts: [part],
    );
  }

  /// Colores por triángulo del archivo (estilo Magics): una pieza por color.
  Scene? colorScene;
  bool fileColor = true;

  Future<void> _buildColorScene() async {
    final colors = meta?.colors;
    if (colors == null) return;
    final src = TransferableTypedData.fromList([mesh.vertices]);
    final cs = TransferableTypedData.fromList([colors]);
    final def = meta?.defaultColor ?? const [183, 202, 205];
    final groups = await isoRun(() {
      final v = src.materialize().asFloat32List();
      final c = cs.materialize().asUint16List();
      final n = math.min(v.length ~/ 18, c.length);
      int key(int p) {
        if ((p & 0x8000) != 0) return -1; // sin color propio: el de la cabecera
        return ((p >> 10) & 31) << 10 | ((p >> 5) & 31) << 5 | (p & 31);
      }

      // Más de 24 colores distintos: se agrupan a 3 bits por canal.
      final distinct = <int>{for (var t = 0; t < n; t++) key(c[t])};
      final coarse = distinct.length > 24;
      int q(int k) => k < 0 || !coarse
          ? k
          : ((k >> 12) & 7) << 6 | ((k >> 7) & 7) << 3 | ((k >> 2) & 7);
      final map = <int, List<double>>{};
      for (var t = 0; t < n; t++) {
        final k = q(key(c[t]));
        final l = map.putIfAbsent(k, () => []);
        for (var i = 0; i < 18; i++) {
          l.add(v[t * 18 + i]);
        }
      }
      return (
        coarse,
        {for (final e in map.entries) e.key: Float32List.fromList(e.value)},
      );
    });
    final coarse = groups.$1;
    final parts = <Part>[];
    var id = 0;
    for (final e in groups.$2.entries) {
      int r, g, b;
      if (e.key < 0) {
        r = def[0];
        g = def[1];
        b = def[2];
      } else if (coarse) {
        r = ((e.key >> 6) & 7) * 255 ~/ 7;
        g = ((e.key >> 3) & 7) * 255 ~/ 7;
        b = (e.key & 7) * 255 ~/ 7;
      } else {
        r = ((e.key >> 10) & 31) * 255 ~/ 31;
        g = ((e.key >> 5) & 31) * 255 ~/ 31;
        b = (e.key & 31) * 255 ~/ 31;
      }
      parts.add(
        Part(
          id: id++,
          name: 'color',
          mesh: Mesh(vertices: e.value, bounds: mesh.bounds),
          color: 0xFF000000 | (r << 16) | (g << 8) | b,
        ),
      );
    }
    colorScene = Scene(
      name: 'color',
      root: SceneNode(
        name: 'color',
        children: [for (final p in parts) SceneNode(name: p.name, part: p)],
      ),
      parts: parts,
    );
    notifyListeners();
  }

  void toggleFileColor() {
    fileColor = !fileColor;
    notifyListeners();
  }

  List<OrientationInfo> orientations = const [];

  Future<void> _analyzeOrientations() async {
    final src = TransferableTypedData.fromList([mesh.vertices]);
    final limit = math.sin(overhangDeg * math.pi / 180);
    final sc = scale;
    final res = await isoRun(() {
      final v = src.materialize().asFloat32List();
      final n = v.length ~/ 18;
      // Seis direcciones «hacia abajo»: ±X, ±Y, ±Z.
      final over = List<double>.filled(6, 0), base = List<double>.filled(6, 0);
      final ext = List<double>.filled(6, -double.infinity);
      final lo = List<double>.filled(3, double.infinity),
          hi = List<double>.filled(3, -double.infinity);
      for (var i = 0; i < v.length; i += 6) {
        for (var k = 0; k < 3; k++) {
          final x = v[i + k];
          if (x < lo[k]) lo[k] = x;
          if (x > hi[k]) hi[k] = x;
        }
      }
      for (var k = 0; k < 3; k++) {
        ext[k * 2] =
            hi[k]; // d = +eje: el punto más bajo es el de mayor coordenada
        ext[k * 2 + 1] = -lo[k]; // d = -eje
      }
      final tol = 0.05 / math.max(sc, 1e-9);
      for (var t = 0; t < n; t++) {
        final o = t * 18;
        final ax = v[o], ay = v[o + 1], az = v[o + 2];
        final bx = v[o + 6], by = v[o + 7], bz = v[o + 8];
        final cx = v[o + 12], cy = v[o + 13], cz = v[o + 14];
        final ux = bx - ax, uy = by - ay, uz = bz - az;
        final wx = cx - ax, wy = cy - ay, wz = cz - az;
        final nx = uy * wz - uz * wy,
            ny = uz * wx - ux * wz,
            nz = ux * wy - uy * wx;
        final len = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (len == 0) continue;
        final nn = [nx / len, ny / len, nz / len];
        final area = len / 2;
        final pts = [
          [ax, ay, az],
          [bx, by, bz],
          [cx, cy, cz],
        ];
        for (var k = 0; k < 3; k++) {
          for (var sg = 0; sg < 2; sg++) {
            final d = sg == 0 ? 1.0 : -1.0;
            final di = k * 2 + sg;
            final dot = nn[k] * d;
            if (dot <= limit) continue;
            // proyección más baja del triángulo respecto a la cara de apoyo
            var minProj = double.infinity;
            for (final p in pts) {
              final pr = p[k] * d;
              if (pr < minProj) minProj = pr;
            }
            if (dot > 0.995 && minProj >= ext[di] - tol) {
              base[di] += area;
            } else {
              over[di] += area;
            }
          }
        }
      }
      return (over, base, [hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]]);
    });
    const names = ['X', 'Y', 'Z'];
    final list = <OrientationInfo>[];
    for (var k = 0; k < 3; k++) {
      for (var sg = 0; sg < 2; sg++) {
        final di = k * 2 + sg;
        list.add(
          OrientationInfo(
            tr('Apoyada sobre la cara {a}', {'a': '${sg == 0 ? '+' : '−'}${names[k]}'}),
            k,
            sg == 0 ? 1 : -1,
            res.$1[di] * sc * sc,
            res.$2[di] * sc * sc,
            res.$3[k] * sc,
          ),
        );
      }
    }
    orientations = list;
    notifyListeners();
  }

  Future<void> run() async {
    _buildLod();
    _buildColorScene();
    _analyzeOrientations();
    checking = true;
    notifyListeners();
    try {
      report = await checkMesh(mesh.vertices);
    } catch (_) {
      report = null;
    }
    checking = false;
    // Sin unidades en el archivo: se sugiere la más razonable por el tamaño.
    notifyListeners();
  }

  double get scale => unit.mmPerUnit;

  List<double> get sizeMm => [
    for (var k = 0; k < 3; k++)
      (mesh.bounds.max[k] - mesh.bounds.min[k]) * scale,
  ];

  double get volumeCm3 =>
      (report?.volume.abs() ?? 0) * math.pow(scale, 3) / 1000;
  double get areaCm2 => (report?.area ?? 0) * scale * scale / 100;
  double get density => kPrintMaterials[material].$2;
  double get solidGrams => volumeCm3 * density;

  /// Masa estimada con paredes de 1,2 mm y el relleno elegido (cáscara maciza + relleno).
  double get estimatedGrams {
    final shell = math.min(volumeCm3, areaCm2 * 0.12); // cm² × 0,12 cm
    return (shell + (volumeCm3 - shell) * infill) * density;
  }

  /// Longitud de filamento de 1,75 mm para la masa estimada (metros).
  double get filamentMeters {
    final cm3 = estimatedGrams / density;
    return cm3 / (math.pi * 0.0875 * 0.0875) / 100;
  }

  void setUnit(LengthUnit u) {
    unit = u;
    unitChosen = true;
    notifyListeners();
  }

  /// Pista sobre la unidad cuando el tamaño es sospechoso (se da en mm).
  String? get unitHint {
    if (unitChosen) return null;
    final m = sizeMm.reduce(math.max);
    if (m < 2) return tr('Medidas muy pequeñas: ¿el archivo está en metros?');
    if (m < 8) return tr('Medidas muy pequeñas: ¿está en pulgadas?');
    if (m > 3000) return tr('Medidas muy grandes: ¿está en micras?');
    return null;
  }

  // ---- Cama

  BedPreset get bedPreset => kBeds[bed];

  /// Las seis orientaciones que dejan un eje hacia arriba, de la mejor a la peor.
  List<FitResult> get fits {
    final s = sizeMm;
    final b = bedPreset;
    final out = <FitResult>[];
    void add(String label, double w, double d, double h) {
      // La cama permite girar 90° sobre sí misma.
      double over(double bw, double bd) =>
          math.max(0, math.max(w - bw, math.max(d - bd, h - b.z)));
      final o = math.min(over(b.x, b.y), over(b.y, b.x));
      out.add(FitResult(label, [w, d, h], o <= 0, o));
    }

    add(tr('Tal como está'), s[0], s[1], s[2]);
    add(tr('Tumbada sobre {a}', {'a': 'X'}), s[0], s[2], s[1]);
    add(tr('Tumbada sobre {a}', {'a': 'Y'}), s[2], s[1], s[0]);
    out.sort((a, c) => a.overflow.compareTo(c.overflow));
    return out;
  }

  // ---- Voladizos

  Future<void> toggleThickness() async {
    thicknessView = !thicknessView;
    if (thicknessView) {
      overhangView = false;
      await _measureThickness();
    }
    notifyListeners();
  }

  void setThicknessMm(double mm) {
    thicknessMm = mm;
    if (thicknessView && thickness != null) _paintThickness();
    notifyListeners();
  }

  Future<void> _measureThickness() async {
    if (thicknessBusy) return;
    if (thickness != null) {
      await _paintThickness();
      return;
    }
    thicknessBusy = true;
    notifyListeners();
    final sw = Stopwatch()..start();
    final src = TransferableTypedData.fromList([mesh.vertices]);
    final r = await isoRun(() {
      final v = src.materialize().asFloat32List();
      final t = computeThickness(v, maxRays: 150000);
      final n = v.length ~/ 18;
      final areas = Float32List(n);
      for (var i = 0; i < n; i++) {
        final o = i * 18;
        final ux = v[o + 6] - v[o], uy = v[o + 7] - v[o + 1], uz = v[o + 8] - v[o + 2];
        final wx = v[o + 12] - v[o], wy = v[o + 13] - v[o + 1], wz = v[o + 14] - v[o + 2];
        final cx = uy * wz - uz * wy, cy = uz * wx - ux * wz, cz = ux * wy - uy * wx;
        areas[i] = math.sqrt(cx * cx + cy * cy + cz * cz) / 2;
      }
      return (t, areas);
    });
    thickness = r.$1;
    _triAreas = r.$2;
    // ignore: avoid_print
    if (const String.fromEnvironment('DATUM_CAD').isNotEmpty) print('ESPESOR ${sw.elapsedMilliseconds} ms · ${r.$1.perTriangle.length} caras · mín ${r.$1.minThickness * scale} mm');
    thicknessBusy = false;
    await _paintThickness();
  }

  Future<void> _paintThickness() async {
    final t = thickness, areas = _triAreas;
    if (t == null || areas == null) return;
    final thr = thicknessMm / math.max(scale, 1e-9);
    final src = TransferableTypedData.fromList([mesh.vertices]);
    final per = t.perTriangle;
    final r = await isoRun(() {
      final v = src.materialize().asFloat32List();
      final n = v.length ~/ 18;
      final thin = <double>[], warn = <double>[], ok = <double>[], none = <double>[];
      var aThin = 0.0, aWarn = 0.0, aAll = 0.0;
      for (var i = 0; i < n; i++) {
        final th = per[i];
        final List<double> target;
        if (th.isNaN) {
          target = none;
        } else if (th < thr) {
          target = thin;
          aThin += areas[i];
          aAll += areas[i];
        } else if (th < thr * 1.5) {
          target = warn;
          aWarn += areas[i];
          aAll += areas[i];
        } else {
          target = ok;
          aAll += areas[i];
        }
        final o = i * 18;
        for (var k = 0; k < 18; k++) {
          target.add(v[o + k]);
        }
      }
      return (Float32List.fromList(thin), Float32List.fromList(warn), Float32List.fromList(ok), Float32List.fromList(none), aThin, aWarn, aAll);
    });
    final b = mesh.bounds;
    Part part(int id, String nm, Float32List d, int color) => Part(id: id, name: nm, mesh: Mesh(vertices: d, bounds: b), color: color);
    final parts = <Part>[
      if (r.$4.isNotEmpty) part(0, 'sin medir', r.$4, 0xFF6B7F83),
      if (r.$3.isNotEmpty) part(1, 'ok', r.$3, 0xFFB7CACD),
      if (r.$2.isNotEmpty) part(2, 'justo', r.$2, 0xFFFACC15),
      if (r.$1.isNotEmpty) part(3, 'fino', r.$1, 0xFFEF4444),
    ];
    thicknessScene = Scene(
      name: 'espesor',
      root: SceneNode(name: 'espesor', children: [for (final p in parts) SceneNode(name: p.name, part: p)]),
      parts: parts,
    );
    final k = scale * scale;
    thinArea = r.$5 * k;
    warnArea = r.$6 * k;
    measuredArea = r.$7 * k;
    notifyListeners();
  }

  void toggleOverhang() {
    if (!overhangView) thicknessView = false;
    overhangView = !overhangView;
    if (overhangView) {
      _buildOverhang();
    }
    notifyListeners();
  }

  void setOverhangAngle(double deg) {
    overhangDeg = deg;
    if (overhangView) _buildOverhang();
    notifyListeners();
  }

  Future<void> _buildOverhang() async {
    if (overhangBusy) return;
    overhangBusy = true;
    final src = TransferableTypedData.fromList([mesh.vertices]);
    final limit = math.sin(overhangDeg * math.pi / 180);
    final zMin = mesh.bounds.min[2];
    final tol = 0.05 / math.max(scale, 1e-9);
    final r = await isoRun(() {
      final v = src.materialize().asFloat32List();
      final n = v.length ~/ 18;
      final ok = <double>[], over = <double>[], base = <double>[];
      var aOver = 0.0, aBase = 0.0;
      for (var t = 0; t < n; t++) {
        final o = t * 18;
        final ax = v[o], ay = v[o + 1], az = v[o + 2];
        final bx = v[o + 6], by = v[o + 7], bz = v[o + 8];
        final cx = v[o + 12], cy = v[o + 13], cz = v[o + 14];
        final ux = bx - ax, uy = by - ay, uz = bz - az;
        final wx = cx - ax, wy = cy - ay, wz = cz - az;
        final nx = uy * wz - uz * wy,
            ny = uz * wx - ux * wz,
            nz = ux * wy - uy * wx;
        final len = math.sqrt(nx * nx + ny * ny + nz * nz);
        if (len == 0) continue;
        final fz = nz / len;
        final area = len / 2;
        final target =
            fz < -0.995 && math.max(az, math.max(bz, cz)) <= zMin + tol
            ? base
            : (fz < -limit ? over : ok);
        if (identical(target, base)) aBase += area;
        if (identical(target, over)) aOver += area;
        for (var k = 0; k < 3; k++) {
          final q = o + k * 6;
          target.addAll([
            v[q],
            v[q + 1],
            v[q + 2],
            v[q + 3],
            v[q + 4],
            v[q + 5],
          ]);
        }
      }
      return (
        Float32List.fromList(ok),
        Float32List.fromList(over),
        Float32List.fromList(base),
        aOver,
        aBase,
      );
    });
    final b = mesh.bounds;
    Part part(int id, String nm, Float32List d, int color) => Part(
      id: id,
      name: nm,
      mesh: Mesh(vertices: d, bounds: b),
      color: color,
    );
    final parts = <Part>[
      if (r.$1.isNotEmpty) part(0, 'ok', r.$1, 0xFFB7CACD),
      if (r.$2.isNotEmpty) part(1, 'voladizo', r.$2, 0xFFF97316),
      if (r.$3.isNotEmpty) part(2, 'base', r.$3, 0xFF34D399),
    ];
    overhangScene = Scene(
      name: 'voladizos',
      root: SceneNode(
        name: 'voladizos',
        children: [for (final p in parts) SceneNode(name: p.name, part: p)],
      ),
      parts: parts,
    );
    overhangArea = r.$4 * scale * scale / 100;
    baseArea = r.$5 * scale * scale / 100;
    overhangBusy = false;
    notifyListeners();
  }

  // ---- Medición

  void toggleMeasure() {
    measuring = !measuring;
    points.clear();
    notifyListeners();
  }

  void addPoint(vm.Vector3 p) {
    if (points.length >= 2) points.clear();
    points.add(p);
    notifyListeners();
  }

  // ---- Sección

  void setSection(int axis, {double? t, bool? flip}) {
    sectionAxis = axis;
    if (t != null) sectionT = t;
    if (flip != null) sectionFlip = flip;
    _applySection();
    notifyListeners();
  }

  void clearSection() {
    sectionAxis = -1;
    options.clip = null;
    notifyListeners();
  }

  void _applySection() {
    if (sectionAxis < 0) {
      options.clip = null;
      return;
    }
    final lo = mesh.bounds.min[sectionAxis], hi = mesh.bounds.max[sectionAxis];
    final pos = lo + (hi - lo) * sectionT;
    final n = [0.0, 0.0, 0.0]..[sectionAxis] = sectionFlip ? -1 : 1;
    options.clip = vm.Vector4(n[0], n[1], n[2], sectionFlip ? -pos : pos);
  }

  // ---- Capas de líneas sobre el modelo

  LineBuf _lines(Float32List segs, Color c) {
    final out = Float32List(segs.length ~/ 6 * 12);
    var o = 0;
    for (var i = 0; i + 5 < segs.length; i += 6) {
      for (var k = 0; k < 2; k++) {
        out[o++] = segs[i + k * 3];
        out[o++] = segs[i + k * 3 + 1];
        out[o++] = segs[i + k * 3 + 2];
        out[o++] = 0;
        out[o++] = 0;
        out[o++] = 1;
      }
    }
    return LineBuf(out, c);
  }

  /// Líneas que se dibujan encima del modelo: defectos, cama, medida.
  void refreshOverlays() {
    final list = <LineBuf>[];
    final r = report;
    if (showDefects && r != null) {
      final holes = focusedHole != null ? [focusedHole!] : r.holes;
      for (final h in holes) {
        list.add(_lines(h.segments, const Color(0xFFFB923C)));
      }
      if (showNonManifold) {
        list.add(_lines(r.nonManifoldSegments, const Color(0xFFF43F5E)));
      }
      if (showInconsistent) {
        list.add(_lines(r.inconsistentSegments, const Color(0xFFFACC15)));
      }
    }
    if (showBed) {
      final b = bedPreset;
      final f = fits.first;
      final cx = (mesh.bounds.min[0] + mesh.bounds.max[0]) / 2;
      final cy = (mesh.bounds.min[1] + mesh.bounds.max[1]) / 2;
      final z0 = mesh.bounds.min[2];
      final hx = b.x / 2 / scale, hy = b.y / 2 / scale, hz = b.z / scale;
      final p = <List<double>>[
        [cx - hx, cy - hy, z0],
        [cx + hx, cy - hy, z0],
        [cx + hx, cy + hy, z0],
        [cx - hx, cy + hy, z0],
      ];
      final s = <double>[];
      void seg(List<double> a, List<double> c) => s.addAll([...a, ...c]);
      for (var i = 0; i < 4; i++) {
        final a = p[i], c = p[(i + 1) % 4];
        seg(a, c);
        seg([a[0], a[1], z0 + hz], [c[0], c[1], z0 + hz]);
        seg(a, [a[0], a[1], z0 + hz]);
      }
      list.add(
        _lines(
          Float32List.fromList(s),
          f.fits ? DT.mint : const Color(0xFFFB923C),
        ),
      );
    }
    if (points.isNotEmpty) {
      final b = mesh.bounds;
      final r0 =
          [for (var k = 0; k < 3; k++) b.max[k] - b.min[k]].reduce(math.max) *
          0.02;
      final s = <double>[];
      for (final p in points) {
        s.addAll([p.x - r0, p.y, p.z, p.x + r0, p.y, p.z]);
        s.addAll([p.x, p.y - r0, p.z, p.x, p.y + r0, p.z]);
        s.addAll([p.x, p.y, p.z - r0, p.x, p.y, p.z + r0]);
      }
      if (points.length == 2) {
        s.addAll([...points[0].storage, ...points[1].storage]);
      }
      list.add(_lines(Float32List.fromList(s), DT.mint));
    }
    options.pmiLines = list;
  }

  /// Texto de la medida entre los dos puntos.
  String? get measureText {
    if (points.length < 2) return null;
    final d = (points[1] - points[0]) * scale;
    final len = d.length;
    String f(double v) => Units.len(v);
    return tr('Distancia {d}  ·  ΔX {x}  ·  ΔY {y}  ·  ΔZ {z}', {'d': f(len), 'x': f(d.x.abs()), 'y': f(d.y.abs()), 'z': f(d.z.abs())});
  }

  void refresh() => notifyListeners();

  void showHole(MeshHole? h) {
    focusedHole = h;
    showDefects = h != null || showDefects;
    refreshOverlays();
    notifyListeners();
  }
}

// ---------------------------------------------------------------- hojas

Future<void> datumSheet(BuildContext context, Widget child) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 640,
              maxHeight: MediaQuery.of(ctx).size.height * 0.86,
            ),
            child: Glass(
              radius: 26,
              color: const Color(0xF2101B1F),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

Widget sheetTitle(String t, {String? sub}) => Padding(
  padding: const EdgeInsets.only(bottom: 10),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        t,
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
      ),
      if (sub != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            sub,
            style: const TextStyle(color: DT.muted, fontSize: 12.5),
          ),
        ),
    ],
  ),
);

Widget sheetRow(String k, String v, {Color? color}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
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

Widget sheetLabel(String t) => Padding(
  padding: const EdgeInsets.only(top: 14, bottom: 6),
  child: Text(
    t,
    style: const TextStyle(
      fontSize: 11.5,
      letterSpacing: 1.6,
      color: DT.muted,
      fontWeight: FontWeight.w600,
    ),
  ),
);

String fmtNum(double v, {int d = 1}) {
  final s = v.toStringAsFixed(d);
  final parts = s.split('.');
  final ip = parts[0].replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (m) => kThousands,
  );
  return parts.length > 1 ? '$ip${L.decimal}${parts[1]}' : ip;
}

/// Revisión de la malla: ¿se puede laminar tal cual?
Future<void> showMeshReviewSheet(
  BuildContext context,
  StlController c, {
  required void Function(MeshHole) onHole,
}) {
  return datumSheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) {
        final r = c.report;
        if (r == null) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sheetTitle(tr('Revisión de la malla')),
              Text(
                c.checking
                    ? tr('Revisando la malla…')
                    : tr('No se pudo revisar la malla.'),
                style: const TextStyle(color: DT.muted),
              ),
            ],
          );
        }
        final ok =
            r.watertight &&
            r.degenerate == 0 &&
            r.duplicates == 0 &&
            r.volume > 0;
        Widget item({
          required bool bad,
          required String title,
          required String detail,
          Widget? action,
        }) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                bad
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline_rounded,
                size: 20,
                color: bad ? DT.orangeSoft : DT.mint,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 14.5)),
                    Text(
                      detail,
                      style: const TextStyle(color: DT.muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              if (action != null) action,
            ],
          ),
        );

        final shells = r.shells;
        final big = shells.isEmpty
            ? 0.0
            : shells.map((s) => s.volume.abs()).reduce(math.max);
        final crumbs = shells.where((s) => s.volume.abs() < big * 0.01).length;
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sheetTitle(
                tr('Revisión de la malla'),
                sub: tr('{t} triángulos · {v} vértices · {s}', {
                  't': fmtNum(r.triangles.toDouble(), d: 0),
                  'v': fmtNum(r.vertices.toDouble(), d: 0),
                  's': shells.length == 1
                      ? tr('{n} casco', {'n': 1})
                      : tr('{n} cascos', {'n': shells.length}),
                }),
              ),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: (ok ? DT.mint : DT.orangeSoft).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(
                      ok
                          ? Icons.check_circle_rounded
                          : Icons.report_problem_rounded,
                      color: ok ? DT.mint : DT.orangeSoft,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        ok
                            ? tr('Malla cerrada y bien orientada: lista para laminar.')
                            : r.watertight && r.volume > 0
                            ? tr('La malla es estanca; hay detalles menores.')
                            : tr('La malla tiene defectos: un laminador puede fallar o tener que repararla.'),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: ok ? DT.mint : DT.orangeSoft,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              item(
                bad: r.boundaryEdges > 0,
                title: r.boundaryEdges == 0
                    ? tr('Sin agujeros')
                    : (r.holes.length == 1
                          ? tr('{n} agujero ({e} aristas abiertas)', {'n': 1, 'e': fmtNum(r.boundaryEdges.toDouble(), d: 0)})
                          : tr('{n} agujeros ({e} aristas abiertas)', {'n': r.holes.length, 'e': fmtNum(r.boundaryEdges.toDouble(), d: 0)})),
                detail: r.boundaryEdges == 0
                    ? tr('Cada arista une dos triángulos.')
                    : tr('Aristas con un solo triángulo: la superficie no se cierra.'),
                action: r.holes.isEmpty
                    ? null
                    : TextButton(
                        onPressed: () {
                          c.showDefects = true;
                          c.showHole(null);
                          onHole(r.holes.first);
                        },
                        child: Text(tr('Ver')),
                      ),
              ),
              if (r.holes.length > 1)
                SizedBox(
                  height: 38,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (var i = 0; i < r.holes.length && i < 40; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(
                            label: Text(
                              '#${i + 1} · ${Units.mm(r.holes[i].size * c.scale)}',
                            ),
                            onPressed: () => onHole(r.holes[i]),
                          ),
                        ),
                    ],
                  ),
                ),
              item(
                bad: r.nonManifoldEdges > 0,
                title: r.nonManifoldEdges == 0
                    ? tr('Sin aristas compartidas por más de dos triángulos')
                    : tr('{n} aristas no-manifold', {'n': fmtNum(r.nonManifoldEdges.toDouble(), d: 0)}),
                detail: r.nonManifoldEdges == 0
                    ? tr('La malla es una variedad.')
                    : tr('Tres o más triángulos comparten una arista (geometría pegada o solapada).'),
                action: r.nonManifoldEdges == 0
                    ? null
                    : Switch(
                        value: c.showNonManifold,
                        onChanged: (v) {
                          c.showNonManifold = v;
                          c.showDefects = true;
                          c.refreshOverlays();
                          c.refresh();
                        },
                      ),
              ),
              item(
                bad: r.inconsistentEdges > 0 || r.volume < 0,
                title: r.volume < 0
                    ? tr('Normales hacia dentro')
                    : r.inconsistentEdges > 0
                    ? tr('{n} aristas con orientación mezclada', {'n': fmtNum(r.inconsistentEdges.toDouble(), d: 0)})
                    : tr('Normales orientadas hacia fuera'),
                detail: r.volume < 0
                    ? tr('El volumen sale negativo: la malla está del revés.')
                    : r.inconsistentEdges > 0
                    ? tr('Triángulos vecinos con el sentido invertido: el laminador no sabe qué es dentro.')
                    : tr('El volumen es positivo y el sentido es coherente.'),
                action: r.inconsistentEdges == 0
                    ? null
                    : Switch(
                        value: c.showInconsistent,
                        onChanged: (v) {
                          c.showInconsistent = v;
                          c.showDefects = true;
                          c.refreshOverlays();
                          c.refresh();
                        },
                      ),
              ),
              item(
                bad: r.degenerate > 0 || r.duplicates > 0,
                title: r.degenerate == 0 && r.duplicates == 0
                    ? tr('Sin triángulos degenerados ni repetidos')
                    : tr('{a} degenerados · {b} repetidos', {'a': r.degenerate, 'b': r.duplicates}),
                detail:
                    tr('Triángulos sin área o copiados; suelen venir de exportaciones con errores.'),
              ),
              item(
                bad: shells.length > 1 && crumbs > 0,
                title: shells.length == 1
                    ? tr('Un solo casco')
                    : (crumbs > 0
                          ? tr('{n} cascos sueltos ({c} diminutos)', {'n': shells.length, 'c': crumbs})
                          : tr('{n} cascos sueltos', {'n': shells.length})),
                detail: shells.length == 1
                    ? tr('Una sola pieza.')
                    : tr('Piezas separadas en el mismo archivo; los diminutos suelen ser restos.'),
              ),
              if (shells.length > 1)
                for (final (i, s) in shells.take(5).indexed)
                  sheetRow(
                    tr('  Casco {n}', {'n': i + 1}),
                    Units.tru('{t} tri · {v} cm³', {
                          't': fmtNum(s.triangles.toDouble(), d: 0),
                          'v': Units.volumeCm3N(s.volume.abs() * math.pow(c.scale, 3) / 1000, d: 2),
                        }) +
                        (s.closed ? '' : tr(' · abierto')),
                  ),
              sheetLabel(tr('ARCHIVO')),
              if (c.meta != null) ...[
                sheetRow(tr('Formato'), c.meta!.binary ? tr('STL binario') : 'STL ASCII'),
                sheetRow(tr('Tamaño'), '${fmtNum(c.meta!.bytes / 1e6, d: 2)} MB'),
                if (c.meta!.solids > 1) sheetRow(tr('Sólidos'), '${c.meta!.solids}'),
                if (c.meta!.header.isNotEmpty) sheetRow(tr('Cabecera'), c.meta!.header),
                if (c.meta!.colored)
                  sheetRow(tr('Color'), tr('El archivo trae color por triángulo')),
              ],
              sheetRow(tr('Revisión'), '${r.milliseconds} ms'),
            ],
          ),
        );
      },
    ),
  );
}

/// Impresión: material, peso, filamento, cama y voladizos.
Future<void> showPrintSheet(BuildContext context, StlController c) {
  return datumSheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) {
        final fits = c.fits;
        final best = fits.first;
        final s = c.sizeMm;
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sheetTitle(tr('Impresión'), sub: Units.dims(s)),
              if (c.unitHint != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    c.unitHint!,
                    style: const TextStyle(color: DT.orangeSoft, fontSize: 13),
                  ),
                ),
              Wrap(
                spacing: 6,
                children: [
                  for (final u in [
                    LengthUnit.mm,
                    LengthUnit.cm,
                    LengthUnit.inch,
                    LengthUnit.m,
                  ])
                    ChoiceChip(
                      label: Text(tr('Archivo en {u}', {'u': u.symbol})),
                      selected: c.unit == u,
                      onSelected: (_) {
                        c.setUnit(u);
                        c.refreshOverlays();
                      },
                    ),
                ],
              ),
              sheetLabel(tr('MATERIAL Y PESO')),
              Wrap(
                spacing: 6,
                children: [
                  for (var i = 0; i < kPrintMaterials.length; i++)
                    ChoiceChip(
                      label: Text(tr(kPrintMaterials[i].$1)),
                      selected: c.material == i,
                      onSelected: (_) {
                        c.material = i;
                        c.refresh();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 10),
              sheetRow(tr('Volumen'), Units.volume(c.volumeCm3 * 1000)),
              sheetRow(tr('Superficie'), Units.area(c.areaCm2 * 100)),
              sheetRow(tr('Masa maciza'), Units.mass(c.solidGrams)),
              Row(
                children: [
                  Text(tr('Relleno'), style: const TextStyle(color: DT.muted)),
                  Expanded(
                    child: Slider(
                      value: c.infill,
                      min: 0,
                      max: 1,
                      divisions: 20,
                      label: '${(c.infill * 100).round()} %',
                      onChanged: (v) {
                        c.infill = v;
                        c.refresh();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${(c.infill * 100).round()} %',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              sheetRow(
                tr('Con ese relleno (estimación)'),
                Units.isImperial
                    ? tr('{m} · {l} ft de filamento 1,75 mm', {'m': Units.mass(c.estimatedGrams), 'l': Units.fmt(c.filamentMeters * 1000 / kMmPerInch / 12, d: 1)})
                    : tr('{m} · {l} m de filamento 1,75 mm', {'m': Units.mass(c.estimatedGrams), 'l': fmtNum(c.filamentMeters, d: 1)}),
              ),
              Text(
                Units.isImperial
                    ? tr('Estimación con paredes de {w}; el laminador dará la cifra exacta.', {'w': Units.mm(1.2)})
                    : tr('Estimación con paredes de 1,2 mm; el laminador dará la cifra exacta.'),
                style: const TextStyle(color: DT.muted, fontSize: 11.5),
              ),
              sheetLabel(tr('¿CABE EN MI IMPRESORA?')),
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (var i = 0; i < kBeds.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(kBeds[i].name),
                          selected: c.bed == i,
                          onSelected: (_) {
                            c.bed = i;
                            c.refreshOverlays();
                            c.refresh();
                          },
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    best.fits
                        ? Icons.check_circle_rounded
                        : Icons.cancel_rounded,
                    color: best.fits ? DT.mint : DT.orangeSoft,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      best.fits
                          ? (best.label == tr('Tal como está')
                                ? Units.tru('Cabe tal como está ({x} × {y} × {z} mm)', {'x': Units.number(c.bedPreset.x, d: 0), 'y': Units.number(c.bedPreset.y, d: 0), 'z': Units.number(c.bedPreset.z, d: 0)})
                                : Units.tru('Cabe {l} ({x} × {y} × {z} mm)', {'l': best.label.toLowerCase(), 'x': Units.number(c.bedPreset.x, d: 0), 'y': Units.number(c.bedPreset.y, d: 0), 'z': Units.number(c.bedPreset.z, d: 0)}))
                          : Units.tru('No cabe: sobran {o} mm incluso {l}.', {'o': Units.number(best.overflow), 'l': best.label.toLowerCase()}),
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: best.fits ? DT.mint : DT.orangeSoft,
                      ),
                    ),
                  ),
                  Switch(
                    value: c.showBed,
                    onChanged: (v) {
                      c.showBed = v;
                      c.refreshOverlays();
                      c.refresh();
                    },
                  ),
                ],
              ),
              sheetLabel(tr('MEJOR ORIENTACIÓN PARA IMPRIMIR')),
              ..._orientationRows(c),
              sheetLabel(tr('VOLADIZOS')),
              Row(
                children: [
                  Text(
                    tr('Ángulo máximo'),
                    style: const TextStyle(color: DT.muted),
                  ),
                  Expanded(
                    child: Slider(
                      value: c.overhangDeg,
                      min: 20,
                      max: 70,
                      divisions: 10,
                      label: '${c.overhangDeg.round()}°',
                      onChanged: c.setOverhangAngle,
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${c.overhangDeg.round()}°',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      c.overhangView && !c.overhangBusy
                          ? Units.tru('Naranja: necesita soporte ({a} cm²) · verde: apoyo en la cama ({b} cm²)', {'a': Units.areaCm2N(c.overhangArea), 'b': Units.areaCm2N(c.baseArea)})
                          : tr('Colorea las caras que miran hacia abajo más allá de ese ángulo.'),
                      style: const TextStyle(color: DT.muted, fontSize: 12.5),
                    ),
                  ),
                  Switch(
                    value: c.overhangView,
                    onChanged: (_) => c.toggleOverhang(),
                  ),
                ],
              ),
              sheetLabel(tr('ESPESOR DE PARED')),
              Row(
                children: [
                  Text(tr('Mínimo deseado'), style: const TextStyle(color: DT.muted)),
                  Expanded(
                    child: Slider(
                      value: c.thicknessMm,
                      min: 0.2,
                      max: 3,
                      divisions: 28,
                      label: Units.mm(c.thicknessMm),
                      onChanged: c.setThicknessMm,
                    ),
                  ),
                  SizedBox(
                    width: 60,
                    child: Text(
                      Units.mm(c.thicknessMm),
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      c.thicknessBusy
                          ? tr('Midiendo desde cada cara hacia dentro…')
                          : (c.thicknessView && c.thickness != null && c.measuredArea > 0
                                ? Units.tru('Pared más fina: {t} mm · rojo: por debajo ({a} % de la superficie) · amarillo: justo ({b} %)', {
                                        't': Units.number(c.thickness!.minThickness * c.scale, d: 2),
                                        'a': fmtNum(c.thinArea / c.measuredArea * 100, d: 1),
                                        'b': fmtNum(c.warnArea / c.measuredArea * 100, d: 1),
                                      }) +
                                      (c.thickness!.sampled ? tr(' · medido en una muestra de {n} caras', {'n': c.thickness!.measured}) : '')
                                : tr('Lanza un rayo hacia dentro desde cada cara y mide hasta la pared de enfrente.')),
                      style: const TextStyle(color: DT.muted, fontSize: 12.5),
                    ),
                  ),
                  Switch(
                    value: c.thicknessView,
                    onChanged: c.thicknessBusy ? null : (_) => c.toggleThickness(),
                  ),
                ],
              ),
              sheetLabel(tr('AUTOINTERSECCIONES')),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      c.selfIntBusy
                          ? tr('Buscando caras que se atraviesan…')
                          : c.selfInt == null
                              ? tr('Busca pares de caras que se cruzan sin compartir vértices (piezas solapadas, mallas mal unidas).')
                              : c.selfInt!.pairs == 0
                                  ? tr('Ninguna: no hay caras que se atraviesen.')
                                  : (c.selfInt!.truncated
                                        ? Units.tru('Más de {n} pares de caras se atraviesan. Primera zona: x {x}, y {y}, z {z} mm.', {'n': c.selfInt!.pairs, 'x': Units.number(c.selfInt!.at[0] * c.scale), 'y': Units.number(c.selfInt!.at[1] * c.scale), 'z': Units.number(c.selfInt!.at[2] * c.scale)})
                                        : Units.tru('{n} pares de caras se atraviesan. Primera zona: x {x}, y {y}, z {z} mm.', {'n': c.selfInt!.pairs, 'x': Units.number(c.selfInt!.at[0] * c.scale), 'y': Units.number(c.selfInt!.at[1] * c.scale), 'z': Units.number(c.selfInt!.at[2] * c.scale)})),
                      style: const TextStyle(color: DT.muted, fontSize: 12.5),
                    ),
                  ),
                  TextButton(
                    onPressed: c.selfIntBusy ? null : c.findSelfInt,
                    child: Text(c.selfInt == null ? tr('Buscar') : tr('Repetir')),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// Plano de sección sobre un eje.
Future<void> showMeshSectionSheet(BuildContext context, StlController c) {
  return datumSheet(
    context,
    ListenableBuilder(
      listenable: c,
      builder: (ctx, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          sheetTitle(
            tr('Sección'),
            sub: tr('Corta la malla con un plano para ver el interior'),
          ),
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
            Slider(
              value: c.sectionT,
              onChanged: (v) => c.setSection(c.sectionAxis, t: v),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () =>
                    c.setSection(c.sectionAxis, flip: !c.sectionFlip),
                child: Text(tr('Invertir lado')),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

/// Simplificación por agrupación de vértices: cada celda de una rejilla se convierte en un
/// vértice y se descartan los triángulos que colapsan. Devuelve 6 floats por vértice.
Float32List decimateMesh(
  Float32List v,
  List<double> mn,
  List<double> mx,
  int targetTriangles,
) {
  final n = (math.sqrt(targetTriangles / 2)).clamp(16, 2000).round();
  final sx = (mx[0] - mn[0]) / n,
      sy = (mx[1] - mn[1]) / n,
      sz = (mx[2] - mn[2]) / n;
  final ix = sx > 0 ? 1 / sx : 0.0,
      iy = sy > 0 ? 1 / sy : 0.0,
      iz = sz > 0 ? 1 / sz : 0.0;
  final ids = <int, int>{};
  final px = <double>[], py = <double>[], pz = <double>[], cnt = <int>[];
  final tri = Int32List(v.length ~/ 6);
  for (var i = 0; i < tri.length; i++) {
    final o = i * 6;
    final qx = ((v[o] - mn[0]) * ix).floor().clamp(0, n),
        qy = ((v[o + 1] - mn[1]) * iy).floor().clamp(0, n),
        qz = ((v[o + 2] - mn[2]) * iz).floor().clamp(0, n);
    final key = (qx * (n + 1) + qy) * (n + 1) + qz;
    var id = ids[key];
    if (id == null) {
      id = px.length;
      ids[key] = id;
      px.add(0);
      py.add(0);
      pz.add(0);
      cnt.add(0);
    }
    px[id] += v[o];
    py[id] += v[o + 1];
    pz[id] += v[o + 2];
    cnt[id]++;
    tri[i] = id;
  }
  final out = <double>[];
  for (var t = 0; t + 2 < tri.length; t += 3) {
    final a = tri[t], b = tri[t + 1], c = tri[t + 2];
    if (a == b || b == c || a == c) continue;
    final ax = px[a] / cnt[a], ay = py[a] / cnt[a], az = pz[a] / cnt[a];
    final bx = px[b] / cnt[b], by = py[b] / cnt[b], bz = pz[b] / cnt[b];
    final cx = px[c] / cnt[c], cy = py[c] / cnt[c], cz = pz[c] / cnt[c];
    final ux = bx - ax, uy = by - ay, uz = bz - az;
    final wx = cx - ax, wy = cy - ay, wz = cz - az;
    var nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
    final l = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l == 0) continue;
    nx /= l;
    ny /= l;
    nz /= l;
    out.addAll([
      ax,
      ay,
      az,
      nx,
      ny,
      nz,
      bx,
      by,
      bz,
      nx,
      ny,
      nz,
      cx,
      cy,
      cz,
      nx,
      ny,
      nz,
    ]);
  }
  return Float32List.fromList(out);
}

/// Seis formas de apoyar la pieza, de menos a más voladizos (comparadas con la actual).
List<Widget> _orientationRows(StlController c) {
  if (c.orientations.isEmpty) {
    return [Text(tr('Calculando…'), style: const TextStyle(color: DT.muted))];
  }
  // La orientación actual: apoyada sobre la cara −Z.
  final cur = c.orientations.firstWhere((o) => o.axis == 2 && o.sign == -1);
  final sorted = [...c.orientations]
    ..sort((a, b) => a.overhangMm2.compareTo(b.overhangMm2));
  final out = <Widget>[];
  for (final (i, o) in sorted.take(3).indexed) {
    final isCur = identical(o, cur);
    final delta = cur.overhangMm2 > 0
        ? ((o.overhangMm2 - cur.overhangMm2) / cur.overhangMm2 * 100)
        : 0.0;
    out.add(
      sheetRow(
        '${i == 0 ? '★ ' : ''}${isCur ? tr('{l} (actual)', {'l': o.label}) : o.label}',
        Units.tru('{a} cm² de voladizo', {'a': Units.areaCm2N(o.overhangMm2 / 100)}) +
            (!isCur && cur.overhangMm2 > 0 ? ' (${delta >= 0 ? '+' : '−'}${delta.abs().round()} %)' : '') +
            Units.tru(' · alto {h} mm', {'h': Units.number(o.heightMm, d: 0)}),
        color: i == 0 ? DT.mint : null,
      ),
    );
  }
  out.add(
    Text(
      tr('Solo se comparan las seis caras de la caja envolvente.'),
      style: const TextStyle(color: DT.muted, fontSize: 11.5),
    ),
  );
  return out;
}
