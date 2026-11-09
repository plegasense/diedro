// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import '../io/iso_run.dart';

/// Datos del archivo STL que no están en la malla.
class StlMeta {
  StlMeta({
    required this.binary,
    required this.header,
    required this.solids,
    required this.bytes,
    required this.colored,
    this.skipped = 0,
    this.colors,
    this.defaultColor,
  });

  /// Color de 15 bits de cada triángulo (estilo Magics); bit 15 = «sin color propio».
  final Uint16List? colors;
  final List<int>? defaultColor; // rgb 0-255
  final bool binary;
  final String header;
  final int solids;
  final int bytes;
  final bool colored;

  /// Triángulos descartados por tener coordenadas no finitas (NaN o infinito).
  final int skipped;
}

/// Un casco (conjunto de triángulos conectados).
class MeshShell {
  MeshShell({
    required this.triangles,
    required this.volume,
    required this.area,
    required this.min,
    required this.max,
    required this.closed,
  });
  final int triangles;

  /// Volumen con signo (mm³ si la malla está en mm): negativo = normales hacia dentro.
  final double volume;
  final double area;
  final List<double> min, max;
  final bool closed;
}

/// Un contorno abierto (agujero) de la malla.
class MeshHole {
  MeshHole(this.center, this.size, this.edges, this.perimeter, this.segments);
  final List<double> center;

  /// Diagonal de su caja envolvente.
  final double size;
  final int edges;
  final double perimeter;

  /// Segmentos del contorno (6 floats por segmento: x0 y0 z0 x1 y1 z1).
  final Float32List segments;
}

/// Resultado de revisar una malla triangular.
class MeshReport {
  MeshReport({
    required this.triangles,
    required this.vertices,
    required this.degenerate,
    required this.duplicates,
    required this.boundaryEdges,
    required this.nonManifoldEdges,
    required this.inconsistentEdges,
    required this.shells,
    required this.holes,
    required this.volume,
    required this.area,
    required this.centroid,
    required this.min,
    required this.max,
    required this.nonManifoldSegments,
    required this.inconsistentSegments,
    required this.milliseconds,
  });

  final int triangles;

  /// Vértices tras soldar los coincidentes.
  final int vertices;
  final int degenerate, duplicates;
  final int boundaryEdges, nonManifoldEdges, inconsistentEdges;
  final List<MeshShell> shells;
  final List<MeshHole> holes;

  /// Suma de los volúmenes con signo de todos los cascos.
  final double volume;
  final double area;
  final List<double> centroid;
  final List<double> min, max;
  final Float32List nonManifoldSegments, inconsistentSegments;
  final int milliseconds;

  /// Cada arista une exactamente dos triángulos, en sentidos opuestos.
  bool get watertight =>
      boundaryEdges == 0 && nonManifoldEdges == 0 && inconsistentEdges == 0;

  /// Cierra el volumen pero con normales mezcladas u orientadas al revés.
  bool get invertedNormals => volume < 0 || inconsistentEdges > 0;

  int get problemCount =>
      (boundaryEdges > 0 ? 1 : 0) +
      (nonManifoldEdges > 0 ? 1 : 0) +
      (inconsistentEdges > 0 ? 1 : 0) +
      (degenerate > 0 ? 1 : 0) +
      (duplicates > 0 ? 1 : 0) +
      (volume < 0 && inconsistentEdges == 0 ? 1 : 0);
}

int _pow2(int n) {
  var c = 16;
  while (c < n) {
    c <<= 1;
  }
  return c;
}

/// Revisa la malla en otro hilo. [vertices] son 6 floats por vértice (posición + normal),
/// tres vértices por triángulo.
Future<MeshReport> checkMesh(Float32List vertices) {
  final copy = TransferableTypedData.fromList([vertices]);
  return isoRun(() => analyzeMesh(copy.materialize().asFloat32List()));
}

