// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../src/datum_ffi.dart';
import 'pmi.dart';

enum SurfaceKind { other, plane, cylinder, cone, sphere, torus }

enum CurveKind { other, line, circle, arc }

/// Descripción exacta de una cara (en el sistema de coordenadas de su pieza, en mm).
class FaceInfo {
  FaceInfo(List<double> v)
    : kind = SurfaceKind.values[v[0].round().clamp(0, 5)],
      area = v[1],
      radius = v[2],
      minor = v[3],
      point = vm.Vector3(v[4], v[5], v[6]),
      axis = vm.Vector3(v[7], v[8], v[9]),
      length = v[10],
      sweep = v[11],
      concave = v[12] > 0.5;
  final SurfaceKind kind;
  final double area, radius, minor, length, sweep;
  final vm.Vector3 point, axis;
  final bool concave;
}

class EdgeInfo {
  EdgeInfo(List<double> v)
    : kind = CurveKind.values[v[0].round().clamp(0, 3)],
      length = v[1],
      radius = v[2],
      center = vm.Vector3(v[3], v[4], v[5]),
      axis = vm.Vector3(v[6], v[7], v[8]),
      start = vm.Vector3(v[9], v[10], v[11]),
      end = vm.Vector3(v[12], v[13], v[14]);
  final CurveKind kind;
  final double length, radius;
  final vm.Vector3 center, axis, start, end;
}

class PartProps {
  PartProps(List<double> v)
    : volume = v[0],
      area = v[1],
      centroid = vm.Vector3(v[2], v[3], v[4]),
      fileVolume = v[7] > 0.5 && v[5] > 0 ? v[5] : null,
      fileArea = v[7] > 0.5 && v[6] > 0 ? v[6] : null;
  final double volume, area;
  final vm.Vector3 centroid;

  /// Valores que el programa de origen guardó en el archivo, si los hay.
  final double? fileVolume, fileArea;

  /// ¿El volumen calculado coincide con el del archivo? null si no hay dato.
  bool? get volumeMatches => fileVolume == null || volume <= 0
      ? null
      : ((volume - fileVolume!).abs() / volume) < 0.01;
}

/// Resultado de una medición de distancia exacta entre dos entidades.
class DistanceResult {
  DistanceResult(this.distance, this.a, this.b);
  final double distance;
  final vm.Vector3 a, b;
}

/// Geometría exacta (B-rep) mantenida por el núcleo nativo mientras el documento está abierto.
class CadBrep {
  CadBrep(
    this._handle,
    this.unit,
    this.origin,
    this.schema, [
    this.pmi = const [],
  ]);

  /// Anotaciones del archivo (cotas, tolerancias, referencias).
  final List<PmiItem> pmi;
  final int _handle;
  bool _disposed = false;

  /// Unidad de longitud que declara el archivo ("MM", "INCH", "METRE"…).
  final String unit;
  final String origin;
  final String schema;

  Pointer<Void> get _p => Pointer<Void>.fromAddress(_handle);

  FaceInfo faceInfo(int part, int face) {
    if (_disposed) return FaceInfo(List.filled(14, 0));
    return using((arena) {
      final out = arena<Double>(14);
      datumPartFaceInfo(_p, part, face, out);
      return FaceInfo(out.asTypedList(14).toList());
    });
  }

  EdgeInfo edgeInfo(int part, int edge) {
    return using((arena) {
      final out = arena<Double>(15);
      datumPartEdgeInfo(_p, part, edge, out);
      return EdgeInfo(out.asTypedList(15).toList());
    });
  }

  final Map<int, PartProps> _props = {};
  PartProps props(int part) => _props.putIfAbsent(part, () {
    return using((arena) {
      final out = arena<Double>(8);
      datumPartProps(_p, part, out);
      return PartProps(out.asTypedList(8).toList());
    });
  });

