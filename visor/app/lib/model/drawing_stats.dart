import 'dart:math' as math;
import 'dart:typed_data';

import '../l10n/l10n.dart';
import 'lines.dart';
import 'shapes.dart';

/// Un contorno de corte: uno o varios tramos unidos por sus extremos.
class Contour {
  Contour(this.parts, this.closed, this.group, {this.polyOnly = false});

  /// La longitud se calcula de `poly` (contorno partido en una repetición).
  final bool polyOnly;
  final List<Shape> parts;
  final bool closed;
  final int group;

  /// Puntos x,y,x,y… del contorno completo (para contención y resaltado).
  Float64List poly = Float64List(0);
  double length = 0;
  double area = 0;
  double minX = 0, minY = 0, maxX = 0, maxY = 0;

  /// Un contorno cerrado contenido en otro (de profundidad impar) es un agujero.
  bool isHole = false;
  int holes = 0;
}

/// Un problema que conviene revisar antes de cortar.
class DrawingProblem {
  DrawingProblem(
    this.kind,
    this.text,
    this.poly, {
    this.asSegments = false,
    this.value = 0,
    this.isGap = false,
  });

  /// Hueco (en unidades del dibujo) o longitud del contorno abierto.
  final double value;
  final bool isGap;

  /// Si es cierto, `poly` son pares de puntos independientes (segmentos) y no una polilínea.
  final bool asSegments;
  final ProblemKind kind;
  final String text;

  /// Lo que se resalta en el plano: x,y,x,y… (una polilínea).
  final Float64List poly;
}

enum ProblemKind { open, duplicate, tiny, unit, incomplete }

/// ¿La capa lleva geometría de corte? Se descartan cotas, textos, ejes, plegados y construcción.
bool isCutLayer(String name) => !RegExp(
  r'(dim|cota|acot|text|nota|note|constr|axis|eje|center|centro|bend|plieg|plegad|doblez|fold|hatch|achur|relleno|sheet|stock|plancha|title|marco|border|defpoints|grid|malla|viaje|travel)',
  caseSensitive: false,
).hasMatch(name);

class LayerStats {
  LayerStats(this.name);
  final String name;
  int outer = 0, holes = 0, open = 0, segments = 0;
  double length = 0;
  int get contours => outer + holes + open;
  int get pierces => contours;
}

/// Resultado del análisis de un dibujo para corte.
class DrawingAnalysis {
  DrawingAnalysis(this.contours, this.layers, this.problems, this.bounds);
  final List<Contour> contours;
  final Map<String, LayerStats> layers;
  final List<DrawingProblem> problems;
  final List<double> bounds; // minX, minY, maxX, maxY

  /// Totales de las capas incluidas.
  (int outer, int holes, int open, double length, double netArea, int distinct)
  totals(Set<String> included, List<LineGroup> groups) {
    var o = 0, h = 0, op = 0;
    var len = 0.0, net = 0.0;
    final sig = <String>{};
    for (final c in contours) {
      final name = groups.isEmpty ? '' : groups[c.group].name;
      if (!included.contains(name)) continue;
      len += c.length;
      if (!c.closed) {
        op++;
      } else if (c.isHole) {
        h++;
        net -= c.area;
      } else {
        o++;
        net += c.area;
        sig.add(
          '${c.area.toStringAsFixed(1)}|${c.length.toStringAsFixed(1)}|${c.holes}',
        );
      }
    }
    return (o, h, op, len, net, sig.length);
  }
}

double _d2(double ax, double ay, double bx, double by) =>
    (ax - bx) * (ax - bx) + (ay - by) * (ay - by);