MeshReport analyzeMesh(Float32List v) {
  final sw = Stopwatch()..start();
  final nTri = v.length ~/ 18;
  final mn = [double.infinity, double.infinity, double.infinity];
  final mx = [-double.infinity, -double.infinity, -double.infinity];
  for (var i = 0; i < v.length; i += 6) {
    for (var k = 0; k < 3; k++) {
      final x = v[i + k];
      if (x < mn[k]) mn[k] = x;
      if (x > mx[k]) mx[k] = x;
    }
  }
  if (nTri == 0) {
    return MeshReport(
      triangles: 0,
      vertices: 0,
      degenerate: 0,
      duplicates: 0,
      boundaryEdges: 0,
      nonManifoldEdges: 0,
      inconsistentEdges: 0,
      shells: const [],
      holes: const [],
      volume: 0,
      area: 0,
      centroid: [0, 0, 0],
      min: [0, 0, 0],
      max: [0, 0, 0],
      nonManifoldSegments: Float32List(0),
      inconsistentSegments: Float32List(0),
      milliseconds: 0,
    );
  }
  final diag = math.sqrt(
    math.pow(mx[0] - mn[0], 2) +
        math.pow(mx[1] - mn[1], 2) +
        math.pow(mx[2] - mn[2], 2),
  );
  // Soldadura: dos vértices se unen si difieren menos de `tol` en cada eje. La rejilla tiene
  // celdas de 10·tol y se miran también las celdas vecinas cuando el punto está cerca del borde.
  final tol = math.max(diag * 1e-6, 1e-9);
  final inv = 1 / (tol * 10);
  final cap = _pow2(nTri * 3 * 2);
  final mask = cap - 1;
  final kx = Int32List(cap), ky = Int32List(cap), kz = Int32List(cap);
  final kv = Int32List(cap)..fillRange(0, cap, -1);
  final wx = <double>[],
      wy = <double>[],
      wz = <double>[]; // posiciones soldadas
  final idx = Int32List(nTri * 3);
  int slotOf(int qx, int qy, int qz) {
    var h = (qx * 73856093) ^ (qy * 19349663) ^ (qz * 83492791);
    return (h ^ (h >> 15)) & mask;
  }

  int? find3(int qx, int qy, int qz, double x, double y, double z) {
    var h = slotOf(qx, qy, qz);
    while (true) {
      final id = kv[h];
      if (id < 0) return null;
      if (kx[h] == qx && ky[h] == qy && kz[h] == qz) {
        if ((wx[id] - x).abs() <= tol &&
            (wy[id] - y).abs() <= tol &&
            (wz[id] - z).abs() <= tol) {
          return id;
        }
      }
      h = (h + 1) & mask;
    }
  }

  for (var t = 0; t < nTri * 3; t++) {
    final o = t * 6;
    final x = v[o], y = v[o + 1], z = v[o + 2];
    final fx = x * inv, fy = y * inv, fz = z * inv;
    final qx = fx.round(), qy = fy.round(), qz = fz.round();
    // Desplazamientos de celda a revisar en cada eje.
    final ox = fx - qx > 0.4 ? 1 : (fx - qx < -0.4 ? -1 : 0);
    final oy = fy - qy > 0.4 ? 1 : (fy - qy < -0.4 ? -1 : 0);
    final oz = fz - qz > 0.4 ? 1 : (fz - qz < -0.4 ? -1 : 0);
    int? found = find3(qx, qy, qz, x, y, z);
    if (found == null && ox != 0) found = find3(qx + ox, qy, qz, x, y, z);
    if (found == null && oy != 0) found = find3(qx, qy + oy, qz, x, y, z);
    if (found == null && oz != 0) found = find3(qx, qy, qz + oz, x, y, z);
    if (found == null && ox != 0 && oy != 0) {
      found = find3(qx + ox, qy + oy, qz, x, y, z);
    }
    if (found == null && ox != 0 && oz != 0) {
      found = find3(qx + ox, qy, qz + oz, x, y, z);
    }
    if (found == null && oy != 0 && oz != 0) {
      found = find3(qx, qy + oy, qz + oz, x, y, z);
    }
    if (found == null && ox != 0 && oy != 0 && oz != 0) {
      found = find3(qx + ox, qy + oy, qz + oz, x, y, z);
    }
    if (found != null) {
      idx[t] = found;
      continue;
    }
    var h = slotOf(qx, qy, qz);
    while (kv[h] >= 0) {
      h = (h + 1) & mask;
    }
    kx[h] = qx;
    ky[h] = qy;
    kz[h] = qz;
    kv[h] = wx.length;
    idx[t] = wx.length;
    wx.add(x);
    wy.add(y);
    wz.add(z);
  }
  final nv = wx.length;

  // --- 2. Triángulos degenerados (dos vértices iguales o área ~ 0).
  final live = Uint8List(nTri);
  var degenerate = 0;
  for (var t = 0; t < nTri; t++) {
    final a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
    var bad = a == b || b == c || a == c;
    if (!bad) {
      final ux = wx[b] - wx[a], uy = wy[b] - wy[a], uz = wz[b] - wz[a];
      final vx = wx[c] - wx[a], vy = wy[c] - wy[a], vz = wz[c] - wz[a];
      final cx = uy * vz - uz * vy,
          cy = uz * vx - ux * vz,
          cz = ux * vy - uy * vx;
      final area2 = math.sqrt(cx * cx + cy * cy + cz * cz);
      bad = area2 < tol * tol * 0.5;
    }
    if (bad) {
      degenerate++;
    } else {
      live[t] = 1;
    }
  }

  // --- 3. Aristas: cuántos triángulos la usan y en qué sentido.
  final ecap = _pow2(nTri * 3 * 2);
  final emask = ecap - 1;
  final eLo = Int32List(ecap)..fillRange(0, ecap, -1);
  final eHi = Int32List(ecap);
  final eCnt = Uint8List(ecap), eFwd = Uint8List(ecap), eBwd = Uint8List(ecap);
  for (var t = 0; t < nTri; t++) {
    if (live[t] == 0) continue;
    for (var k = 0; k < 3; k++) {
      final a = idx[t * 3 + k], b = idx[t * 3 + (k + 1) % 3];
      final lo = a < b ? a : b, hi = a < b ? b : a;
      var h = ((lo * 73856093) ^ (hi * 19349663)) & emask;
      while (true) {
        if (eLo[h] < 0) {
          eLo[h] = lo;
          eHi[h] = hi;
          break;
        }
        if (eLo[h] == lo && eHi[h] == hi) break;
        h = (h + 1) & emask;
      }
      if (eCnt[h] < 255) eCnt[h]++;
      if (a < b) {
        if (eFwd[h] < 255) eFwd[h]++;
      } else {
        if (eBwd[h] < 255) eBwd[h]++;
      }
    }
  }
  var boundary = 0, nonManifold = 0, inconsistent = 0;
  final nmSegs = <double>[], inSegs = <double>[];
  final bEdges = <int>[]; // pares lo,hi de aristas abiertas
  for (var h = 0; h < ecap; h++) {
    if (eLo[h] < 0) continue;
    final c = eCnt[h];
    if (c == 1) {
      boundary++;
      bEdges
        ..add(eLo[h])
        ..add(eHi[h]);
    } else if (c > 2) {
      nonManifold++;
      if (nmSegs.length < 6 * 20000) {
        nmSegs.addAll([
          wx[eLo[h]],
          wy[eLo[h]],
          wz[eLo[h]],
          wx[eHi[h]],
          wy[eHi[h]],
          wz[eHi[h]],
        ]);
      }
    } else if (c == 2 && (eFwd[h] == 2 || eBwd[h] == 2)) {
      inconsistent++;
      if (inSegs.length < 6 * 20000) {
        inSegs.addAll([
          wx[eLo[h]],
          wy[eLo[h]],
          wz[eLo[h]],
          wx[eHi[h]],
          wy[eHi[h]],
          wz[eHi[h]],
        ]);
      }
    }
  }

  // --- 4. Triángulos duplicados (mismo trío de vértices).
  var duplicates = 0;
  {
    final dcap = _pow2(nTri * 2);
    final dmask = dcap - 1;
    final d0 = Int32List(dcap)..fillRange(0, dcap, -1);
    final d1 = Int32List(dcap), d2 = Int32List(dcap);
    for (var t = 0; t < nTri; t++) {
      if (live[t] == 0) continue;
      var a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
      int tmp;
      if (a > b) {
        tmp = a;
        a = b;
        b = tmp;
      }
      if (b > c) {
        tmp = b;
        b = c;
        c = tmp;
      }
      if (a > b) {
        tmp = a;
        a = b;
        b = tmp;
      }
      var h = ((a * 73856093) ^ (b * 19349663) ^ (c * 83492791)) & dmask;
      while (true) {
        if (d0[h] < 0) {
          d0[h] = a;
          d1[h] = b;
          d2[h] = c;
          break;
        }
        if (d0[h] == a && d1[h] == b && d2[h] == c) {
          duplicates++;
          break;
        }
        h = (h + 1) & dmask;
      }
    }
  }

  // --- 5. Cascos (vértices unidos por triángulos) y su volumen.
  final parent = Int32List(nv);
  for (var i = 0; i < nv; i++) {
    parent[i] = i;
  }
  int find(int x) {
    while (parent[x] != x) {
      parent[x] = parent[parent[x]];
      x = parent[x];
    }
    return x;
  }

  for (var t = 0; t < nTri; t++) {
    if (live[t] == 0) continue;
    final ra = find(idx[t * 3]);
    final rb = find(idx[t * 3 + 1]);
    final rc = find(idx[t * 3 + 2]);
    if (ra != rb) parent[rb] = ra;
    final r2 = find(idx[t * 3]);
    if (r2 != rc) parent[rc] = r2;
  }
  final shellOf = <int, int>{};
  final sTris = <int>[];
  final sVol = <double>[];
  final sArea = <double>[];
  final sMin = <List<double>>[], sMax = <List<double>>[];
  final sOpen = <int>[];
  var totalVol = 0.0, totalArea = 0.0;
  var cx = 0.0, cy = 0.0, cz = 0.0;
  for (var t = 0; t < nTri; t++) {
    if (live[t] == 0) continue;
    final a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
    final root = find(a);
    final s = shellOf.putIfAbsent(root, () {
      sTris.add(0);
      sVol.add(0);
      sArea.add(0);
      sMin.add([double.infinity, double.infinity, double.infinity]);
      sMax.add([-double.infinity, -double.infinity, -double.infinity]);
      sOpen.add(0);
      return sTris.length - 1;
    });
    final ax = wx[a], ay = wy[a], az = wz[a];
    final bx = wx[b], by = wy[b], bz = wz[b];
    final qx = wx[c], qy = wy[c], qz = wz[c];
    final dv =
        (ax * (by * qz - bz * qy) -
            ay * (bx * qz - bz * qx) +
            az * (bx * qy - by * qx)) /
        6;
    final ux = bx - ax, uy = by - ay, uz = bz - az;
    final vx = qx - ax, vy = qy - ay, vz = qz - az;
    final nx = uy * vz - uz * vy,
        ny = uz * vx - ux * vz,
        nz = ux * vy - uy * vx;
    final ar = 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz);
    sTris[s]++;
    sVol[s] += dv;
    sArea[s] += ar;
    totalVol += dv;
    totalArea += ar;
    cx += dv * (ax + bx + qx) / 4;
    cy += dv * (ay + by + qy) / 4;
    cz += dv * (az + bz + qz) / 4;
    for (final p in [(ax, ay, az), (bx, by, bz), (qx, qy, qz)]) {
      final m0 = sMin[s], m1 = sMax[s];
      if (p.$1 < m0[0]) m0[0] = p.$1;
      if (p.$2 < m0[1]) m0[1] = p.$2;
      if (p.$3 < m0[2]) m0[2] = p.$3;
      if (p.$1 > m1[0]) m1[0] = p.$1;
      if (p.$2 > m1[1]) m1[1] = p.$2;
      if (p.$3 > m1[2]) m1[2] = p.$3;
    }
  }
  // Cascos con aristas abiertas.
  for (var i = 0; i < bEdges.length; i += 2) {
    final s = shellOf[find(bEdges[i])];
    if (s != null) sOpen[s]++;
  }

  // --- 6. Agujeros: contornos abiertos conectados.
  final holes = <MeshHole>[];
  if (bEdges.isNotEmpty) {
    final bParent = <int, int>{};
    int bf(int x) {
      var r = x;
      while (bParent[r] != r) {
        r = bParent[r]!;
      }
      while (bParent[x] != r) {
        final n = bParent[x]!;
        bParent[x] = r;
        x = n;
      }
      return r;
    }

    for (var i = 0; i < bEdges.length; i += 2) {
      bParent.putIfAbsent(bEdges[i], () => bEdges[i]);
      bParent.putIfAbsent(bEdges[i + 1], () => bEdges[i + 1]);
    }
    for (var i = 0; i < bEdges.length; i += 2) {
      final a = bf(bEdges[i]), b = bf(bEdges[i + 1]);
      if (a != b) bParent[b] = a;
    }
    final groups = <int, List<int>>{};
    for (var i = 0; i < bEdges.length; i += 2) {
      groups.putIfAbsent(bf(bEdges[i]), () => []).add(i);
    }
    final list = groups.values.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final g in list.take(300)) {
      final segs = Float32List(g.length * 6);
      var per = 0.0;
      final lo = [double.infinity, double.infinity, double.infinity];
      final hi = [-double.infinity, -double.infinity, -double.infinity];
      for (var k = 0; k < g.length; k++) {
        final a = bEdges[g[k]], b = bEdges[g[k] + 1];
        segs[k * 6] = wx[a];
        segs[k * 6 + 1] = wy[a];
        segs[k * 6 + 2] = wz[a];
        segs[k * 6 + 3] = wx[b];
        segs[k * 6 + 4] = wy[b];
        segs[k * 6 + 5] = wz[b];
        per += math.sqrt(
          math.pow(wx[a] - wx[b], 2) +
              math.pow(wy[a] - wy[b], 2) +
              math.pow(wz[a] - wz[b], 2),
        );
        for (final p in [(wx[a], wy[a], wz[a]), (wx[b], wy[b], wz[b])]) {
          if (p.$1 < lo[0]) lo[0] = p.$1;
          if (p.$2 < lo[1]) lo[1] = p.$2;
          if (p.$3 < lo[2]) lo[2] = p.$3;
          if (p.$1 > hi[0]) hi[0] = p.$1;
          if (p.$2 > hi[1]) hi[1] = p.$2;
          if (p.$3 > hi[2]) hi[2] = p.$3;
        }
      }
      holes.add(
        MeshHole(
          [(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2],
          math.sqrt(
            math.pow(hi[0] - lo[0], 2) +
                math.pow(hi[1] - lo[1], 2) +
                math.pow(hi[2] - lo[2], 2),
          ),
          g.length,
          per,
          segs,
        ),
      );
    }
  }

  final shells = <MeshShell>[
    for (var i = 0; i < sTris.length; i++)
      MeshShell(
        triangles: sTris[i],
        volume: sVol[i],
        area: sArea[i],
        min: sMin[i],
        max: sMax[i],
        closed: sOpen[i] == 0,
      ),
  ]..sort((a, b) => b.triangles.compareTo(a.triangles));

  return MeshReport(
    triangles: nTri,
    vertices: nv,
    degenerate: degenerate,
    duplicates: duplicates,
    boundaryEdges: boundary,
    nonManifoldEdges: nonManifold,
    inconsistentEdges: inconsistent,
    shells: shells,
    holes: holes,
    volume: totalVol,
    area: totalArea,
    centroid: totalVol.abs() > 1e-12
        ? [cx / totalVol, cy / totalVol, cz / totalVol]
        : [(mn[0] + mx[0]) / 2, (mn[1] + mx[1]) / 2, (mn[2] + mx[2]) / 2],
    min: mn,
    max: mx,
    nonManifoldSegments: Float32List.fromList(nmSegs),
    inconsistentSegments: Float32List.fromList(inSegs),
    milliseconds: sw.elapsedMilliseconds,
  );
}
