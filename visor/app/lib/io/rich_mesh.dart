// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:math' as math;
import 'dart:typed_data';

import 'mesh_data.dart';
import '../l10n/l10n.dart';

/// Lista de enteros con crecimiento.
class IntBuf {
  Int32List a = Int32List(1024);
  int n = 0;
  void add(int v) {
    if (n >= a.length) {
      final b = Int32List(a.length * 2);
      b.setRange(0, n, a);
      a = b;
    }
    a[n++] = v;
  }

  Int32List take() => Int32List.sublistView(a, 0, n);
}

class FloatBuf {
  Float32List a = Float32List(4096);
  int n = 0;
  void add(double v) {
    if (n >= a.length) {
      final b = Float32List(a.length * 2);
      b.setRange(0, n, a);
      a = b;
    }
    a[n++] = v;
  }

  void add3(double x, double y, double z) {
    if (n + 3 > a.length) {
      final b = Float32List(a.length * 2);
      b.setRange(0, n, a);
      a = b;
    }
    a[n++] = x;
    a[n++] = y;
    a[n++] = z;
  }

  Float32List take() => Float32List.sublistView(a, 0, n);
}

class Uint32Buf {
  Uint32List a = Uint32List(4096);
  int n = 0;
  void add(int v) {
    if (n >= a.length) {
      final b = Uint32List(a.length * 2);
      b.setRange(0, n, a);
      a = b;
    }
    a[n++] = v;
  }

  Uint32List take() => Uint32List.sublistView(a, 0, n);
}

/// Triángulos por esquinas: posición, UV y normal (−1 si no hay) y grupo de material.
/// Los buffers de UV, normal y grupo solo se rellenan si se piden.
class CornerTris {
  CornerTris({this.withUv = false, this.withNrm = false, this.withGroup = false});
  final bool withUv, withNrm, withGroup;
  final pos = IntBuf();
  final uv = IntBuf();
  final nrm = IntBuf();
  final group = IntBuf(); // un valor por triángulo
  int _tris = 0;

  int get triangleCount => _tris;
  int uvAt(int c) => withUv ? uv.a[c] : -1;
  int nrmAt(int c) => withNrm ? nrm.a[c] : -1;
  int groupAt(int tri) => withGroup ? group.a[tri] : 0;

  void tri(
    int p0,
    int p1,
    int p2, {
    int g = 0,
    int t0 = -1,
    int t1 = -1,
    int t2 = -1,
    int n0 = -1,
    int n1 = -1,
    int n2 = -1,
  }) {
    pos
      ..add(p0)
      ..add(p1)
      ..add(p2);
    if (withUv) {
      uv
        ..add(t0)
        ..add(t1)
        ..add(t2);
    }
    if (withNrm) {
      nrm
        ..add(n0)
        ..add(n1)
        ..add(n2);
    }
    if (withGroup) group.add(g);
    _tris++;
  }
}

/// Resultado por grupo: malla indexada con normales y atributos.
class RichGroupOut {
  RichGroupOut(
    this.group,
    this.name,
    this.vertices,
    this.indices,
    this.min,
    this.max,
    this.extra,
    this.material,
  );
  final int group;
  final String name;
  final Float32List vertices;
  final Uint32List indices;
  final List<double> min, max;
  final Float32List? extra;
  final int? material;

  MeshData toMeshData({int? colorOverride}) => MeshData(
    name,
    vertices,
    min,
    max,
    color: colorOverride,
    indices: indices,
    extra: extra,
    material: material,
  );
}

/// Tabla de dispersión abierta con claves de tres enteros (sin objetos por entrada).
class _CornerMap {
  _CornerMap(int expected) {
    var c = 1024;
    while (c < expected * 2) {
      c <<= 1;
    }
    _alloc(c);
  }
  late int _mask;
  late Int64List _k1;
  late Int64List _k2;
  late Int32List _val;
  int _count = 0;

  void _alloc(int c) {
    _mask = c - 1;
    _k1 = Int64List(c)..fillRange(0, c, -1);
    _k2 = Int64List(c);
    _val = Int32List(c);
  }

  static int _hash(int p, int t, int n) =>
      (p * 0x9E3779B1) ^ (t * 0x85EBCA6B) ^ (n * 0xC2B2AE35);

