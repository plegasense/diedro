import 'dart:math' as math;
import 'dart:typed_data';

import '../l10n/l10n.dart';
import 'mesh.dart';
import 'print_summary.dart';
import 'scene.dart';
import 'toolpath.dart';

/// Diámetro (mm) que anuncia el comentario de una herramienta: «T2 FRESA D12», «Ø6», «1/4" endmill»…
double? toolDiameterFromComment(String? c) {
  if (c == null) return null;
  final s = c.replaceAll(',', '.');
  final d = RegExp(
    r'(?:\bD|Ø|⌀|dia(?:m(?:eter)?)?\.?)\s*=?\s*(\d+(?:\.\d+)?)',
    caseSensitive: false,
  ).firstMatch(s);
  if (d != null) return double.parse(d.group(1)!);
  final mm = RegExp(
    r'(\d+(?:\.\d+)?)\s*mm',
    caseSensitive: false,
  ).firstMatch(s);
  if (mm != null) return double.parse(mm.group(1)!);
  final frac = RegExp(r'(\d+)\s*/\s*(\d+)\s*(?:"|in|inch|pulg)?').firstMatch(s);
  if (frac != null && int.parse(frac.group(2)!) > 0) {
    return int.parse(frac.group(1)!) / int.parse(frac.group(2)!) * 25.4;
  }
  final inch = RegExp(r'(\d*\.\d+)\s*(?:"|in\b|inch)').firstMatch(s);
  if (inch != null) return double.parse(inch.group(1)!) * 25.4;
  return null;
}

bool toolIsBall(String? c) =>
    c != null &&
    RegExp(
      r'ball|bola|esf|\bbn\b|round nose',
      caseSensitive: false,
    ).hasMatch(c);

/// Simulación 2,5D de la pieza en bruto: un mapa de alturas que se va tallando con la fresa.
class StockSim {
  StockSim(this.t, {double defaultDiameter = 6}) {
    final b = t.paths.bounds;
    final cnc = t.stats.cnc;
    for (final e in cnc?.tools ?? <CncTool>[]) {
      diameter.putIfAbsent(
        e.number,
        () => toolDiameterFromComment(e.comment) ?? defaultDiameter,
      );
      if (toolIsBall(e.comment)) ball.add(e.number);
    }
    this.defaultDiameter = defaultDiameter;
    final rmax =
        math.max(defaultDiameter, diameter.values.fold(0.0, math.max)) / 2;
    x0 = b.min[0] - rmax;
    y0 = b.min[1] - rmax;
    final ex = b.max[0] - b.min[0] + 2 * rmax,
        ey = b.max[1] - b.min[1] + 2 * rmax;
    cell = math.max(math.max(ex, ey) / 170, 0.05);
    nx = (ex / cell).ceil() + 1;
    ny = (ey / cell).ceil() + 1;
    // Cara superior: la mayor altura de los tramos que avanzan en horizontal (las bajadas
    // desde el plano de seguridad no cuentan).
    var hz = double.negativeInfinity;
    final pv = t.paths.vertices;
    for (var i = 0; i < t.paths.segmentCount; i++) {
      final o = i * 12;
      final dxy = (pv[o + 6] - pv[o]).abs() + (pv[o + 7] - pv[o + 1]).abs();
      if (dxy > 1e-6) hz = math.max(hz, math.max(pv[o + 2], pv[o + 8]));
    }
    zTop = hz.isInfinite ? (b.min[2] < 0 ? 0.0 : b.max[2]) : math.max(0.0, hz);
    zBottom = b.min[2] - math.max(1.0, 0.2 * (zTop - b.min[2]));
    h = Float32List(nx * ny)..fillRange(0, nx * ny, zTop);
  }

  final Toolpath t;
  final Map<int, double> diameter = {};
  final Set<int> ball = {};

  /// Herramientas cuyo diámetro no consta en el archivo (se supone o lo fija el usuario).
  final Set<int> assumed = {};
  late final double defaultDiameter;
  late final double x0, y0, cell, zTop, zBottom;
  late final int nx, ny;
  late Float32List h;
  int applied = 0;
  final Map<int, List<(int, int, double)>> _disk = {};

  /// Profundidad máxima de corte respecto a la cara superior.
  double get depth => zTop - t.paths.bounds.min[2];