  /// Distancia mínima exacta entre dos entidades colocadas en el mundo.
  DistanceResult? distance(
    int partA,
    bool edgeA,
    int idxA,
    vm.Matrix4 worldA,
    int partB,
    bool edgeB,
    int idxB,
    vm.Matrix4 worldB,
  ) {
    if (_disposed) return null;
    return using((arena) {
      final ma = arena<Double>(16), mb = arena<Double>(16);
      ma.asTypedList(16).setAll(0, worldA.storage);
      mb.asTypedList(16).setAll(0, worldB.storage);
      final out = arena<Double>(7);
      final ok = datumDistance(
        _p,
        partA,
        edgeA ? 1 : 0,
        idxA,
        ma,
        partB,
        edgeB ? 1 : 0,
        idxB,
        mb,
        out,
      );
      if (ok == 0) return null;
      final v = out.asTypedList(7);
      return DistanceResult(
        v[0],
        vm.Vector3(v[1], v[2], v[3]),
        vm.Vector3(v[4], v[5], v[6]),
      );
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    datumSceneFree(_p);
  }
}

/// Datos B-rep de una pieza que viajan con la malla.
class PartBrep {
  PartBrep({
    required this.faceOfTriangle,
    required this.faceCount,
    required this.edgeSegments,
    required this.edgeOfSegment,
    required this.edgeCount,
    this.materialName = '',
    this.materialDensity = 0,
  });

  /// Material que declara el archivo y su densidad en g/cm³ (0 = sin dato).
  final String materialName;
  final double materialDensity;

  /// Cara a la que pertenece cada triángulo.
  final Int32List faceOfTriangle;
  final int faceCount;

  /// Segmentos de las aristas vivas (6 floats cada uno) y a qué arista pertenecen.
  final Float32List edgeSegments;
  final Int32List edgeOfSegment;
  final int edgeCount;

  Object? gpuEdges; // buffer de GPU cacheado (aristas con color de contraste)

  Int32List? _faceStart, _edgeStart;

  /// Primer triángulo de cada cara (más uno al final); los triángulos de una cara son contiguos.
  Int32List get faceStart => _faceStart ??= _ranges(faceOfTriangle, faceCount);

  /// Primer segmento de cada arista (más uno al final).
  Int32List get edgeStart => _edgeStart ??= _ranges(edgeOfSegment, edgeCount);

  static Int32List _ranges(Int32List ids, int count) {
    final out = Int32List(count + 1);
    var i = 0;
    for (var f = 0; f < count; f++) {
      out[f] = i;
      while (i < ids.length && ids[i] == f) {
        i++;
      }
    }
    out[count] = ids.length;
    return out;
  }
}

/// Agujero reconocido: cilindros cóncavos coaxiales del mismo radio, unidos.
class Hole {
  Hole(this.radius, this.start, this.axis, this.depth, this.faces, this.full);
  final double radius;
  final vm.Vector3 start, axis;
  final double depth;
  final List<int> faces;
  final bool full;
  double get diameter => radius * 2;
}

/// Agrupa las caras cilíndricas cóncavas en agujeros.
List<Hole> findHoles(CadBrep brep, int part, int faceCount) {
  final cyl = <(int, FaceInfo)>[];
  for (var f = 0; f < faceCount; f++) {
    final i = brep.faceInfo(part, f);
    if (i.kind == SurfaceKind.cylinder && i.concave && i.radius > 0) {
      cyl.add((f, i));
    }
  }
  final used = <int>{};
  final holes = <Hole>[];
  for (final (f, i) in cyl) {
    if (used.contains(f)) continue;
    final group = [(f, i)];
    used.add(f);
    for (final (g, j) in cyl) {
      if (used.contains(g)) continue;
      if ((j.radius - i.radius).abs() > 1e-4 * i.radius) continue;
      if (j.axis.cross(i.axis).length > 1e-4) continue;
      final d = j.point - i.point;
      final perp = d - i.axis * d.dot(i.axis);
      if (perp.length > 1e-3 * math.max(1.0, i.radius)) continue;
      group.add((g, j));
      used.add(g);
    }
    var mn = double.infinity, mx = -double.infinity, sweep = 0.0;
    final ax = i.axis.normalized();
    for (final (_, j) in group) {
      final t0 = (j.point - i.point).dot(ax);
      final t1 = t0 + (j.axis.dot(ax) >= 0 ? j.length : -j.length);
      mn = math.min(mn, math.min(t0, t1));
      mx = math.max(mx, math.max(t0, t1));
      sweep += j.sweep;
    }
    holes.add(
      Hole(i.radius, i.point + ax * mn, ax, mx - mn, [
        for (final g in group) g.$1,
      ], sweep > 2 * math.pi * 0.97),
    );
  }
  holes.sort((a, b) => b.diameter.compareTo(a.diameter));
  return holes;
}