  void _grow() {
    final ok1 = _k1, ok2 = _k2, ov = _val;
    _alloc((_mask + 1) * 2);
    for (var i = 0; i < ok1.length; i++) {
      final k = ok1[i];
      if (k == -1) continue;
      final p = k >> 32;
      final t = (k & 0xFFFFFFFF).toSigned(32);
      var h = _hash(p, t, ok2[i]) & _mask;
      while (_k1[h] != -1) {
        h = (h + 1) & _mask;
      }
      _k1[h] = k;
      _k2[h] = ok2[i];
      _val[h] = ov[i];
    }
  }

  /// Devuelve el id existente o −1 (y registra [id] en ese caso).
  int getOrAdd(int p, int t, int n, int id) {
    if ((_count + 1) * 2 > _mask + 1) _grow();
    final k1 = (p << 32) | (t & 0xFFFFFFFF);
    var h = _hash(p, t, n) & _mask;
    while (true) {
      final cur = _k1[h];
      if (cur == -1) {
        _k1[h] = k1;
        _k2[h] = n;
        _val[h] = id;
        _count++;
        return -1;
      }
      if (cur == k1 && _k2[h] == n) return _val[h];
      h = (h + 1) & _mask;
    }
  }
}

/// Construye mallas indexadas con UV, normales y color por vértice a partir de esquinas.
///
/// Sin normales en el archivo se calculan suaves (media ponderada por área) y las
/// esquinas cuyo ángulo con la normal suave supera [creaseDot] se dejan planas, de modo que
/// una caja queda con aristas vivas y un escaneo queda suave. Con [flatWithoutNormals]
/// (glTF) todo es plano, como pide la especificación.
class RichMeshBuilder {
  RichMeshBuilder({
    required this.pos,
    this.nrm,
    this.uv,
    this.col,
    this.faceColor,
    this.flatWithoutNormals = false,
    this.creaseDot = 0.7,
  });

  /// 3 por vértice.
  final Float32List pos;

  /// 3 por normal (se indexa por las esquinas, o por vértice si [CornerTris.nrm] vale −1 y
  /// el archivo trae una por vértice: ver [nrmPerVertex]).
  Float32List? nrm;
  bool nrmPerVertex = false;

  /// 2 por UV.
  final Float32List? uv;

  /// 4 por vértice (RGBA, 0..255).
  final Uint8List? col;

  /// Color por triángulo (RGBA 0..1, 4 por triángulo); fuerza vértices propios por cara.
  final Float32List? faceColor;
  final bool flatWithoutNormals;
  final double creaseDot;

  Float32List? _smooth;
  Float32List? _faceN;

  void _prepareNormals(CornerTris t) {
    final nt = t.triangleCount;
    final fn = Float32List(nt * 3);
    final sm = Float32List(pos.length);
    for (var i = 0; i < nt; i++) {
      final a = t.pos.a[i * 3] * 3, b = t.pos.a[i * 3 + 1] * 3, c = t.pos.a[i * 3 + 2] * 3;
      if (a + 2 >= pos.length || b + 2 >= pos.length || c + 2 >= pos.length) continue;
      final ux = pos[b] - pos[a], uy = pos[b + 1] - pos[a + 1], uz = pos[b + 2] - pos[a + 2];
      final vx = pos[c] - pos[a], vy = pos[c + 1] - pos[a + 1], vz = pos[c + 2] - pos[a + 2];
      var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      // normal suave ponderada por el ángulo de cada esquina: no depende de cómo se triangule
      final flen = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (flen > 0) {
        final fx = nx / flen, fy = ny / flen, fz = nz / flen;
        double ang(int p, int q, int r) {
          final e1x = pos[q] - pos[p], e1y = pos[q + 1] - pos[p + 1], e1z = pos[q + 2] - pos[p + 2];
          final e2x = pos[r] - pos[p], e2y = pos[r + 1] - pos[p + 1], e2z = pos[r + 2] - pos[p + 2];
          final l1 = math.sqrt(e1x * e1x + e1y * e1y + e1z * e1z);
          final l2 = math.sqrt(e2x * e2x + e2y * e2y + e2z * e2z);
          if (l1 == 0 || l2 == 0) return 0;
          return math.acos(((e1x * e2x + e1y * e2y + e1z * e2z) / (l1 * l2)).clamp(-1.0, 1.0));
        }

        final wa = ang(a, b, c), wb = ang(b, c, a), wc = ang(c, a, b);
        sm[a] += fx * wa;
        sm[a + 1] += fy * wa;
        sm[a + 2] += fz * wa;
        sm[b] += fx * wb;
        sm[b + 1] += fy * wb;
        sm[b + 2] += fz * wb;
        sm[c] += fx * wc;
        sm[c + 1] += fy * wc;
        sm[c + 2] += fz * wc;
      }
      final len = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (len > 0) {
        nx /= len;
        ny /= len;
        nz /= len;
      }
      fn[i * 3] = nx;
      fn[i * 3 + 1] = ny;
      fn[i * 3 + 2] = nz;
    }
    for (var i = 0; i + 2 < sm.length; i += 3) {
      final l = math.sqrt(sm[i] * sm[i] + sm[i + 1] * sm[i + 1] + sm[i + 2] * sm[i + 2]);
      if (l > 0) {
        sm[i] /= l;
        sm[i + 1] /= l;
        sm[i + 2] /= l;
      }
    }
    _smooth = sm;
    _faceN = fn;
  }

