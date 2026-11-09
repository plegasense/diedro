// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/mesh.dart';
import '../model/mesh_check.dart';
import '../l10n/l10n.dart';

/// Datos del archivo STL (formato, cabecera, color) asociados a su malla.
final stlMetaOf = Expando<StlMeta>();

/// Lee un STL (binario o ASCII) en un isolate para no bloquear la interfaz.
Future<Mesh> loadStl(String path) async {
  final lang = L.lang;
  final data = await Isolate.run(() {
    L.lang = lang; // el isolate no hereda el idioma
    return _parse(File(path).readAsBytesSync());
  });
  final mesh = Mesh(
    vertices: data.vertices.materialize().asFloat32List(),
    bounds: Bounds(data.min, data.max),
  );
  stlMetaOf[mesh] = StlMeta(
    binary: data.binary,
    header: data.header,
    solids: data.solids,
    bytes: data.bytes,
    colored: data.colored,
    skipped: data.skipped,
    colors: data.colors?.materialize().asUint16List(),
    defaultColor: data.defaultColor,
  );
  return mesh;
}

class _Parsed {
  _Parsed(
    this.vertices,
    this.min,
    this.max, {
    required this.binary,
    required this.header,
    required this.solids,
    required this.bytes,
    required this.colored,
    required this.skipped,
    this.colors,
    this.defaultColor,
  });
  final TransferableTypedData? colors;
  final List<int>? defaultColor;
  final TransferableTypedData vertices;
  final List<double> min;
  final List<double> max;
  final bool binary, colored;
  final String header;
  final int solids, bytes, skipped;
}

bool _isBinary(Uint8List b) {
  if (b.length < 84) return false;
  final count = ByteData.sublistView(b).getUint32(80, Endian.little);
  if (84 + count * 50 == b.length) return true;
  // Un STL ASCII empieza por "solid" y enseguida trae "facet"; un binario truncado
  // puede empezar también por "solid" (nombre del programa) sin tener "facet".
  // (puede haber espacios delante y estar en mayúsculas: «  SOLID Untitled»)
  final probe = latin1
      .decode(b.sublist(0, math.min(4096, b.length)))
      .toLowerCase();
  if (!probe.trimLeft().startsWith('solid')) return true;
  return !probe.contains('facet');
}

String _headerText(Uint8List b) {
  final n = math.min(80, b.length);
  final out = StringBuffer();
  for (var i = 0; i < n; i++) {
    final c = b[i];
    if (c == 0) break;
    out.writeCharCode(c >= 32 && c < 127 ? c : 32);
  }
  return out.toString().trim();
}

_Parsed _parse(Uint8List bytes) {
  final binary = _isBinary(bytes);
  var colored = false;
  var skipped = 0;
  var solids = 1;
  var header = '';
  Uint16List? colors;
  List<int>? defaultColor;
  Float32List verts;
  if (binary) {
    header = _headerText(bytes);
    // Color por triángulo al estilo Magics: la cabecera lo anuncia con «COLOR=».
    final r = _binary(bytes, header.contains('COLOR='));
    verts = r.$1;
    skipped = r.$2;
    colored = r.$3;
    colors = r.$4;
    if (colored) {
      final at = String.fromCharCodes(
        bytes.sublist(0, math.min(80, bytes.length)),
      ).indexOf('COLOR=');
      if (at >= 0 && at + 10 <= 80) {
        defaultColor = [bytes[at + 6], bytes[at + 7], bytes[at + 8]];
      }
    }
  } else {
    final r = _ascii(bytes);
    verts = r.$1;
    skipped = r.$2;
    solids = r.$3;
    final firstLine = latin1
        .decode(bytes.sublist(0, math.min(120, bytes.length)))
        .split('\n')
        .first;
    header = firstLine
        .replaceFirst(RegExp(r'^\s*solid\s*', caseSensitive: false), '')
        .trim();
  }
  final mn = [double.infinity, double.infinity, double.infinity];
  final mx = [-double.infinity, -double.infinity, -double.infinity];
  for (var i = 0; i < verts.length; i += 6) {
    for (var k = 0; k < 3; k++) {
      final v = verts[i + k];
      if (v < mn[k]) mn[k] = v;
      if (v > mx[k]) mx[k] = v;
    }
  }
  if (verts.isEmpty) {
    throw Exception(
      binary
          ? tr('El archivo STL no contiene triángulos (¿está vacío o dañado?).')
          : tr('No se han encontrado triángulos en este STL de texto. ¿Es realmente un STL?'),
    );
  }
  return _Parsed(
    TransferableTypedData.fromList([verts]),
    mn,
    mx,
    binary: binary,
    header: header.length > 60 ? header.substring(0, 60) : header,
    solids: solids,
    bytes: bytes.length,
    colored: colored,
    skipped: skipped,
    colors: colors == null ? null : TransferableTypedData.fromList([colors]),
    defaultColor: defaultColor,
  );
}