  double diameterOf(int tool) => diameter[tool] ?? defaultDiameter;

  /// Cambia el diámetro de una herramienta y reinicia la simulación.
  void setDiameter(int tool, double d) {
    diameter[tool] = d;
    assumed.add(tool);
    _disk.remove(tool);
    reset();
  }

  void reset() {
    h.fillRange(0, h.length, zTop);
    applied = 0;
  }

  List<(int, int, double)> _offsets(int tool) {
    return _disk[tool] ??= () {
      final r = diameterOf(tool) / 2;
      final rc = (r / cell).ceil();
      final out = <(int, int, double)>[];
      final isBall = ball.contains(tool);
      for (var j = -rc; j <= rc; j++) {
        for (var i = -rc; i <= rc; i++) {
          final d2 = (i * i + j * j) * cell * cell;
          if (d2 > r * r) continue;
          out.add((
            i,
            j,
            isBall ? r - math.sqrt(math.max(0, r * r - d2)) : 0.0,
          ));
        }
      }
      if (out.isEmpty) out.add((0, 0, 0.0));
      return out;
    }();
  }

  void _stamp(int tool, double x, double y, double z) {
    if (z >= zTop) return;
    final ci = ((x - x0) / cell).round(), cj = ((y - y0) / cell).round();
    for (final (di, dj, dz) in _offsets(tool)) {
      final i = ci + di, j = cj + dj;
      if (i < 0 || j < 0 || i >= nx || j >= ny) continue;
      final zz = z + dz;
      final k = j * nx + i;
      if (zz < h[k]) h[k] = zz;
    }
  }

  /// Aplica los movimientos de trabajo hasta el [seg]-ésimo (rebobina si hace falta).
  void advanceTo(int seg) {
    if (seg < applied) reset();
    final v = t.paths.vertices;
    final total = t.paths.segmentCount;
    seg = seg.clamp(0, total);
    while (applied < seg) {
      final o = applied * 12;
      final tool = t.tool[applied];
      final ax = v[o], ay = v[o + 1], az = v[o + 2];
      final bx = v[o + 6], by = v[o + 7], bz = v[o + 8];
      var ox = 0.0, oy = 0.0;
      final comp = t.stats.segComp;
      final dx = bx - ax, dy = by - ay;
      final len = math.sqrt(dx * dx + dy * dy);
      if (comp != null && comp[applied] != 0 && len > 1e-9) {
        // La fresa va a un lado del trazado programado, a un radio de distancia.
        final r = diameterOf(tool) / 2 * comp[applied];
        ox = -dy / len * r;
        oy = dx / len * r;
      }
      final n = math.max(1, (len / (cell * 0.7)).ceil());
      for (var k = 0; k <= n; k++) {
        final u = k / n;
        _stamp(tool, ax + dx * u + ox, ay + dy * u + oy, az + (bz - az) * u);
      }
      applied++;
    }
  }

  static const _bandColors = [
    0xFFD8C7A8, // sin tallar
    0xFFC29B63,
    0xFFA67C48,
    0xFF86602F,
    0xFF664620,
    0xFF4A3217,
  ];
  static const _wallColor = 0xFF9A8B74;