  /// Genera una malla por cada grupo que tenga triángulos. [names] da el nombre de cada grupo.
  List<RichGroupOut> build(CornerTris t, List<String> names, {List<int?>? materials}) {
    final nt = t.triangleCount;
    final haveN = nrm != null;
    _prepareNormals(t);
    final groups = <int>{for (var i = 0; i < nt; i++) t.groupAt(i)};
    final out = <RichGroupOut>[];
    final haveUv = uv != null;
    final haveCol = col != null;
    final extraWanted = haveUv || haveCol || faceColor != null;
    for (final g in groups.toList()..sort()) {
      final verts = FloatBuf();
      final extra = extraWanted ? FloatBuf() : null;
      final idx = Uint32Buf();
      final map = _CornerMap(math.max(1024, nt ~/ 2));
      var nv = 0;
      final mn = [double.infinity, double.infinity, double.infinity];
      final mx = [-double.infinity, -double.infinity, -double.infinity];
      for (var i = 0; i < nt; i++) {
        if (t.groupAt(i) != g) continue;
        var bad = false;
        final startIdx = idx.n;
        for (var k = 0; k < 3; k++) {
          final c = i * 3 + k;
          final p = t.pos.a[c];
          if (p < 0 || p * 3 + 2 >= pos.length) {
            bad = true;
            break;
          }
          final tu = t.uvAt(c);
          final ni = t.nrmAt(c);
          // clave de normal: índice del archivo, o −1 (suave por vértice), o −2−triángulo (plano)
          int nkey;
          double nx, ny, nz;
          if (haveN && ni >= 0 && ni * 3 + 2 < nrm!.length) {
            nkey = ni;
            nx = nrm![ni * 3];
            ny = nrm![ni * 3 + 1];
            nz = nrm![ni * 3 + 2];
          } else if (haveN && nrmPerVertex && p * 3 + 2 < nrm!.length) {
            nkey = -1;
            nx = nrm![p * 3];
            ny = nrm![p * 3 + 1];
            nz = nrm![p * 3 + 2];
          } else {
            final fx = _faceN![i * 3], fy = _faceN![i * 3 + 1], fz = _faceN![i * 3 + 2];
            final sx = _smooth![p * 3], sy = _smooth![p * 3 + 1], sz = _smooth![p * 3 + 2];
            final smooth = !flatWithoutNormals && (fx * sx + fy * sy + fz * sz) >= creaseDot;
            if (smooth) {
              nkey = -1;
              nx = sx;
              ny = sy;
              nz = sz;
            } else {
              // esquinas planas: las de un mismo plano comparten vértice
              nkey = -2 -
                  (((fx * 1000).round() + 1000) * 2001 + ((fy * 1000).round() + 1000)) * 2001 -
                  ((fz * 1000).round() + 1000);
              nx = fx;
              ny = fy;
              nz = fz;
            }
          }
          if (faceColor != null) nkey = -2 - i;
          final found = map.getOrAdd(p, tu, nkey, nv);
          if (found >= 0) {
            idx.add(found);
            continue;
          }
          final px = pos[p * 3], py = pos[p * 3 + 1], pz = pos[p * 3 + 2];
          verts
            ..add(px)
            ..add(py)
            ..add(pz)
            ..add(nx)
            ..add(ny)
            ..add(nz);
          if (px < mn[0]) mn[0] = px;
          if (py < mn[1]) mn[1] = py;
          if (pz < mn[2]) mn[2] = pz;
          if (px > mx[0]) mx[0] = px;
          if (py > mx[1]) mx[1] = py;
          if (pz > mx[2]) mx[2] = pz;
          if (extra != null) {
            if (haveUv && tu >= 0 && tu * 2 + 1 < uv!.length) {
              extra
                ..add(uv![tu * 2])
                ..add(uv![tu * 2 + 1]);
            } else {
              extra
                ..add(0)
                ..add(0);
            }
            if (faceColor != null && i * 4 + 3 < faceColor!.length) {
              extra
                ..add(faceColor![i * 4])
                ..add(faceColor![i * 4 + 1])
                ..add(faceColor![i * 4 + 2])
                ..add(faceColor![i * 4 + 3]);
            } else if (haveCol && p * 4 + 3 < col!.length) {
              extra
                ..add(col![p * 4] / 255)
                ..add(col![p * 4 + 1] / 255)
                ..add(col![p * 4 + 2] / 255)
                ..add(col![p * 4 + 3] / 255);
            } else {
              extra
                ..add(1)
                ..add(1)
                ..add(1)
                ..add(1);
            }
          }
          idx.add(nv);
          nv++;
        }
        if (bad) idx.n = startIdx; // índice fuera de rango: se descarta el triángulo
      }
      if (idx.n == 0) continue;
      out.add(
        RichGroupOut(
          g,
          g < names.length ? names[g] : tr('Grupo {n}', {'n': g}),
          verts.take(),
          idx.take(),
          mn,
          mx,
          extra?.take(),
          materials != null && g < materials.length ? materials[g] : null,
        ),
      );
    }
    return out;
  }
}

