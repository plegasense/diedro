// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:math' as math;
import 'dart:typed_data';

/// Un canal de animación: qué propiedad de qué nodo y sus fotogramas clave.
class RigChannel {
  RigChannel(this.node, this.path, this.interp, this.times, this.values);

  /// Nodo de glTF.
  final int node;

  /// 0 traslación, 1 rotación, 2 escala, 3 pesos de morfo.
  final int path;

  /// 0 lineal, 1 escalón, 2 spline cúbica.
  final int interp;
  final Float32List times;
  final Float32List values;
}

class RigAnimation {
  RigAnimation(this.name, this.duration, this.channels);
  final String name;
  final double duration;
  final List<RigChannel> channels;
}

class RigSkin {
  RigSkin(this.joints, this.ibm);
  final List<int> joints; // nodos de glTF
  final Float32List ibm; // 16 por articulación
}

/// Una malla con piel o formas de morfo: lo necesario para recalcular sus vértices.
class RigPrim {
  RigPrim(this.mesh, this.node);

  /// Índice de la malla (pieza) en la escena.
  final int mesh;

  /// Nodo de glTF que la lleva (para los pesos de morfo).
  final int node;
  int skin = -1;

  /// Posiciones y normales de reposo (3 por vértice), antes de morfo y piel.
  Float32List? basePos, baseNor;
  Uint16List? joints; // 4 por vértice
  Float32List? weights; // 4 por vértice
  List<Float32List>? morphDeltas; // desplazamientos de posición por forma
  List<double> baseWeights = const [];
}

/// Esqueleto, animaciones y mallas deformables de un glTF.
class Rig {
  Rig(this.nodeCount);
  final int nodeCount;
  final parent = <int>[];
  late Float32List t, r, s; // 3, 4 y 3 por nodo
  final hasMatrix = <bool>[];

  /// Centro de giro y de escala de cada nodo (3 por nodo; VRML `center`), o null si ninguno lo usa.
  Float32List? center;
  late List<Float64List?> matrix; // para nodos con matriz fija
  final prims = <RigPrim>[];
  final skins = <RigSkin>[];
  final animations = <RigAnimation>[];

  bool get animated => animations.isNotEmpty;
}

/// Matriz 4x4 column-major a partir de traslación, rotación (cuaternión) y escala.
void composeTrs(
  Float64List out,
  double tx,
  double ty,
  double tz,
  double qx,
  double qy,
  double qz,
  double qw,
  double sx,
  double sy,
  double sz,
) {
  out[0] = (1 - 2 * (qy * qy + qz * qz)) * sx;
  out[1] = 2 * (qx * qy + qz * qw) * sx;
  out[2] = 2 * (qx * qz - qy * qw) * sx;
  out[3] = 0;
  out[4] = 2 * (qx * qy - qz * qw) * sy;
  out[5] = (1 - 2 * (qx * qx + qz * qz)) * sy;
  out[6] = 2 * (qy * qz + qx * qw) * sy;
  out[7] = 0;
  out[8] = 2 * (qx * qz + qy * qw) * sz;
  out[9] = 2 * (qy * qz - qx * qw) * sz;
  out[10] = (1 - 2 * (qx * qx + qy * qy)) * sz;
  out[11] = 0;
  out[12] = tx;
  out[13] = ty;
  out[14] = tz;
  out[15] = 1;
}

void mulInto(Float64List out, List<double> a, int ao, List<double> b, int bo) {
  for (var c = 0; c < 4; c++) {
    for (var r = 0; r < 4; r++) {
      var s = 0.0;
      for (var k = 0; k < 4; k++) {
        s += a[ao + k * 4 + r] * b[bo + c * 4 + k];
      }
      out[c * 4 + r] = s;
    }
  }
}

/// Estado animado de un [Rig]: traslación, rotación, escala y pesos por nodo en un instante.
class RigPose {
  RigPose(this.rig) {
    t = Float32List.fromList(rig.t);
    r = Float32List.fromList(rig.r);
    s = Float32List.fromList(rig.s);
    _world = List.generate(rig.nodeCount, (_) => Float64List(16));
    _have = List.filled(rig.nodeCount, false);
    _local = Float64List(16);
  }
  final Rig rig;
  late Float32List t, r, s;
  final weights = <int, List<double>>{};
  late List<Float64List> _world;
  late List<bool> _have;
  late Float64List _local;

  void reset() {
    t.setAll(0, rig.t);
    r.setAll(0, rig.r);
    s.setAll(0, rig.s);
    weights.clear();
  }