/// Une tramos sueltos en contornos, los clasifica y busca problemas.
DrawingAnalysis analyzeDrawing(
  List<Shape> shapes,
  LineSet lines, {
  bool Function(String layer)? isCut,
}) {
  final cut = isCut ?? isCutLayer;
  final b = lines.bounds;
  final extent = math
      .max(b.max[0] - b.min[0], b.max[1] - b.min[1])
      .clamp(1e-9, double.infinity);
  final tol = extent * 2e-6;
  final groups = lines.groups;
  final contours = <Contour>[];

  // --- 1) Tramos cerrados ya forman un contorno; los abiertos se unen por sus extremos.
  final open = <Shape>[];
  for (final s in shapes) {
    if (s.closed) {
      contours.add(Contour([s], true, s.group));
    } else {
      open.add(s);
    }
  }
  final used = List<bool>.filled(open.length, false);
  final grid =
      <(int, int), List<(int, bool)>>{}; // (celda) -> (tramo, ¿es el final?)
  (int, int) cell(double x, double y) =>
      ((x / (tol * 4)).floor(), (y / (tol * 4)).floor());
  for (var i = 0; i < open.length; i++) {
    final p = open[i].pts;
    final n = open[i].pointCount;
    (grid[cell(p[0], p[1])] ??= []).add((i, false));
    (grid[cell(p[(n - 1) * 2], p[(n - 1) * 2 + 1])] ??= []).add((i, true));
  }
  // Extremo libre más cercano (dentro de tol) de otro tramo de la misma capa.
  (int, bool)? neighbour(double x, double y, int group, int self) {
    final c = cell(x, y);
    (int, bool)? best;
    var bd = tol * tol * 16;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final e in grid[(c.$1 + dx, c.$2 + dy)] ?? const <(int, bool)>[]) {
          if (e.$1 == self || used[e.$1] || open[e.$1].group != group) continue;
          final q = open[e.$1].pts;
          final n = open[e.$1].pointCount;
          final qx = e.$2 ? q[(n - 1) * 2] : q[0];
          final qy = e.$2 ? q[(n - 1) * 2 + 1] : q[1];
          final d = _d2(x, y, qx, qy);
          if (d <= bd) {
            bd = d;
            best = e;
          }
        }
      }
    }
    return best;
  }

  for (var i = 0; i < open.length; i++) {
    if (used[i]) continue;
    used[i] = true;
    final chain = <Shape>[open[i]];
    final pts = <double>[...open[i].pts];
    // Hacia el final.
    for (var guard = 0; guard < 100000; guard++) {
      final x = pts[pts.length - 2], y = pts[pts.length - 1];
      final nb = neighbour(x, y, open[i].group, -1);
      if (nb == null) break;
      used[nb.$1] = true;
      final s = open[nb.$1];
      chain.add(s);
      final seg = nb.$2 ? _reversed(s.pts) : s.pts;
      pts.addAll(seg.sublist(2));
    }
    // Hacia el principio.
    for (var guard = 0; guard < 100000; guard++) {
      final x = pts[0], y = pts[1];
      final nb = neighbour(x, y, open[i].group, -1);
      if (nb == null) break;
      used[nb.$1] = true;
      final s = open[nb.$1];
      chain.insert(0, s);
      final seg = nb.$2 ? s.pts : _reversed(s.pts);
      pts.insertAll(0, seg.sublist(0, seg.length - 2));
    }
    // Si la cadena vuelve a su punto de partida antes del final, hay un lazo cerrado
    // y un resto (normalmente una línea repetida).
    int? back;
    for (var k = 2; k < pts.length ~/ 2 - 1; k++) {
      if (_d2(pts[0], pts[1], pts[k * 2], pts[k * 2 + 1]) <= tol * tol * 16) {
        back = k;
        break;
      }
    }
    if (back != null) {
      contours.add(
        Contour(chain, true, open[i].group, polyOnly: true)
          ..poly = Float64List.fromList(pts.sublist(0, back * 2 + 2)),
      );
      contours.add(
        Contour(const [], false, open[i].group, polyOnly: true)
          ..poly = Float64List.fromList(pts.sublist(back * 2)),
      );
      continue;
    }
    final closed = chain.length > 1 || open[i].pointCount > 2
        ? _d2(pts[0], pts[1], pts[pts.length - 2], pts[pts.length - 1]) <=
              tol * tol * 16
        : false;
    final c = Contour(chain, closed, open[i].group)
      ..poly = Float64List.fromList(pts);
    contours.add(c);
  }

  // --- 2) Longitud (con arcos y círculos exactos), área y caja de cada contorno.
  for (final c in contours) {
    if (c.parts.length == 1 && c.parts.first.closed) {
      final s = c.parts.first;
      c.poly = s.pts;
      c.length = s.length;
      c.area = s.area;
    } else {
      var len = 0.0;
      if (c.polyOnly) {
        for (var i = 0; i + 3 < c.poly.length; i += 2) {
          len += math.sqrt(
            _d2(c.poly[i], c.poly[i + 1], c.poly[i + 2], c.poly[i + 3]),
          );
        }
      } else {
        for (final s in c.parts) {
          len += s.length;
        }
      }
      c.length = len;
      if (c.closed) {
        var a = 0.0;
        final n = c.poly.length ~/ 2;
        for (var i = 0; i < n; i++) {
          final j = (i + 1) % n;
          a +=
              c.poly[i * 2] * c.poly[j * 2 + 1] -
              c.poly[j * 2] * c.poly[i * 2 + 1];
        }
        c.area = a.abs() / 2;
      }
    }
    var mnx = double.infinity, mny = double.infinity;
    var mxx = -double.infinity, mxy = -double.infinity;
    for (var i = 0; i < c.poly.length; i += 2) {
      mnx = math.min(mnx, c.poly[i]);
      mxx = math.max(mxx, c.poly[i]);
      mny = math.min(mny, c.poly[i + 1]);
      mxy = math.max(mxy, c.poly[i + 1]);
    }
    c.minX = mnx;
    c.maxX = mxx;
    c.minY = mny;
    c.maxY = mxy;
  }

  // --- 3) Exterior o agujero por profundidad de contención.
  // Solo las capas de corte forman la jerarquía pieza/agujero (la chapa o las cotas no cuentan).
  final closedList = [
    for (final c in contours)
      if (c.closed && (groups.isEmpty || cut(groups[c.group].name))) c,
  ];
  closedList.sort((a, b) => b.area.compareTo(a.area));
  bool inside(Contour inner, Contour outer) {
    if (inner.minX < outer.minX - tol ||
        inner.maxX > outer.maxX + tol ||
        inner.minY < outer.minY - tol ||
        inner.maxY > outer.maxY + tol) {
      return false;
    }
    // Un punto de la figura interior (el primero) dentro del polígono exterior.
    final px = inner.poly[0], py = inner.poly[1];
    var ins = false;
    final n = outer.poly.length ~/ 2;
    for (var i = 0, j = n - 1; i < n; j = i++) {
      final xi = outer.poly[i * 2], yi = outer.poly[i * 2 + 1];
      final xj = outer.poly[j * 2], yj = outer.poly[j * 2 + 1];
      if ((yi > py) != (yj > py) &&
          px < (xj - xi) * (py - yi) / (yj - yi) + xi) {
        ins = !ins;
      }
    }
    return ins;
  }

  // Índice espacial: cada contorno cerrado se anota en las celdas que cubre su caja.
  // Los muy grandes (la chapa) se guardan aparte y se comprueban siempre.
  final sizes = <double>[
    for (final c in closedList) math.max(c.maxX - c.minX, c.maxY - c.minY),
  ]..sort();
  final median = sizes.isEmpty ? extent : sizes[sizes.length ~/ 2];
  final cellSize = median.clamp(extent / 2000, extent / 8).toDouble() * 2;
  int cx(double x) => ((x - b.min[0]) / cellSize).floor();
  int cy(double y) => ((y - b.min[1]) / cellSize).floor();
  final cells = <(int, int), List<int>>{};
  final big = <int>[];
  for (var i = 0; i < closedList.length; i++) {
    final c = closedList[i];
    final x0 = cx(c.minX), x1 = cx(c.maxX), y0 = cy(c.minY), y1 = cy(c.maxY);
    if ((x1 - x0 + 1) * (y1 - y0 + 1) > 400) {
      big.add(i);
      continue;
    }
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        (cells[(x, y)] ??= []).add(i);
      }
    }
  }
  final depth = List<int>.filled(closedList.length, 0);
  final parent = List<int>.filled(closedList.length, -1);
  for (var i = 0; i < closedList.length; i++) {
    final c = closedList[i];
    final here = cells[(cx(c.poly[0]), cy(c.poly[1]))] ?? const <int>[];
    var best = -1;
    for (final list in [here, big]) {
      for (final j in list) {
        if (j >= i || closedList[j].area <= c.area) continue;
        if (best >= 0 && closedList[j].area >= closedList[best].area) continue;
        if (inside(c, closedList[j])) best = j;
      }
    }
    if (best >= 0) {
      parent[i] = best;
      depth[i] = depth[best] + 1;
    }
  }
  for (var i = 0; i < closedList.length; i++) {
    closedList[i].isHole = depth[i].isOdd;
    if (parent[i] >= 0 && depth[i].isOdd) closedList[parent[i]].holes++;
  }

  // --- 4) Estadísticas por capa.
  final layers = <String, LayerStats>{};
  for (final g in groups) {
    layers[g.name] = LayerStats(g.name);
  }
  for (final c in contours) {
    final name = groups.isEmpty ? '' : groups[c.group].name;
    final ls = layers.putIfAbsent(name, () => LayerStats(name));
    ls.length += c.length;
    if (!c.closed) {
      ls.open++;
    } else if (c.isHole) {
      ls.holes++;
    } else {
      ls.outer++;
    }
  }

  // --- 5) Problemas.
  final problems = <DrawingProblem>[];
  for (final c in contours) {
    if (c.closed) continue;
    if (c.poly.length < 4) continue;
    if (groups.isNotEmpty && !cut(groups[c.group].name)) continue;
    final x0 = c.poly[0], y0 = c.poly[1];
    final x1 = c.poly[c.poly.length - 2], y1 = c.poly[c.poly.length - 1];
    final gap = math.sqrt(_d2(x0, y0, x1, y1));
    final isGap = gap < extent * 0.02;
    problems.add(
      DrawingProblem(
        ProblemKind.open,
        isGap
            ? tr('Contorno abierto: falta cerrar un hueco de {d}', {'d': _fmt(gap)})
            : tr('Contorno abierto de {d} de longitud', {'d': _fmt(c.length)}),
        c.poly,
        value: isGap ? gap : c.length,
        isGap: isGap,
      ),
    );
  }
  _duplicates(lines, tol, extent, problems, cut);
  return DrawingAnalysis(contours, layers, problems, [
    b.min[0],
    b.min[1],
    b.max[0],
    b.max[1],
  ]);
}