/// Triangula un polígono (índices de posición) y devuelve ternas de posiciones locales
/// (0..n−1). Cuadriláteros convexos y triángulos sin coste; los polígonos cóncavos se
/// cortan por orejas sobre el plano de su normal de Newell.
List<int> triangulatePolygon(Float32List pos, List<int> p) {
  final n = p.length;
  if (n < 3) return const [];
  if (n == 3) return const [0, 1, 2];
  // Normal de Newell
  double nx = 0, ny = 0, nz = 0;
  for (var i = 0; i < n; i++) {
    final a = p[i] * 3, b = p[(i + 1) % n] * 3;
    if (a + 2 >= pos.length || b + 2 >= pos.length) return _fan(n);
    nx += (pos[a + 1] - pos[b + 1]) * (pos[a + 2] + pos[b + 2]);
    ny += (pos[a + 2] - pos[b + 2]) * (pos[a] + pos[b]);
    nz += (pos[a] - pos[b]) * (pos[a + 1] + pos[b + 1]);
  }
  final ax = nx.abs(), ay = ny.abs(), az = nz.abs();
  // proyección al plano dominante
  final k = ax >= ay && ax >= az ? 0 : (ay >= az ? 1 : 2);
  final sgn = (k == 0 ? nx : (k == 1 ? ny : nz)) < 0 ? -1.0 : 1.0;
  double px(int i) {
    final b = p[i] * 3;
    return k == 0 ? pos[b + 1] : (k == 1 ? pos[b + 2] : pos[b]);
  }

  double py(int i) {
    final b = p[i] * 3;
    return k == 0 ? pos[b + 2] : (k == 1 ? pos[b] : pos[b + 1]);
  }

  double cross(int a, int b, int c) =>
      sgn * ((px(b) - px(a)) * (py(c) - py(a)) - (py(b) - py(a)) * (px(c) - px(a)));

  // ¿convexo? entonces abanico
  var convex = true;
  for (var i = 0; i < n; i++) {
    if (cross(i, (i + 1) % n, (i + 2) % n) < -1e-12) {
      convex = false;
      break;
    }
  }
  if (convex) return _fan(n);

  final idx = List<int>.generate(n, (i) => i);
  final out = <int>[];
  var guard = 0;
  while (idx.length > 3 && guard++ < n * n) {
    var clipped = false;
    for (var i = 0; i < idx.length; i++) {
      final a = idx[(i + idx.length - 1) % idx.length], b = idx[i], c = idx[(i + 1) % idx.length];
      if (cross(a, b, c) <= 1e-12) continue;
      var inside = false;
      for (final o in idx) {
        if (o == a || o == b || o == c) continue;
        if (cross(a, b, o) >= 0 && cross(b, c, o) >= 0 && cross(c, a, o) >= 0) {
          inside = true;
          break;
        }
      }
      if (inside) continue;
      out.addAll([a, b, c]);
      idx.removeAt(i);
      clipped = true;
      break;
    }
    if (!clipped) break;
  }
  if (idx.length == 3) {
    out.addAll(idx);
  } else {
    // polígono degenerado: abanico del resto
    for (var i = 1; i + 1 < idx.length; i++) {
      out.addAll([idx[0], idx[i], idx[i + 1]]);
    }
  }
  return out;
}

List<int> _fan(int n) => [
  for (var i = 1; i + 1 < n; i++) ...[0, i, i + 1],
];