  /// Escena con la pieza en bruto: la superficie por bandas de profundidad y las paredes.
  Scene buildScene() {
    var minH = zTop;
    for (final x in h) {
      if (x < minH) minH = x;
    }
    final depth = math.max(1e-6, zTop - minH);

    int band(double a) {
      if (a >= zTop - 1e-5) return 0;
      return 1 + math.min(4, ((zTop - a) / depth * 5).floor());
    }

    double hAt(int i, int j) => h[j.clamp(0, ny - 1) * nx + i.clamp(0, nx - 1)];
    // Normales por vértice (diferencias centrales), calculadas una sola vez.
    final nor = Float32List(nx * ny * 3);
    for (var j = 0; j < ny; j++) {
      for (var i = 0; i < nx; i++) {
        final dx = (hAt(i + 1, j) - hAt(i - 1, j)) / (2 * cell);
        final dy = (hAt(i, j + 1) - hAt(i, j - 1)) / (2 * cell);
        final l = math.sqrt(dx * dx + dy * dy + 1);
        final k = (j * nx + i) * 3;
        nor[k] = -dx / l;
        nor[k + 1] = -dy / l;
        nor[k + 2] = 1 / l;
      }
    }

    final counts = List<int>.filled(6, 0);
    final bandOf = Uint8List((nx - 1) * (ny - 1) * 2);
    var q = 0;
    for (var j = 0; j < ny - 1; j++) {
      for (var i = 0; i < nx - 1; i++) {
        final a = h[j * nx + i],
            b = h[j * nx + i + 1],
            c = h[(j + 1) * nx + i + 1],
            d = h[(j + 1) * nx + i];
        final b1 = band((a + b + c) / 3), b2 = band((a + c + d) / 3);
        bandOf[q++] = b1;
        bandOf[q++] = b2;
        counts[b1]++;
        counts[b2]++;
      }
    }
    final arrays = [for (final c in counts) Float32List(c * 18)];
    final pos = List<int>.filled(6, 0);
    void put(int bd, int i, int j) {
      final a = arrays[bd];
      final p = pos[bd];
      final k = j * nx + i;
      a[p] = x0 + i * cell;
      a[p + 1] = y0 + j * cell;
      a[p + 2] = h[k];
      a[p + 3] = nor[k * 3];
      a[p + 4] = nor[k * 3 + 1];
      a[p + 5] = nor[k * 3 + 2];
      pos[bd] = p + 6;
    }

    q = 0;
    for (var j = 0; j < ny - 1; j++) {
      for (var i = 0; i < nx - 1; i++) {
        final b1 = bandOf[q++], b2 = bandOf[q++];
        put(b1, i, j);
        put(b1, i + 1, j);
        put(b1, i + 1, j + 1);
        put(b2, i, j);
        put(b2, i + 1, j + 1);
        put(b2, i, j + 1);
      }
    }

    // Paredes del bloque.
    final wall = <double>[];
    void quad(
      double ax,
      double ay,
      double bx,
      double by,
      double za,
      double zb,
      List<double> n,
      double zbot,
    ) {
      void v(double x, double y, double z) =>
          wall.addAll([x, y, z, n[0], n[1], n[2]]);
      v(ax, ay, za);
      v(bx, by, zb);
      v(bx, by, zbot);
      v(ax, ay, za);
      v(bx, by, zbot);
      v(ax, ay, zbot);
    }

    for (var i = 0; i < nx - 1; i++) {
      final x = x0 + i * cell;
      quad(x + cell, y0, x, y0, hAt(i + 1, 0), hAt(i, 0), [0, -1, 0], zBottom);
      final yt = y0 + (ny - 1) * cell;
      quad(x, yt, x + cell, yt, hAt(i, ny - 1), hAt(i + 1, ny - 1), [
        0,
        1,
        0,
      ], zBottom);
    }
    for (var j = 0; j < ny - 1; j++) {
      final y = y0 + j * cell;
      quad(x0, y, x0, y + cell, hAt(0, j), hAt(0, j + 1), [-1, 0, 0], zBottom);
      final xr = x0 + (nx - 1) * cell;
      quad(xr, y + cell, xr, y, hAt(nx - 1, j + 1), hAt(nx - 1, j), [
        1,
        0,
        0,
      ], zBottom);
    }

    final bounds = Bounds(
      [x0, y0, zBottom],
      [x0 + (nx - 1) * cell, y0 + (ny - 1) * cell, zTop],
    );
    final parts = <Part>[];
    for (var b = 0; b < 6; b++) {
      if (counts[b] == 0) continue;
      parts.add(
        Part(
          id: b,
          name: tr('banda {b}', {'b': b}),
          mesh: Mesh(vertices: arrays[b], bounds: bounds),
          color: _bandColors[b],
        ),
      );
    }
    if (wall.isNotEmpty) {
      parts.add(
        Part(
          id: 9,
          name: tr('paredes'),
          mesh: Mesh(vertices: Float32List.fromList(wall), bounds: bounds),
          color: _wallColor,
        ),
      );
    }
    final root = SceneNode(
      name: tr('bruto'),
      children: [for (final p in parts) SceneNode(name: p.name, part: p)],
    );
    return Scene(name: tr('bruto'), root: root, parts: parts);
  }
}