String _fmt(double v) =>
    v.abs() >= 100 ? v.toStringAsFixed(1) : v.toStringAsFixed(3);

Float64List _reversed(Float64List p) {
  final n = p.length ~/ 2;
  final out = Float64List(p.length);
  for (var i = 0; i < n; i++) {
    out[i * 2] = p[(n - 1 - i) * 2];
    out[i * 2 + 1] = p[(n - 1 - i) * 2 + 1];
  }
  return out;
}

/// Segmentos repetidos (se cortarían dos veces) y segmentos diminutos.
void _duplicates(
  LineSet lines,
  double tol,
  double extent,
  List<DrawingProblem> out,
  bool Function(String) cut,
) {
  const f = LineSet.floatsPerVertex;
  final v = lines.vertices;
  final seen = <String>{};
  var dups = 0, tiny = 0;
  final dupMarks = <double>[];
  final tinyMarks = <double>[];
  final q = tol * 20;
  final tinyLen = extent * 1e-5;
  final groups = lines.groups.isEmpty
      ? [LineGroup('', 0, lines.vertexCount)]
      : lines.groups;
  for (final g in groups) {
    if (lines.groups.isNotEmpty && !cut(g.name)) continue;
    for (var s = g.firstVertex; s + 1 < g.firstVertex + g.vertexCount; s += 2) {
      final a = s * f, b = (s + 1) * f;
      final ax = v[a].toDouble(), ay = v[a + 1].toDouble();
      final bx = v[b].toDouble(), by = v[b + 1].toDouble();
      final len2 = _d2(ax, ay, bx, by);
      if (len2 < tinyLen * tinyLen) {
        tiny++;
        if (tinyMarks.length < 40) tinyMarks.addAll([ax, ay, bx, by]);
        continue;
      }
      final k1 = '${(ax / q).round()},${(ay / q).round()}';
      final k2 = '${(bx / q).round()},${(by / q).round()}';
      final key = k1.compareTo(k2) <= 0 ? '$k1|$k2' : '$k2|$k1';
      if (!seen.add(key)) {
        dups++;
        if (dupMarks.length < 200) dupMarks.addAll([ax, ay, bx, by]);
      }
    }
  }
  if (dups > 0) {
    out.add(
      DrawingProblem(
        ProblemKind.duplicate,
        dups == 1
            ? tr('1 línea repetida: se cortarían dos veces')
            : tr('{n} líneas repetidas: se cortarían dos veces', {'n': dups}),
        Float64List.fromList(dupMarks),
        asSegments: true,
      ),
    );
  }
  if (tiny > 0) {
    out.add(
      DrawingProblem(
        ProblemKind.tiny,
        tiny == 1
            ? tr('1 segmento diminuto: suelen ser restos de edición')
            : tr('{n} segmentos diminutos: suelen ser restos de edición', {'n': tiny}),
        Float64List.fromList(tinyMarks),
        asSegments: true,
      ),
    );
  }
}