(Float32List, int, bool, Uint16List?) _binary(Uint8List b, bool magicsColor) {
  final bd = ByteData.sublistView(b);
  var count = bd.getUint32(80, Endian.little);
  final maxCount = (b.length - 84) ~/ 50;
  if (count > maxCount) count = maxCount; // archivo truncado
  final out = Float32List(count * 18);
  var o = 0;
  var skipped = 0;
  final colors = magicsColor ? Uint16List(count) : null;
  var nColor = 0;
  var base = 84 + 12; // se salta la normal del archivo: se recalcula
  for (var t = 0; t < count; t++, base += 50) {
    final ax = bd.getFloat32(base, Endian.little);
    final ay = bd.getFloat32(base + 4, Endian.little);
    final az = bd.getFloat32(base + 8, Endian.little);
    final bx = bd.getFloat32(base + 12, Endian.little);
    final by = bd.getFloat32(base + 16, Endian.little);
    final bz = bd.getFloat32(base + 20, Endian.little);
    final cx = bd.getFloat32(base + 24, Endian.little);
    final cy = bd.getFloat32(base + 28, Endian.little);
    final cz = bd.getFloat32(base + 32, Endian.little);
    final attr = bd.getUint16(base + 36, Endian.little);
    if (!(ax.isFinite &&
        ay.isFinite &&
        az.isFinite &&
        bx.isFinite &&
        by.isFinite &&
        bz.isFinite &&
        cx.isFinite &&
        cy.isFinite &&
        cz.isFinite)) {
      skipped++;
      continue;
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
    if (colors != null) colors[nColor++] = attr;
    out[o] = ax;
    out[o + 1] = ay;
    out[o + 2] = az;
    out[o + 3] = nx;
    out[o + 4] = ny;
    out[o + 5] = nz;
    out[o + 6] = bx;
    out[o + 7] = by;
    out[o + 8] = bz;
    out[o + 9] = nx;
    out[o + 10] = ny;
    out[o + 11] = nz;
    out[o + 12] = cx;
    out[o + 13] = cy;
    out[o + 14] = cz;
    out[o + 15] = nx;
    out[o + 16] = ny;
    out[o + 17] = nz;
    o += 18;
  }
  return (
    o == out.length ? out : Float32List.sublistView(out, 0, o),
    skipped,
    magicsColor,
    colors == null ? null : Uint16List.sublistView(colors, 0, nColor),
  );
}

(Float32List, int, int) _ascii(Uint8List b) {
  final text = utf8.decode(b, allowMalformed: true);
  final re = RegExp(r'vertex\s+(\S+)\s+(\S+)\s+(\S+)', caseSensitive: false);
  final pts = <double>[];
  var skipped = 0;
  for (final m in re.allMatches(text)) {
    final x = double.tryParse(m.group(1)!),
        y = double.tryParse(m.group(2)!),
        z = double.tryParse(m.group(3)!);
    if (x == null ||
        y == null ||
        z == null ||
        !x.isFinite ||
        !y.isFinite ||
        !z.isFinite) {
      // se descarta el vértice y, al cerrar, el triángulo incompleto
      skipped++;
      pts.addAll([double.nan, double.nan, double.nan]);
      continue;
    }
    pts.add(x);
    pts.add(y);
    pts.add(z);
  }
  final solids = RegExp(
    r'endsolid',
    caseSensitive: false,
  ).allMatches(text).length;
  final tris = pts.length ~/ 9;
  final out = Float32List(tris * 18);
  var o = 0;
  for (var t = 0; t < tris; t++) {
    final p = pts.sublist(t * 9, t * 9 + 9);
    if (p.any((e) => e.isNaN)) continue;
    final ux = p[3] - p[0], uy = p[4] - p[1], uz = p[5] - p[2];
    final vx = p[6] - p[0], vy = p[7] - p[1], vz = p[8] - p[2];
    var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    final len = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 0) {
      nx /= len;
      ny /= len;
      nz /= len;
    }
    for (var v = 0; v < 3; v++) {
      out[o++] = p[v * 3];
      out[o++] = p[v * 3 + 1];
      out[o++] = p[v * 3 + 2];
      out[o++] = nx;
      out[o++] = ny;
      out[o++] = nz;
    }
  }
  return (
    o == out.length ? out : Float32List.sublistView(out, 0, o),
    skipped,
    math.max(1, solids),
  );
}
