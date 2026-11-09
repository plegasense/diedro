// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:math' as math;
import 'dart:typed_data';

import 'lines.dart';

enum ShapeKind { line, circle, arc, rectangle, polygon, polyline }

/// Figura reconocida en un dibujo 2D: una cadena de segmentos conectados.
class Shape {
  Shape(this.kind, this.group, this.pts, {required this.closed});
  final ShapeKind kind;

  /// Índice de la capa (LineGroup) a la que pertenece.
  final int group;

  /// Puntos x,y,x,y… de la cadena.
  final Float64List pts;
  final bool closed;

  double cx = 0, cy = 0, radius = 0, sweep = 0;
  double minX = 0, minY = 0, maxX = 0, maxY = 0;

  int get pointCount => pts.length ~/ 2;

  double get length {
    switch (kind) {
      case ShapeKind.circle:
        return 2 * math.pi * radius;
      case ShapeKind.arc:
        return radius * sweep;
      default:
        var s = 0.0;
        for (var i = 0; i + 1 < pointCount; i++) {
          s += math.sqrt(
            _d2(pts[i * 2], pts[i * 2 + 1], pts[i * 2 + 2], pts[i * 2 + 3]),
          );
        }
        return s;
    }
  }

  /// Área de una figura cerrada (0 si es abierta).
  double get area {
    if (!closed) return 0;
    if (kind == ShapeKind.circle) return math.pi * radius * radius;
    var a = 0.0;
    final n = pointCount;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      a += pts[i * 2] * pts[j * 2 + 1] - pts[j * 2] * pts[i * 2 + 1];
    }
    return a.abs() / 2;
  }

  /// Puntos notables a los que se ajusta la medición.
  List<(double, double)> snapPoints() {
    final out = <(double, double)>[];
    final n = pointCount;
    switch (kind) {
      case ShapeKind.circle:
        out.add((cx, cy));
      case ShapeKind.arc:
        out
          ..add((cx, cy))
          ..add((pts[0], pts[1]))
          ..add((pts[(n - 1) * 2], pts[(n - 1) * 2 + 1]));
      case ShapeKind.line:
        out
          ..add((pts[0], pts[1]))
          ..add((pts[2], pts[3]))
          ..add(((pts[0] + pts[2]) / 2, (pts[1] + pts[3]) / 2));
      default:
        // Esquinas: vértices donde la dirección cambia de forma apreciable.
        final m = closed ? n - 1 : n;
        for (var i = 0; i < m; i++) {
          if (!closed && (i == 0 || i == m - 1)) {
            out.add((pts[i * 2], pts[i * 2 + 1]));
            continue;
          }
          final p = (i - 1 + m) % m, q = (i + 1) % m;
          final ax = pts[i * 2] - pts[p * 2],
              ay = pts[i * 2 + 1] - pts[p * 2 + 1];
          final bx = pts[q * 2] - pts[i * 2],
              by = pts[q * 2 + 1] - pts[i * 2 + 1];
          final la = math.sqrt(ax * ax + ay * ay),
              lb = math.sqrt(bx * bx + by * by);
          if (la < 1e-12 || lb < 1e-12) continue;
          final cos = (ax * bx + ay * by) / (la * lb);
          if (cos < 0.97) out.add((pts[i * 2], pts[i * 2 + 1]));
        }
    }
    return out;
  }

  /// Distancia mínima de un punto a la figura (a su contorno).
  double distanceTo(double x, double y) {
    var best = double.infinity;
    for (var i = 0; i + 1 < pointCount; i++) {
      final d = _segDist(
        x,
        y,
        pts[i * 2],
        pts[i * 2 + 1],
        pts[i * 2 + 2],
        pts[i * 2 + 3],
      );
      if (d < best) best = d;
    }
    return best;
  }

  bool contains(double x, double y) {
    if (!closed) return false;
    if (x < minX || x > maxX || y < minY || y > maxY) return false;
    var inside = false;
    final n = pointCount;
    for (var i = 0, j = n - 1; i < n; j = i++) {
      final xi = pts[i * 2],
          yi = pts[i * 2 + 1],
          xj = pts[j * 2],
          yj = pts[j * 2 + 1];
      if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }
}

double _d2(double ax, double ay, double bx, double by) =>
    (ax - bx) * (ax - bx) + (ay - by) * (ay - by);

double _segDist(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax, dy = by - ay;
  final l2 = dx * dx + dy * dy;
  var t = l2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / l2;
  t = t.clamp(0.0, 1.0);
  return math.sqrt(_d2(px, py, ax + dx * t, ay + dy * t));
}

/// Recorre los segmentos del dibujo y reconoce líneas, círculos, arcos,
/// rectángulos y contornos.
List<Shape> buildShapes(LineSet set) {
  final v = set.vertices;
  const f = LineSet.floatsPerVertex;
  final b = set.bounds;
  final extent = math
      .max(b.max[0] - b.min[0], b.max[1] - b.min[1])
      .clamp(1e-9, double.infinity);
  final eps = extent * 1e-6;
  final shapes = <Shape>[];

  void flush(List<double> chain, int group) {
    if (chain.length < 4) return;
    final n = chain.length ~/ 2;
    final closed =
        n > 2 &&
        _d2(chain[0], chain[1], chain[n * 2 - 2], chain[n * 2 - 1]) <=
            eps * eps * 4;
    final pts = Float64List.fromList(chain);
    shapes.add(_classify(pts, group, closed, extent));
  }

  final groups = set.groups.isEmpty
      ? [LineGroup('', 0, set.vertexCount)]
      : set.groups;
  for (var gi = 0; gi < groups.length; gi++) {
    final g = groups[gi];
    final chain = <double>[];
    for (var s = 0; s + 1 < g.vertexCount; s += 2) {
      final i0 = (g.firstVertex + s) * f, i1 = (g.firstVertex + s + 1) * f;
      final x0 = v[i0].toDouble(), y0 = v[i0 + 1].toDouble();
      final x1 = v[i1].toDouble(), y1 = v[i1 + 1].toDouble();
      if (chain.isNotEmpty &&
          _d2(chain[chain.length - 2], chain[chain.length - 1], x0, y0) >
              eps * eps) {
        flush(chain, gi);
        chain.clear();
      }
      if (chain.isEmpty) chain.addAll([x0, y0]);
      chain.addAll([x1, y1]);
    }
    flush(chain, gi);
  }
  return shapes;
}

