// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'package:xml/xml.dart';

import 'vrml_parse.dart';
import '../l10n/l10n.dart';

/// Lee X3D en su codificación XML y lo vuelve al mismo árbol de nodos que VRML.
void parseX3dXml(String text, VrmlDoc doc) {
  final XmlDocument xml;
  try {
    xml = XmlDocument.parse(text);
  } on XmlException catch (e) {
    throw FormatException(tr('El X3D está mal formado: {m}', {'m': e.message}));
  }
  final root = xml.rootElement;
  XmlElement? scene;
  for (final c in root.childElements) {
    if (c.name.local == 'Scene') scene = c;
  }
  if (scene == null) throw FormatException(tr('El X3D no tiene escena (falta el elemento Scene)'));
  for (final c in scene.childElements) {
    final n = _conv(c, doc, 0);
    if (n != null) doc.top.add(n);
  }
}

const _geometryTypes = {
  'Box', 'Sphere', 'Cone', 'Cylinder', 'IndexedFaceSet', 'IndexedLineSet', 'PointSet', 'Extrusion', 'ElevationGrid', 'Text',
  'TriangleSet', 'IndexedTriangleSet', 'QuadSet', 'IndexedQuadSet', 'TriangleStripSet', 'IndexedTriangleStripSet',
  'TriangleFanSet', 'IndexedTriangleFanSet', 'LineSet', 'Arc2D', 'Circle2D', 'Disk2D', 'Rectangle2D',
};

const _containerOf = {
  'Appearance': 'appearance',
  'Material': 'material',
  'ImageTexture': 'texture',
  'PixelTexture': 'texture',
  'MovieTexture': 'texture',
  'TextureTransform': 'textureTransform',
  'Coordinate': 'coord',
  'Normal': 'normal',
  'Color': 'color',
  'ColorRGBA': 'color',
  'TextureCoordinate': 'texCoord',
  'FontStyle': 'fontStyle',
};

final _numList = RegExp(r'^[\s,+\-0-9.eE]+$');

Object _attr(String name, String value) {
  final v = value.trim();
  if (name == 'url' || name == 'string' || name == 'info' || name == 'name' || name == 'title') {
    final list = [for (final m in RegExp(r'"((?:[^"\\]|\\.)*)"').allMatches(v)) m.group(1)!];
    return list.isNotEmpty ? list : v;
  }
  if (v == 'true') return true;
  if (v == 'false') return false;
  if (v.isNotEmpty && _numList.hasMatch(v)) {
    final out = <double>[];
    for (final p in v.split(RegExp(r'[\s,]+'))) {
      if (p.isEmpty) continue;
      final d = double.tryParse(p);
      if (d == null) return v;
      out.add(d);
    }
    return out;
  }
  return v;
}

Object? _conv(XmlElement e, VrmlDoc doc, int depth) {
  if (depth > 300) throw FormatException(tr('X3D con anidamiento excesivo'));
  final type = e.name.local;
  final use = e.getAttribute('USE');
  if (use != null) return VUse(use);
  if (type == 'ROUTE') {
    final a = e.getAttribute('fromNode'), b = e.getAttribute('fromField'), c = e.getAttribute('toNode'), d = e.getAttribute('toField');
    if (a != null && b != null && c != null && d != null) doc.routes.add((a, b, c, d));
    return null;
  }
  if (type == 'ProtoDeclare' || type == 'ExternProtoDeclare' || type == 'IMPORT' || type == 'EXPORT' || type == 'meta' || type == 'head') {
    return null;
  }
  if (++doc.nodeCount > VrmlParser.maxNodes) throw FormatException(tr('El X3D tiene demasiados nodos'));
  final n = VNode(type, e.getAttribute('DEF'));
  for (final a in e.attributes) {
    final k = a.name.local;
    if (k == 'DEF' || k == 'USE' || k == 'containerField') continue;
    n.fields[k] = _attr(k, a.value);
  }
  // en X3D `Transform.scale` y `Box.size` ya tienen el mismo nombre que en VRML
  for (final c in e.childElements) {
    final child = _conv(c, doc, depth + 1);
    if (child == null) continue;
    final ct = c.name.local;
    final cf = c.getAttribute('containerField') ?? _containerOf[ct] ?? (_geometryTypes.contains(ct) ? 'geometry' : 'children');
    if (cf == 'children' || cf == 'choice' || cf == 'level') {
      final cur = n.fields[cf];
      if (cur is List<Object>) {
        cur.add(child);
      } else {
        n.fields[cf] = <Object>[child];
      }
    } else {
      n.fields[cf] = child;
    }
  }
  if (n.def != null) doc.defs[n.def!] = n;
  return n;
}