  /// Aplica una animación en el instante [time] (segundos).
  void sample(RigAnimation a, double time) {
    reset();
    for (final c in a.channels) {
      final n = c.times.length;
      if (n == 0) continue;
      final comps = switch (c.path) {
        1 => 4,
        3 => c.values.length ~/ (c.interp == 2 ? n * 3 : n),
        _ => 3,
      };
      final stride = c.interp == 2 ? comps * 3 : comps;
      var tt = time;
      if (tt <= c.times[0]) {
        _set(c, comps, _valueAt(c, 0, comps, stride));
        continue;
      }
      if (tt >= c.times[n - 1]) {
        _set(c, comps, _valueAt(c, n - 1, comps, stride));
        continue;
      }
      var lo = 0, hi = n - 1;
      while (hi - lo > 1) {
        final mid = (lo + hi) >> 1;
        if (c.times[mid] <= tt) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      final t0 = c.times[lo], t1 = c.times[hi];
      final u = t1 > t0 ? (tt - t0) / (t1 - t0) : 0.0;
      final v0 = _valueAt(c, lo, comps, stride);
      if (c.interp == 1) {
        _set(c, comps, v0);
        continue;
      }
      final v1 = _valueAt(c, hi, comps, stride);
      List<double> out;
      if (c.interp == 2) {
        // spline cúbica de Hermite: [entrada, valor, salida] por clave
        final dt = t1 - t0;
        final u2 = u * u, u3 = u2 * u;
        final m0 = [for (var k = 0; k < comps; k++) c.values[lo * stride + comps * 2 + k] * dt];
        final m1 = [for (var k = 0; k < comps; k++) c.values[hi * stride + k] * dt];
        out = [
          for (var k = 0; k < comps; k++)
            (2 * u3 - 3 * u2 + 1) * v0[k] + (u3 - 2 * u2 + u) * m0[k] + (-2 * u3 + 3 * u2) * v1[k] + (u3 - u2) * m1[k],
        ];
        if (c.path == 1) out = _norm(out);
      } else if (c.path == 1) {
        out = _slerp(v0, v1, u);
      } else {
        out = [for (var k = 0; k < comps; k++) v0[k] + (v1[k] - v0[k]) * u];
      }
      _set(c, comps, out);
    }
  }

  List<double> _valueAt(RigChannel c, int key, int comps, int stride) {
    final base = key * stride + (c.interp == 2 ? comps : 0);
    return [for (var k = 0; k < comps; k++) c.values[base + k].toDouble()];
  }

  void _set(RigChannel c, int comps, List<double> v) {
    switch (c.path) {
      case 0:
        t[c.node * 3] = v[0];
        t[c.node * 3 + 1] = v[1];
        t[c.node * 3 + 2] = v[2];
      case 1:
        r[c.node * 4] = v[0];
        r[c.node * 4 + 1] = v[1];
        r[c.node * 4 + 2] = v[2];
        r[c.node * 4 + 3] = v[3];
      case 2:
        s[c.node * 3] = v[0];
        s[c.node * 3 + 1] = v[1];
        s[c.node * 3 + 2] = v[2];
      default:
        weights[c.node] = v;
    }
  }

  static List<double> _norm(List<double> q) {
    final l = math.sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    return l == 0 ? [0, 0, 0, 1] : [for (final x in q) x / l];
  }

  static List<double> _slerp(List<double> a, List<double> b, double u) {
    var d = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    var bb = b;
    if (d < 0) {
      d = -d;
      bb = [-b[0], -b[1], -b[2], -b[3]];
    }
    if (d > 0.9995) {
      return _norm([for (var k = 0; k < 4; k++) a[k] + (bb[k] - a[k]) * u]);
    }
    final th = math.acos(d.clamp(-1.0, 1.0));
    final sin = math.sin(th);
    final w0 = math.sin((1 - u) * th) / sin, w1 = math.sin(u * th) / sin;
    return [for (var k = 0; k < 4; k++) a[k] * w0 + bb[k] * w1];
  }

  /// Matriz local de un nodo (a partir de la pose actual).
  void local(int n, Float64List out) {
    final m = rig.hasMatrix[n] ? rig.matrix[n] : null;
    if (m != null) {
      out.setAll(0, m);
      return;
    }
    final ce = rig.center;
    final cx = ce == null ? 0.0 : ce[n * 3], cy = ce == null ? 0.0 : ce[n * 3 + 1], cz = ce == null ? 0.0 : ce[n * 3 + 2];
    composeTrs(
      out,
      t[n * 3],
      t[n * 3 + 1],
      t[n * 3 + 2],
      r[n * 4],
      r[n * 4 + 1],
      r[n * 4 + 2],
      r[n * 4 + 3],
      s[n * 3],
      s[n * 3 + 1],
      s[n * 3 + 2],
    );
    if (cx != 0 || cy != 0 || cz != 0) {
      // T · C · R · S · C⁻¹: el giro y la escala se hacen alrededor del centro
      out[12] += cx - (out[0] * cx + out[4] * cy + out[8] * cz);
      out[13] += cy - (out[1] * cx + out[5] * cy + out[9] * cz);
      out[14] += cz - (out[2] * cx + out[6] * cy + out[10] * cz);
    }
  }

  void beginFrame() {
    for (var i = 0; i < _have.length; i++) {
      _have[i] = false;
    }
  }

  /// Matriz global de un nodo de glTF (con memoria dentro del fotograma).
  Float64List world(int n) {
    if (_have[n]) return _world[n];
    final p = rig.parent[n];
    final pw = p < 0 ? null : world(p);
    local(n, _local);
    if (pw == null) {
      _world[n].setAll(0, _local);
    } else {
      mulInto(_world[n], pw, 0, _local, 0);
    }
    _have[n] = true;
    return _world[n];
  }
}