Shape _classify(Float64List pts, int group, bool closed, double extent) {
  final n = pts.length ~/ 2;
  Shape make(ShapeKind k) {
    final s = Shape(k, group, pts, closed: closed);
    var mnx = double.infinity, mny = double.infinity;
    var mxx = -double.infinity, mxy = -double.infinity;
    for (var i = 0; i < n; i++) {
      mnx = math.min(mnx, pts[i * 2]);
      mxx = math.max(mxx, pts[i * 2]);
      mny = math.min(mny, pts[i * 2 + 1]);
      mxy = math.max(mxy, pts[i * 2 + 1]);
    }
    s.minX = mnx;
    s.maxX = mxx;
    s.minY = mny;
    s.maxY = mxy;
    return s;
  }

  if (n == 2) return make(ShapeKind.line);

  // ¿Es un círculo o un arco? Circunferencia por tres puntos y comprobación del resto.
  if (n >= 5) {
    final a = 0, bI = n ~/ 2, c = n - 1;
    final ax = pts[a * 2], ay = pts[a * 2 + 1];
    final bx = pts[bI * 2], by = pts[bI * 2 + 1];
    var cxp = pts[c * 2], cyp = pts[c * 2 + 1];
    // En un círculo cerrado el último punto coincide con el primero: se usa otro.
    if (closed) {
      final k = (n * 3) ~/ 4;
      cxp = pts[k * 2];
      cyp = pts[k * 2 + 1];
    }
    final d = 2 * (ax * (by - cyp) + bx * (cyp - ay) + cxp * (ay - by));
    if (d.abs() > 1e-12) {
      final ux =
          ((ax * ax + ay * ay) * (by - cyp) +
              (bx * bx + by * by) * (cyp - ay) +
              (cxp * cxp + cyp * cyp) * (ay - by)) /
          d;
      final uy =
          ((ax * ax + ay * ay) * (cxp - bx) +
              (bx * bx + by * by) * (ax - cxp) +
              (cxp * cxp + cyp * cyp) * (bx - ax)) /
          d;
      final r = math.sqrt(_d2(ux, uy, ax, ay));
      if (r > extent * 1e-6 && r < extent * 20) {
        var ok = true;
        final tol = math.max(r * 0.004, extent * 1e-6);
        for (var i = 0; i < n; i++) {
          if ((math.sqrt(_d2(ux, uy, pts[i * 2], pts[i * 2 + 1])) - r).abs() >
              tol) {
            ok = false;
            break;
          }
        }
        // Un polígono con pocos vértices (un rectángulo, un hexágono) también cabe en un círculo;
        // un arco teselado avanza en pasos angulares pequeños.
        if (ok) {
          var prevA = math.atan2(pts[1] - uy, pts[0] - ux);
          for (var i = 1; i < n && ok; i++) {
            final cur = math.atan2(pts[i * 2 + 1] - uy, pts[i * 2] - ux);
            var dlt = (cur - prevA).abs();
            if (dlt > math.pi) dlt = 2 * math.pi - dlt;
            if (dlt > 40 * math.pi / 180) ok = false;
            prevA = cur;
          }
        }
        if (ok) {
          // Barrido angular acumulado.
          var sweep = 0.0;
          var prev = math.atan2(pts[1] - uy, pts[0] - ux);
          for (var i = 1; i < n; i++) {
            final cur = math.atan2(pts[i * 2 + 1] - uy, pts[i * 2] - ux);
            var dlt = cur - prev;
            while (dlt > math.pi) {
              dlt -= 2 * math.pi;
            }
            while (dlt < -math.pi) {
              dlt += 2 * math.pi;
            }
            sweep += dlt;
            prev = cur;
          }
          sweep = sweep.abs();
          final full = closed && sweep > 2 * math.pi * 0.98;
          final s = make(full ? ShapeKind.circle : ShapeKind.arc)
            ..cx = ux
            ..cy = uy
            ..radius = r
            ..sweep = full ? 2 * math.pi : sweep;
          return s;
        }
      }
    }
  }

  // Rectángulo: cuatro esquinas y ángulos rectos.
  if (closed && n == 5) {
    var right = true;
    for (var i = 0; i < 4; i++) {
      final p = pts, j = (i + 1) % 4, k = (i + 2) % 4;
      final ax = p[j * 2] - p[i * 2], ay = p[j * 2 + 1] - p[i * 2 + 1];
      final bx = p[k * 2] - p[j * 2], by = p[k * 2 + 1] - p[j * 2 + 1];
      final la = math.sqrt(ax * ax + ay * ay),
          lb = math.sqrt(bx * bx + by * by);
      if (la < 1e-12 ||
          lb < 1e-12 ||
          (ax * bx + ay * by).abs() / (la * lb) > 0.01) {
        right = false;
        break;
      }
    }
    if (right) return make(ShapeKind.rectangle);
  }
  return make(closed ? ShapeKind.polygon : ShapeKind.polyline);
}
