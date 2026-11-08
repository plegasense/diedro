import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/material.dart';
import '../model/mesh_info.dart';
import '../model/rig.dart';
import 'mesh_data.dart';
import 'obj_loader.dart' show SiblingFiles;
import 'rich_mesh.dart';
import 'vrml_geom.dart';
import 'vrml_parse.dart';
import 'x3d_xml.dart';
import '../l10n/l10n.dart';

/// Lector de VRML 1.0, VRML 97 (2.0) y X3D en codificación clásica o XML.
///
/// Soporta grupos y transformaciones, `DEF/USE`, `PROTO`, `Inline`, `Switch`/`LOD`, materiales con
/// transparencia y emisión, texturas (archivo, píxeles incrustados y `data:`), y las geometrías
/// `IndexedFaceSet`, `Box`, `Sphere`, `Cone`, `Cylinder`, `Extrusion`, `ElevationGrid`,
/// `IndexedLineSet`, `PointSet` y los conjuntos de triángulos y cuadriláteros de X3D.
final bool _timing = const String.fromEnvironment('DATUM_CAD').isNotEmpty || Platform.environment.containsKey('VRML_TIMING');

SceneData parseVrml(String path, {List<String> extraDirs = const []}) {
  try {
    return _parse(path, extraDirs);
  } on FormatException {
    rethrow;
  } on Error catch (e) {
    throw FormatException(tr('El archivo VRML está dañado o no tiene el formato esperado ({t})', {'t': e.runtimeType}));
  }
}

List<double> _id() => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

List<double> _mul(List<double> a, List<double> b) {
  final r = List<double>.filled(16, 0);
  for (var c = 0; c < 4; c++) {
    for (var rr = 0; rr < 4; rr++) {
      var s = 0.0;
      for (var k = 0; k < 4; k++) {
        s += a[k * 4 + rr] * b[c * 4 + k];
      }
      r[c * 4 + rr] = s;
    }
  }
  return r;
}

List<double> _translate(double x, double y, double z) => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1];
List<double> _scale(double x, double y, double z) => [x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1];
List<double> _rotation(double x, double y, double z, double a) {
  final l = math.sqrt(x * x + y * y + z * z);
  if (l < 1e-12 || a == 0) return _id();
  x /= l;
  y /= l;
  z /= l;
  final c = math.cos(a), s = math.sin(a), t = 1 - c;
  return [
    t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0,
    t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0,
    t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0,
    0, 0, 0, 1,
  ];
}

const _groupTypes = {
  'Group', 'Transform', 'Anchor', 'WWWAnchor', 'Collision', 'Billboard', 'StaticGroup', 'CADAssembly', 'CADPart', 'CADLayer',
  'CADFace', 'GeoTransform', 'GeoLocation', 'Layer', 'LayerSet', 'ViewpointGroup', 'Separator', 'TransformSeparator',
};

const _silent = {
  'WorldInfo', 'NavigationInfo', 'Viewpoint', 'Background', 'Fog', 'DirectionalLight', 'PointLight', 'SpotLight', 'Info',
  'PerspectiveCamera', 'OrthographicCamera', 'LightSource', 'HAnimHumanoid', 'MetadataString', 'MetadataDouble', 'MetadataFloat',
  'MetadataInteger', 'MetadataSet', 'ProfileInfo', 'ComponentInfo', 'Appearance', 'Material', 'Coordinate', 'Normal', 'Color',
  'ColorRGBA', 'TextureCoordinate', 'ImageTexture', 'PixelTexture', 'TextureTransform', 'FontStyle', 'LineProperties',
};

const _behaviour = {
  'TimeSensor', 'TouchSensor', 'ProximitySensor', 'VisibilitySensor', 'CylinderSensor', 'PlaneSensor', 'SphereSensor',
  'Script', 'Sound', 'AudioClip', 'CollisionSensor', 'KeySensor', 'StringSensor',
};

const _interpolators = {
  'PositionInterpolator', 'OrientationInterpolator', 'ColorInterpolator', 'ScalarInterpolator', 'CoordinateInterpolator',
  'NormalInterpolator', 'PositionInterpolator2D', 'BooleanSequencer', 'IntegerSequencer', 'TimeSensor',
};

class _Trs {
  _Trs(this.t, this.q, this.s, this.c, this.fixed);
  final List<double> t, q, s, c;

  /// Con `scaleOrientation` no nulo la matriz no se descompone: no se anima.
  final bool fixed;
}

List<double> _axisAngleQuat(double x, double y, double z, double a) {
  final l = math.sqrt(x * x + y * y + z * z);
  if (l < 1e-12) return [0, 0, 0, 1];
  final sn = math.sin(a / 2) / l;
  return [x * sn, y * sn, z * sn, math.cos(a / 2)];
}

class _Ctx {
  _Ctx(this.doc, this.info, this.sib);
  final VrmlDoc doc;
  final MeshFileInfo info;
  final SiblingFiles sib;
  final meshes = <MeshData>[];
  final nodes = <NodeData>[];
  final materials = <SurfaceMaterial>[];
  final textures = <SceneTexture>[];
  final skipped = <String, int>{};
  final texIndex = <String, int>{};
  final matCache = <Object, int?>{};
  final meshCache = <VNode, Map<Object, int?>>{};
  var shapeCount = 0;
  var inlineDepth = 0;
  var badFaces = 0;
  final inlineMissing = <String>{};
  final inlineDirs = <String>[];
  final v1Apps = <String, VNode>{};

  /// Nombre DEF → índice de nodo (antes de la poda) y su posición/giro/escala, para las animaciones.
  final defNode = <String, int>{};
  final trs = <int, _Trs>{};

  void skip(String type) => skipped[type] = (skipped[type] ?? 0) + 1;

  VNode? res(Object? o) {
    if (o is VUse) return doc.defs[o.name];
    return o is VNode ? o : null;
  }
}

List<double> _f(Object? o) => o is List<double> ? o : (o is num ? [o.toDouble()] : const []);
double _d(Object? o, double def) {
  final l = _f(o);
  return l.isEmpty ? def : l[0];
}

bool _b(Object? o, bool def) => o is bool ? o : def;

String? _firstString(Object? o) {
  if (o is String) return o;
  if (o is List<String> && o.isNotEmpty) return o.first;
  return null;
}

SceneData _parse(String path, List<String> extraDirs) {
  final name = path.split('/').last;
  final sw0 = Stopwatch()..start();
  final text = readVrmlText(path);
  if (_timing) {
    // ignore: avoid_print
    print('VRML lectura de texto ${sw0.elapsedMilliseconds} ms');
  }
  final header = text.trimLeft().startsWith('#') ? text.trimLeft().split(RegExp(r'[\r\n]')).first : '';
  final isXml = text.trimLeft().startsWith('<?xml') || text.trimLeft().startsWith('<X3D');
  final v1 = header.startsWith('#VRML V1');
  final info = MeshFileInfo(
    isXml
        ? 'X3D (XML)'
        : (v1 ? 'VRML 1.0' : (header.startsWith('#X3D') ? 'X3D ${header.split(' ').length > 1 ? header.split(' ')[1].replaceFirst('V', '') : ''}'.trim() : 'VRML 97')),
  )..up = 'y';
  info.generator = _generator(text);
  final sw = Stopwatch()..start();
  final doc = VrmlDoc();
  if (isXml) {
    parseX3dXml(text, doc);
  } else {
    final toks = VTokens(text);
    final tTok = sw.elapsedMilliseconds;
    VrmlParser(toks, doc).parseTop();
    if (_timing) {
      // ignore: avoid_print
      print('VRML tokens $tTok ms · árbol ${sw.elapsedMilliseconds - tTok} ms');
    }
  }
  final dir = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '.';
  final ctx = _Ctx(doc, info, SiblingFiles([dir, ...extraDirs]));
  ctx.inlineDirs.add(dir);

  // raíz
  ctx.nodes.add(NodeData(name, -1, -1, _id(), null));
  if (v1) {
    final st = _V1State();
    for (final n in doc.top) {
      _visitV1(ctx, n, 0, st, 0);
    }
  } else {
    for (final n in doc.top) {
      _visit(ctx, n, 0, 0);
    }
  }
  if (_timing) {
    // ignore: avoid_print
    print('VRML escena ${sw.elapsedMilliseconds} ms');
  }
  final map = _prune(ctx);
  _buildRig(ctx, map);
  if (ctx.meshes.isEmpty) {
    if (ctx.skipped.isNotEmpty) {
      throw FormatException(tr('El VRML no contiene geometría que se pueda dibujar (hay: {l})', {'l': ctx.skipped.keys.take(5).join(', ')}));
    }
    throw FormatException(tr('El VRML no contiene geometría'));
  }
  _finishInfo(ctx, path);
  return SceneData(name, ctx.meshes, const [], nodes: ctx.nodes, materials: ctx.materials, textures: ctx.textures, extra: info);
}

String _generator(String text) {
  final head = text.length > 4000 ? text.substring(0, 4000) : text;
  const known = [
    ('Blender', 'Blender'),
    ('Mathematica', 'Mathematica'),
    ('KrystalShaper', 'KrystalShaper'),
    ('SolidWorks', 'SolidWorks'),
    ('Pro/ENGINEER', 'Pro/ENGINEER'),
    ('Creo', 'Creo'),
    ('3ds max', '3ds Max'),
    ('3D Studio', '3D Studio'),
    ('MeshLab', 'MeshLab'),
    ('Cinema 4D', 'Cinema 4D'),
    ('X3dToVrml97', 'X3D → VRML (XSLT de Web3D)'),
    ('Jmol', 'Jmol'),
    ('Mercury', 'Mercury (CCDC)'),
    ('CATIA', 'CATIA'),
    ('Rhino', 'Rhino'),
    ('AutoCAD', 'AutoCAD'),
    ('Inventor', 'Inventor'),
    ('Maya', 'Maya'),
    ('Cosmo', 'Cosmo Worlds'),
    ('Vrml97Export', 'Vrml97Export'),
  ];
  for (final k in known) {
    if (head.contains(k.$1)) return k.$2;
  }
  return '';
}

/// Quita los grupos sin geometría debajo y reindexa. Devuelve el índice nuevo de cada nodo (−1 si se quitó).
List<int> _prune(_Ctx c) {
  final n = c.nodes.length;
  final keep = List<bool>.filled(n, false);
  for (var i = n - 1; i >= 0; i--) {
    if (c.nodes[i].part >= 0) keep[i] = true;
    if (keep[i] && c.nodes[i].parent >= 0) keep[c.nodes[i].parent] = true;
  }
  // los nodos que una animación mueve se conservan aunque no tengan geometría propia debajo
  keep[0] = true;
  final map = List<int>.filled(n, -1);
  final out = <NodeData>[];
  for (var i = 0; i < n; i++) {
    if (!keep[i]) continue;
    map[i] = out.length;
    final o = c.nodes[i];
    out.add(NodeData(o.name, o.parent < 0 ? -1 : map[o.parent], o.part, o.matrix, o.color, tag: [4, out.length]));
  }
  c.nodes
    ..clear()
    ..addAll(out);
  return map;
}

/// Animaciones de VRML: cada `TimeSensor` con sus `PositionInterpolator` / `OrientationInterpolator`
/// encaminados (ROUTE) a la traslación, el giro o la escala de un `Transform`.
void _buildRig(_Ctx c, List<int> map) {
  final doc = c.doc;
  final sensors = <String, VNode>{}, interps = <String, VNode>{};
  for (final e in doc.defs.entries) {
    if (e.value.type == 'TimeSensor') sensors[e.key] = e.value;
    if (e.value.type == 'PositionInterpolator' || e.value.type == 'OrientationInterpolator') interps[e.key] = e.value;
  }
  if (sensors.isEmpty || interps.isEmpty || doc.routes.isEmpty) return;
  final n = c.nodes.length;
  final rig = Rig(n)
    ..t = Float32List(n * 3)
    ..r = Float32List(n * 4)
    ..s = Float32List(n * 3);
  rig.matrix = List<Float64List?>.filled(n, null);
  final center = Float32List(n * 3);
  var anyCenter = false;
  for (var i = 0; i < n; i++) {
    rig.parent.add(c.nodes[i].parent);
    rig.hasMatrix.add(false);
    rig.r[i * 4 + 3] = 1;
    rig.s[i * 3] = rig.s[i * 3 + 1] = rig.s[i * 3 + 2] = 1;
  }
  for (final e in c.trs.entries) {
    final i = map[e.key];
    if (i < 0) continue;
    final x = e.value;
    if (x.fixed) {
      rig.hasMatrix[i] = true;
      rig.matrix[i] = Float64List.fromList(c.nodes[i].matrix);
      continue;
    }
    for (var k = 0; k < 3; k++) {
      rig.t[i * 3 + k] = x.t[k];
      rig.s[i * 3 + k] = x.s[k];
      center[i * 3 + k] = x.c[k];
      if (x.c[k] != 0) anyCenter = true;
    }
    for (var k = 0; k < 4; k++) {
      rig.r[i * 4 + k] = x.q[k];
    }
  }
  // nodos que no son Transform: su matriz del archivo (identidad) queda fija
  for (var i = 0; i < n; i++) {
    if (!c.trs.keys.any((k) => map[k] == i)) {
      rig.hasMatrix[i] = true;
      rig.matrix[i] = Float64List.fromList(c.nodes[i].matrix);
    }
  }
  if (anyCenter) rig.center = center;

  for (final se in sensors.entries) {
    final dur = _d(se.value.fields['cycleInterval'], 1);
    if (!(dur > 0)) continue;
    final channels = <RigChannel>[];
    for (final r1 in doc.routes) {
      if (r1.$1 != se.key || r1.$2 != 'fraction_changed') continue;
      final ip = interps[r1.$3];
      if (ip == null || r1.$4 != 'set_fraction') continue;
      final key = _f(ip.fields['key']);
      final kv = _f(ip.fields['keyValue']);
      final isRot = ip.type == 'OrientationInterpolator';
      final comps = isRot ? 4 : 3;
      if (key.isEmpty || kv.length < key.length * comps) continue;
      for (final r2 in doc.routes) {
        if (r2.$1 != r1.$3 || r2.$2 != 'value_changed') continue;
        final target = c.defNode[r2.$3];
        if (target == null || map[target] < 0) continue;
        final f = r2.$4.replaceFirst('set_', '');
        final path = f == 'translation' ? 0 : (f == 'rotation' ? 1 : (f == 'scale' ? 2 : -1));
        if (path < 0 || (path == 1) != isRot) continue;
        final times = Float32List(key.length), vals = Float32List(key.length * comps);
        var ok = true;
        for (var k = 0; k < key.length; k++) {
          times[k] = key[k] * dur;
          if (k > 0 && times[k] < times[k - 1]) ok = false;
          if (isRot) {
            final q = _axisAngleQuat(kv[k * 4], kv[k * 4 + 1], kv[k * 4 + 2], kv[k * 4 + 3]);
            for (var j = 0; j < 4; j++) {
              vals[k * 4 + j] = q[j];
            }
          } else {
            for (var j = 0; j < 3; j++) {
              vals[k * 3 + j] = kv[k * 3 + j];
            }
          }
        }
        if (!ok) continue;
        channels.add(RigChannel(map[target], path, 0, times, vals));
      }
    }
    if (channels.isNotEmpty) rig.animations.add(RigAnimation(se.key, dur, channels));
  }
  if (rig.animations.isNotEmpty) {
    c.info.rig = rig;
    c.info.animations.addAll([
      for (final a in rig.animations) AnimationInfo(a.name, a.duration, a.channels.length),
    ]);
  }
}

void _finishInfo(_Ctx c, String path) {
  final info = c.info;
  info.meshes = c.meshes.length;
  info.nodes = c.nodes.length;
  info.hasUv = info.hasUv;
  final unsupported = c.skipped.entries.where((e) => !_silent.contains(e.key) && !_behaviour.contains(e.key) && !_interpolators.contains(e.key)).toList();
  final text = c.skipped.entries.where((e) => e.key == 'Text' || e.key == 'AsciiText').fold<int>(0, (a, e) => a + e.value);
  if (text > 0) info.warnings.add(text == 1
      ? tr('1 texto (Text) sin dibujar: el visor no traza tipos de letra de VRML.')
      : tr('{n} textos (Text) sin dibujar: el visor no traza tipos de letra de VRML.', {'n': text}));
  final interp = c.skipped.entries.where((e) => _interpolators.contains(e.key)).fold<int>(0, (a, e) => a + e.value);
  if (interp > 0 && info.rig == null) info.warnings.add(tr('El archivo está animado ({n} interpoladores o relojes), pero no se ha podido enlazar ninguna animación: se muestra su estado inicial.', {'n': interp}));
  if (interp > 0 && info.rig != null) info.warnings.add(tr('Animaciones: se reproducen las de posición, giro y escala; el resto de interpoladores se ignora.'));
  final script = c.skipped.entries.where((e) => _behaviour.contains(e.key) && !_interpolators.contains(e.key)).fold<int>(0, (a, e) => a + e.value);
  if (script > 0) info.warnings.add(tr('{n} nodos de interacción (Script, sensores, sonido) se ignoran.', {'n': script}));
  final others = unsupported.where((e) => e.key != 'Text' && e.key != 'AsciiText').toList();
  if (others.isNotEmpty) {
    info.warnings.add(tr('Nodos sin soporte (no se dibujan): {l}.', {'l': others.take(8).map((e) => '${e.key} ×${e.value}').join(', ')}));
  }
  if (c.doc.externProtoUses.isNotEmpty) {
    info.warnings.add(tr('PROTO externos que no se pueden leer: {l}.', {'l': c.doc.externProtoUses.keys.take(6).join(', ')}));
  }
  if (c.inlineMissing.isNotEmpty) {
    info.warnings.add(tr('Faltan {n} archivos citados por Inline: {l}.', {'n': c.inlineMissing.length, 'l': c.inlineMissing.take(4).join(', ')}));
    info.missing.addAll(c.inlineMissing);
  }
  if (c.badFaces > 0) info.warnings.add(tr('{n} caras con índices no válidos se han omitido.', {'n': c.badFaces}));
  final ext = _worldExtent(c);
  info.sizeNote = ext;
  if (ext > 400 || (ext > 0 && ext < 0.01)) {
    info.warnings.add(
      ext > 400
          ? tr('VRML no guarda unidades (por norma son metros) y este archivo mide {n} unidades: ¿están en milímetros? Las medidas se dan en las unidades del archivo.', {'n': (ext >= 100 ? ext.toStringAsFixed(0) : ext.toStringAsPrecision(3))})
          : tr('VRML no guarda unidades (por norma son metros) y este archivo mide {n} unidades: ¿están en otra unidad? Las medidas se dan en las unidades del archivo.', {'n': (ext >= 100 ? ext.toStringAsFixed(0) : ext.toStringAsPrecision(3))}),
    );
  }
}

/// Mayor dimensión de la escena ya colocada (todas las cajas de las piezas, con sus matrices).
double _worldExtent(_Ctx c) {
  final w = <List<double>>[];
  final mn = [double.infinity, double.infinity, double.infinity], mx = [-double.infinity, -double.infinity, -double.infinity];
  for (var i = 0; i < c.nodes.length; i++) {
    final n = c.nodes[i];
    final m = n.parent < 0 ? n.matrix : _mul(w[n.parent], n.matrix);
    w.add(m);
    if (n.part < 0) continue;
    final b = c.meshes[n.part];
    for (var k = 0; k < 8; k++) {
      final x = (k & 1) == 0 ? b.min[0] : b.max[0], y = (k & 2) == 0 ? b.min[1] : b.max[1], z = (k & 4) == 0 ? b.min[2] : b.max[2];
      final px = m[0] * x + m[4] * y + m[8] * z + m[12], py = m[1] * x + m[5] * y + m[9] * z + m[13], pz = m[2] * x + m[6] * y + m[10] * z + m[14];
      if (px < mn[0]) mn[0] = px;
      if (py < mn[1]) mn[1] = py;
      if (pz < mn[2]) mn[2] = pz;
      if (px > mx[0]) mx[0] = px;
      if (py > mx[1]) mx[1] = py;
      if (pz > mx[2]) mx[2] = pz;
    }
  }
  final e = [for (var k = 0; k < 3; k++) mx[k] - mn[k]];
  final m = e.reduce(math.max);
  worldBox = [...mn, ...mx];
  return m.isFinite ? m : 0;
}

/// Caja de la última escena leída (la usa la herramienta de comprobación).
List<double>? worldBox;

// ---------------------------------------------------------------- VRML 97 / X3D

List<double> _transformMatrix(VNode n) {
  if (n.type != 'Transform' && n.type != 'GeoTransform') return _id();
  List<double> f(String k, List<double> d) {
    final v = _f(n.fields[k]);
    return v.length >= d.length ? v : d;
  }

  final t = f('translation', [0, 0, 0]);
  final c = f('center', [0, 0, 0]);
  final r = f('rotation', [0, 0, 1, 0]);
  final s = f('scale', [1, 1, 1]);
  final so = f('scaleOrientation', [0, 0, 1, 0]);
  var m = _translate(t[0], t[1], t[2]);
  m = _mul(m, _translate(c[0], c[1], c[2]));
  m = _mul(m, _rotation(r[0], r[1], r[2], r[3]));
  m = _mul(m, _rotation(so[0], so[1], so[2], so[3]));
  m = _mul(m, _scale(s[0], s[1], s[2]));
  m = _mul(m, _rotation(so[0], so[1], so[2], -so[3]));
  m = _mul(m, _translate(-c[0], -c[1], -c[2]));
  return m;
}

Iterable<Object> _childList(Object? o) sync* {
  if (o is List<Object>) {
    yield* o;
  } else if (o is VNode || o is VUse) {
    yield o!;
  }
}

void _visit(_Ctx c, Object? o, int parent, int depth) {
  final n = c.res(o);
  if (n == null || depth > 200) return;
  final t = n.type;
  if (_groupTypes.contains(t) || n.fromProto) {
    final isGroup = t != 'Group' || n.def != null || n.fromProto;
    var me = parent;
    final m = _transformMatrix(n);
    if (isGroup || t != 'Group') {
      c.nodes.add(NodeData(n.def ?? (n.fromProto ? 'PROTO' : t), parent, -1, m, null));
      me = c.nodes.length - 1;
      if (t == 'Transform') {
        List<double> g(String k, List<double> d) {
          final v = _f(n.fields[k]);
          return v.length >= d.length ? v : d;
        }

        final r = g('rotation', [0, 0, 1, 0]), so = g('scaleOrientation', [0, 0, 1, 0]);
        c.trs[me] = _Trs(g('translation', [0, 0, 0]), _axisAngleQuat(r[0], r[1], r[2], r[3]), g('scale', [1, 1, 1]), g('center', [0, 0, 0]), so[3] != 0);
        if (n.def != null) c.defNode.putIfAbsent(n.def!, () => me);
      }
    }
    for (final k in [..._childList(n.fields['children']), ..._childList(n.fields['addChildren']), ...n.kids]) {
      _visit(c, k, me, depth + 1);
    }
    return;
  }
  switch (t) {
    case 'Switch':
      final which = _d(n.fields['whichChoice'], -1).toInt();
      final ch = [..._childList(n.fields['choice']), ..._childList(n.fields['children'])];
      if (which >= 0 && which < ch.length) _visit(c, ch[which], parent, depth + 1);
    case 'LOD':
      final ch = [..._childList(n.fields['level']), ..._childList(n.fields['children'])];
      if (ch.isNotEmpty) _visit(c, ch.first, parent, depth + 1);
    case 'Inline':
      _inline(c, n, parent, depth);
    case 'Viewpoint':
      _viewpoint(c, n, parent);
    case 'Shape':
      _shape(c, n, parent);
    default:
      c.skip(t);
  }
}

/// Matriz del mundo del nodo [i] (producto de las de sus ancestros).
List<double> _worldOf(_Ctx c, int i) {
  final chain = <int>[];
  for (var k = i; k >= 0; k = c.nodes[k].parent) {
    chain.add(k);
  }
  var m = _id();
  for (final k in chain.reversed) {
    m = _mul(m, c.nodes[k].matrix);
  }
  return m;
}

void _viewpoint(_Ctx c, VNode n, int parent) {
  if (c.info.views.length >= 64) return;
  final p = _f(n.fields['position']).length >= 3 ? _f(n.fields['position']) : const [0.0, 0.0, 10.0];
  final o = _f(n.fields['orientation']).length >= 4 ? _f(n.fields['orientation']) : const [0.0, 0.0, 1.0, 0.0];
  final w = _mul(_worldOf(c, parent), _mul(_translate(p[0], p[1], p[2]), _rotation(o[0], o[1], o[2], o[3])));
  final d = [-w[8], -w[9], -w[10]];
  final l = math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
  if (l < 1e-9) return;
  final desc = _firstString(n.fields['description']);
  c.info.views.add(
    ViewInfo(
      desc != null && desc.isNotEmpty ? desc : (n.def ?? tr('Vista {n}', {'n': c.info.views.length + 1})),
      [w[12], w[13], w[14]],
      [d[0] / l, d[1] / l, d[2] / l],
    ),
  );
}

void _inline(_Ctx c, VNode n, int parent, int depth) {
  final url = n.fields['url'];
  final refs = url is List<String> ? url : (url is String ? [url] : <String>[]);
  if (c.inlineDepth > 3) return;
  for (final r in refs) {
    final p = c.sib.find(r);
    if (p == null) continue;
    try {
      final sub = VrmlDoc();
      final text = readVrmlText(p);
      VrmlParser(VTokens(text), sub).parseTop();
      final saved = c.doc.defs.length;
      c.doc.defs.addAll(sub.defs);
      c.doc.protos.addAll(sub.protos);
      c.inlineDepth++;
      c.nodes.add(NodeData(n.def ?? r.split('/').last, parent, -1, _id(), null));
      final me = c.nodes.length - 1;
      for (final k in sub.top) {
        _visit(c, k, me, depth + 1);
      }
      c.inlineDepth--;
      if (saved < 0) return;
      return;
    } on FormatException {
      continue;
    }
  }
  if (refs.isNotEmpty) c.inlineMissing.add(refs.first.split('/').last);
}

void _shape(_Ctx c, VNode n, int parent) {
  final geom = c.res(n.fields['geometry']);
  final app = c.res(n.fields['appearance']);
  if (geom == null) return;
  final parentDef = c.nodes[parent].name;
  final label = n.def ?? geom.def ?? (parent > 0 && !_generic.contains(parentDef) ? parentDef : tr('Forma {n}', {'n': ++c.shapeCount}));
  final key = app ?? geom;
  final cache = c.meshCache.putIfAbsent(geom, () => {});
  int? mi;
  if (cache.containsKey(key)) {
    mi = cache[key];
  } else {
    mi = _meshFor(c, geom, app, label);
    cache[key] = mi;
  }
  if (mi == null) return;
  c.nodes.add(NodeData(label, parent, mi, _id(), null));
}

const _generic = {'Transform', 'Group', 'Anchor', 'PROTO', 'Collision', 'Billboard'};

int? _meshFor(_Ctx c, VNode geom, VNode? app, String label) {
  final sw = Stopwatch()..start();
  final raw = _geometry(c, geom);
  final tGeo = sw.elapsedMilliseconds;
  if (raw == null) {
    c.skip(geom.type);
    return null;
  }
  final mat = _material(c, app, raw.col != null || raw.faceColor != null);
  final md = raw.build(label, mat);
  if (_timing) {
    // ignore: avoid_print
    print('  forma $label: geometría $tGeo ms · malla ${sw.elapsedMilliseconds - tGeo} ms');
  }
  if (md == null) return null;
  c.meshes.add(md);
  final info = c.info;
  info.vertices += raw.pos.length ~/ 3;
  info.triangles += raw.tris.triangleCount;
  info.hasNormals = info.hasNormals || raw.nrm != null;
  info.hasUv = info.hasUv || raw.uv != null;
  info.hasColors = info.hasColors || raw.col != null || raw.faceColor != null;
  return c.meshes.length - 1;
}

RawGeo? _geometry(_Ctx c, VNode g) {
  switch (g.type) {
    case 'IndexedFaceSet':
      return _faceSet(c, g, g.fields['coordIndex'], 'coordIndex');
    case 'Box':
      final s = _f(g.fields['size']);
      return vrmlBox(s.length >= 3 ? s[0] : 2, s.length >= 3 ? s[1] : 2, s.length >= 3 ? s[2] : 2);
    case 'Sphere':
      return vrmlSphere(_d(g.fields['radius'], 1));
    case 'Cylinder':
      return vrmlCylinder(_d(g.fields['radius'], 1), _d(g.fields['height'], 2),
          side: _b(g.fields['side'], true), top: _b(g.fields['top'], true), bottom: _b(g.fields['bottom'], true));
    case 'Cone':
      return vrmlCone(_d(g.fields['bottomRadius'], 1), _d(g.fields['height'], 2),
          side: _b(g.fields['side'], true), bottom: _b(g.fields['bottom'], true));
    case 'Extrusion':
      final cs = _f(g.fields['crossSection']);
      final sp = _f(g.fields['spine']);
      final r = vrmlExtrusion(
        spine: sp.isEmpty ? [0, 0, 0, 0, 1, 0] : sp,
        cross: cs.isEmpty ? [1, 1, 1, -1, -1, -1, -1, 1, 1, 1] : cs,
        scale: _f(g.fields['scale']).isEmpty ? const [1, 1] : _f(g.fields['scale']),
        orientation: _f(g.fields['orientation']).isEmpty ? const [0, 0, 1, 0] : _f(g.fields['orientation']),
        beginCap: _b(g.fields['beginCap'], true),
        endCap: _b(g.fields['endCap'], true),
        ccw: _b(g.fields['ccw'], true),
      );
      if (r == null) return null;
      _crease(r, _d(g.fields['creaseAngle'], 0));
      return r;
    case 'ElevationGrid':
      final r = vrmlElevationGrid(
        xDim: _d(g.fields['xDimension'], 0).toInt(),
        zDim: _d(g.fields['zDimension'], 0).toInt(),
        xSpacing: _d(g.fields['xSpacing'], 1),
        zSpacing: _d(g.fields['zSpacing'], 1),
        height: _f(g.fields['height']),
        ccw: _b(g.fields['ccw'], true),
      );
      if (r == null) return null;
      _crease(r, _d(g.fields['creaseAngle'], 0));
      _elevationColors(c, g, r);
      return r;
    case 'IndexedLineSet':
      return _lines(c, g);
    case 'PointSet':
      final pts = _f(c.res(g.fields['coord'])?.fields['point']);
      if (pts.length < 3) return null;
      final list = <List<double>>[
        for (var i = 0; i + 2 < pts.length && i < 300000; i += 3) [pts[i], pts[i + 1], pts[i + 2]],
      ];
      return thinGeometry(points: list, radius: _boxDiag(pts) * 0.003);
    case 'IndexedTriangleSet' || 'TriangleSet' || 'IndexedQuadSet' || 'QuadSet':
      return _simpleSet(c, g);
    case 'Text' || 'AsciiText':
      c.skip('Text');
      return null;
    default:
      return null;
  }
}

double _boxDiag(List<double> p) {
  if (p.length < 3) return 1;
  final mn = [double.infinity, double.infinity, double.infinity], mx = [-double.infinity, -double.infinity, -double.infinity];
  for (var i = 0; i + 2 < p.length; i += 3) {
    for (var k = 0; k < 3; k++) {
      if (p[i + k] < mn[k]) mn[k] = p[i + k];
      if (p[i + k] > mx[k]) mx[k] = p[i + k];
    }
  }
  final d = math.sqrt(math.pow(mx[0] - mn[0], 2) + math.pow(mx[1] - mn[1], 2) + math.pow(mx[2] - mn[2], 2));
  return d.isFinite && d > 0 ? d : 1;
}

void _crease(RawGeo r, double angle) {
  if (angle <= 1e-6) {
    r.flat = true;
  } else {
    r.flat = false;
    r.creaseDot = angle >= math.pi ? -1.0 : math.cos(angle);
  }
}

void _elevationColors(_Ctx c, VNode g, RawGeo r) {
  final cn = c.res(g.fields['color']);
  final cols = _f(cn?.fields['color']);
  if (cols.isEmpty) return;
  final comps = cn!.type == 'ColorRGBA' ? 4 : 3;
  final xd = _d(g.fields['xDimension'], 0).toInt(), zd = _d(g.fields['zDimension'], 0).toInt();
  if (_b(g.fields['colorPerVertex'], true)) {
    final nv = r.pos.length ~/ 3;
    final col = Uint8List(nv * 4);
    for (var i = 0; i < nv && (i + 1) * comps <= cols.length; i++) {
      col[i * 4] = (cols[i * comps] * 255).round().clamp(0, 255);
      col[i * 4 + 1] = (cols[i * comps + 1] * 255).round().clamp(0, 255);
      col[i * 4 + 2] = (cols[i * comps + 2] * 255).round().clamp(0, 255);
      col[i * 4 + 3] = comps == 4 ? (cols[i * comps + 3] * 255).round().clamp(0, 255) : 255;
    }
    r.col = col;
  } else {
    final nt = r.tris.triangleCount;
    final fc = Float32List(nt * 4);
    for (var t = 0; t < nt; t++) {
      final cell = t ~/ 2; // dos triángulos por celda
      final ci = (cell % (xd - 1)) + (cell ~/ (xd - 1)) * (xd - 1);
      if (ci >= (xd - 1) * (zd - 1) || (ci + 1) * comps > cols.length) continue;
      fc[t * 4] = cols[ci * comps];
      fc[t * 4 + 1] = cols[ci * comps + 1];
      fc[t * 4 + 2] = cols[ci * comps + 2];
      fc[t * 4 + 3] = comps == 4 ? cols[ci * comps + 3] : 1;
    }
    r.faceColor = fc;
  }
}

RawGeo? _lines(_Ctx c, VNode g) {
  final pts = _f(c.res(g.fields['coord'])?.fields['point']);
  final idx = _f(g.fields['coordIndex']);
  if (pts.length < 6 || idx.isEmpty) return null;
  final segs = <List<double>>[];
  var prev = -1;
  for (final d in idx) {
    final v = d.toInt();
    if (v < 0) {
      prev = -1;
      continue;
    }
    if (v * 3 + 2 >= pts.length) {
      prev = -1;
      continue;
    }
    if (prev >= 0) {
      segs.add([pts[prev * 3], pts[prev * 3 + 1], pts[prev * 3 + 2], pts[v * 3], pts[v * 3 + 1], pts[v * 3 + 2]]);
    }
    prev = v;
    if (segs.length >= 400000) break;
  }
  return thinGeometry(segments: segs, radius: _boxDiag(pts) * 0.002);
}

RawGeo? _simpleSet(_Ctx c, VNode g) {
  final pts = _f(c.res(g.fields['coord'])?.fields['point']);
  if (pts.length < 9) return null;
  final nv = pts.length ~/ 3;
  final idx = <double>[];
  switch (g.type) {
    case 'TriangleSet':
      for (var i = 0; i + 2 < nv; i += 3) {
        idx.addAll([i.toDouble(), i + 1.0, i + 2.0, -1]);
      }
    case 'QuadSet':
      for (var i = 0; i + 3 < nv; i += 4) {
        idx.addAll([i.toDouble(), i + 1.0, i + 2.0, i + 3.0, -1]);
      }
    case 'IndexedTriangleSet':
      final ix = _f(g.fields['index']);
      for (var i = 0; i + 2 < ix.length; i += 3) {
        idx.addAll([ix[i], ix[i + 1], ix[i + 2], -1]);
      }
    default:
      final ix = _f(g.fields['index']);
      for (var i = 0; i + 3 < ix.length; i += 4) {
        idx.addAll([ix[i], ix[i + 1], ix[i + 2], ix[i + 3], -1]);
      }
  }
  final f = VNode('IndexedFaceSet', null)
    ..fields.addAll(g.fields)
    ..fields['coordIndex'] = idx;
  f.fields['normalPerVertex'] = true;
  f.fields['colorPerVertex'] = true;
  f.fields['creaseAngle'] = 0.0;
  return _faceSet(c, f, idx, 'coordIndex');
}

/// IndexedFaceSet con sus normales, colores y UV indexados por esquina o por cara.
RawGeo? _faceSet(_Ctx c, VNode g, Object? coordIndexField, String _) {
  final coordNode = c.res(g.fields['coord']);
  final pts = _f(coordNode?.fields['point']);
  final cIdx = _f(coordIndexField);
  final nv = pts.length ~/ 3;
  if (nv < 3 || cIdx.isEmpty) return null;
  final pos = Float32List(nv * 3);
  for (var i = 0; i < pos.length; i++) {
    final v = pts[i];
    pos[i] = v.isFinite ? v : 0;
  }
  final ccw = _b(g.fields['ccw'], true);

  final nrmNode = c.res(g.fields['normal']);
  final nrmArr = _f(nrmNode?.fields['vector']);
  final nIdx = _f(g.fields['normalIndex']);
  final nPerVertex = _b(g.fields['normalPerVertex'], true);
  final colNode = c.res(g.fields['color']);
  final colArr = _f(colNode?.fields['color']);
  final colComps = colNode?.type == 'ColorRGBA' ? 4 : 3;
  final cOff = _f(g.fields['colorIndex']);
  final cPerVertex = _b(g.fields['colorPerVertex'], true);
  final texNode = c.res(g.fields['texCoord']);
  final texArr = _f(texNode?.fields['point']);
  final tIdx = _f(g.fields['texCoordIndex']);

  final haveN = nrmArr.length >= 3;
  final haveT = texArr.length >= 2;
  final haveC = colArr.length >= colComps;
  final tris = CornerTris(withUv: haveT, withNrm: haveN);
  final col8 = haveC && cPerVertex ? Uint8List(nv * 4) : null;
  final colSeen = col8 == null ? null : Uint8List(nv);
  var colConflict = false;
  final faceCols = <double>[]; // por triángulo (si hay color por cara o conflictos)

  List<double> colorOf(int ci) {
    if (ci < 0 || (ci + 1) * colComps > colArr.length) return const [0.8, 0.8, 0.8, 1];
    return [colArr[ci * colComps], colArr[ci * colComps + 1], colArr[ci * colComps + 2], colComps == 4 ? colArr[ci * colComps + 3] : 1];
  }

  var face = 0;
  final poly = <int>[], pk = <int>[];
  var polygons = 0;
  int uvAt(int k) {
    if (!haveT) return -1;
    return tIdx.isNotEmpty ? (k < tIdx.length ? tIdx[k].toInt() : -1) : cIdx[k].toInt();
  }

  int nAt(int k) {
    if (!haveN) return -1;
    if (nPerVertex) {
      return nIdx.isNotEmpty ? (k < nIdx.length ? nIdx[k].toInt() : -1) : cIdx[k].toInt();
    }
    return nIdx.isNotEmpty ? (face < nIdx.length ? nIdx[face].toInt() : -1) : face;
  }

  void colorTri(int l0, int l1, int l2) {
    if (cPerVertex) {
      // color por esquina: si coincide con el de la posición se guarda ahí; si no, se usa el promedio por cara
      final cs = <List<double>>[];
      for (final l in [l0, l1, l2]) {
        final k = pk[l];
        final ci = cOff.isNotEmpty ? (k < cOff.length ? cOff[k].toInt() : -1) : cIdx[k].toInt();
        final col = colorOf(ci);
        cs.add(col);
        final p = poly[l];
        if (col8 != null) {
          final r = (col[0] * 255).round().clamp(0, 255), g2 = (col[1] * 255).round().clamp(0, 255), b2 = (col[2] * 255).round().clamp(0, 255);
          final al = (col[3] * 255).round().clamp(0, 255);
          if (colSeen![p] == 1 && (col8[p * 4] != r || col8[p * 4 + 1] != g2 || col8[p * 4 + 2] != b2)) colConflict = true;
          col8[p * 4] = r;
          col8[p * 4 + 1] = g2;
          col8[p * 4 + 2] = b2;
          col8[p * 4 + 3] = al;
          colSeen[p] = 1;
        }
      }
      faceCols.addAll([
        (cs[0][0] + cs[1][0] + cs[2][0]) / 3,
        (cs[0][1] + cs[1][1] + cs[2][1]) / 3,
        (cs[0][2] + cs[1][2] + cs[2][2]) / 3,
        (cs[0][3] + cs[1][3] + cs[2][3]) / 3,
      ]);
    } else {
      final ci = cOff.isNotEmpty ? (face < cOff.length ? cOff[face].toInt() : -1) : face;
      faceCols.addAll(colorOf(ci));
    }
  }

  void emit(int l0, int l1, int l2) {
    if (!ccw) {
      final tmp = l1;
      l1 = l2;
      l2 = tmp;
    }
    tris.tri(
      poly[l0], poly[l1], poly[l2],
      t0: uvAt(pk[l0]), t1: uvAt(pk[l1]), t2: uvAt(pk[l2]),
      n0: nAt(pk[l0]), n1: nAt(pk[l1]), n2: nAt(pk[l2]),
    );
    if (haveC) colorTri(l0, l1, l2);
  }

  void flush() {
    if (poly.length == 3) {
      polygons++;
      emit(0, 1, 2);
    } else if (poly.length > 3) {
      polygons++;
      final t = triangulatePolygon(pos, poly);
      for (var q = 0; q + 2 < t.length; q += 3) {
        emit(t[q], t[q + 1], t[q + 2]);
      }
    }
    poly.clear();
    pk.clear();
    face++;
  }

  for (var k = 0; k < cIdx.length; k++) {
    final v = cIdx[k];
    if (!v.isFinite) continue;
    final i = v.toInt();
    if (i < 0) {
      flush();
    } else if (i >= nv) {
      c.badFaces++;
      poly.clear();
      pk.clear();
      // se descarta el resto del polígono
      while (k + 1 < cIdx.length && cIdx[k + 1] >= 0) {
        k++;
      }
    } else {
      poly.add(i);
      pk.add(k);
    }
  }
  flush();
  if (tris.triangleCount == 0) return null;
  c.info.faces += polygons;

  final r = RawGeo(pos, tris);
  if (haveN) {
    r.nrm = Float32List.fromList(nrmArr.map((e) => e.isFinite ? e : 0.0).toList());
  }
  if (haveT) {
    // VRML mide V desde abajo; la textura se lee desde arriba
    final uv = Float32List(texArr.length - texArr.length % 2);
    for (var i = 0; i + 1 < uv.length; i += 2) {
      uv[i] = texArr[i];
      uv[i + 1] = 1 - texArr[i + 1];
    }
    r.uv = uv;
  }
  if (haveC) {
    if (cPerVertex && !colConflict && col8 != null) {
      // posiciones sin color (no usadas) quedan blancas
      for (var p = 0; p < nv; p++) {
        if (colSeen![p] == 0) {
          col8[p * 4] = 255;
          col8[p * 4 + 1] = 255;
          col8[p * 4 + 2] = 255;
          col8[p * 4 + 3] = 255;
        }
      }
      r.col = col8;
    } else {
      r.faceColor = Float32List.fromList(faceCols);
    }
  }
  _crease(r, _d(g.fields['creaseAngle'], 0));
  if (haveN) r.flat = false;
  return r;
}

// ---------------------------------------------------------------- materiales

int _argb(List<double> c, double alpha) {
  int ch(double v) => (v.isFinite ? v.clamp(0.0, 1.0) : 0.0) * 255 ~/ 1;
  return ((alpha.clamp(0.0, 1.0) * 255).round() << 24) | (ch(c[0]) << 16) | (ch(c[1]) << 8) | ch(c[2]);
}

int? _material(_Ctx c, VNode? app, bool vertexColors) {
  if (app == null) return null;
  final key = '${identityHashCode(app)}|$vertexColors';
  if (c.matCache.containsKey(key)) return c.matCache[key];
  final mat = c.res(app.fields['material']);
  final texNode = c.res(app.fields['texture']);
  final diffuse = _f(mat?.fields['diffuseColor']).length >= 3 ? _f(mat!.fields['diffuseColor']) : const [0.8, 0.8, 0.8];
  final emissive = _f(mat?.fields['emissiveColor']).length >= 3 ? _f(mat!.fields['emissiveColor']) : const [0.0, 0.0, 0.0];
  final transparency = _d(mat?.fields['transparency'], 0).clamp(0.0, 1.0);
  final specular = _f(mat?.fields['specularColor']).length >= 3 ? _f(mat!.fields['specularColor']) : const [0.0, 0.0, 0.0];
  final shininess = _d(mat?.fields['shininess'], 0.2).clamp(0.0, 1.0);

  int? tex;
  var texName = '';
  if (texNode != null) {
    tex = _texture(c, texNode);
    if (tex != null) texName = c.textures[tex].name;
  }
  final emissiveOn = emissive[0] + emissive[1] + emissive[2] > 1e-6;
  final unlit = mat == null || (emissiveOn && diffuse[0] + diffuse[1] + diffuse[2] < 1e-3);
  // un negro puro sobre el fondo oscuro no deja ver la forma: se sube hasta un gris muy oscuro
  List<double> readable(List<double> c) {
    final lum = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    if (lum >= 0.1) return c;
    final k = 0.1 - lum;
    return [c[0] + k, c[1] + k, c[2] + k];
  }

  final sm = SurfaceMaterial(
    name: mat?.def ?? app.def ?? tr('Material {n}', {'n': c.materials.length + 1}),
    baseColor: (tex != null || vertexColors) ? _argb(const [1, 1, 1], 1 - transparency) : _argb(unlit && emissiveOn ? emissive : readable(diffuse), 1 - transparency),
    texture: tex,
    doubleSided: true,
    emissive: emissiveOn && !unlit ? _argb(emissive, 1) : 0,
    unlit: unlit,
    roughness: (specular[0] + specular[1] + specular[2] > 0.05) ? (1 - 0.8 * shininess) : 1.0,
  );
  if (transparency > 0.001) sm.alphaMode = AlphaMode.blend;
  final tt = c.res(app.fields['textureTransform']);
  if (tt != null && tex != null) {
    final tl = _f(tt.fields['translation']), sc = _f(tt.fields['scale']);
    if (tl.length >= 2) {
      sm.uvOx = tl[0];
      sm.uvOy = -tl[1];
    }
    if (sc.length >= 2) {
      sm.uvSx = sc[0];
      sm.uvSy = sc[1];
    }
    sm.uvRot = -_d(tt.fields['rotation'], 0);
    final ct = _f(tt.fields['center']);
    if (ct.length >= 2 && (ct[0] != 0 || ct[1] != 0)) c.info.warnings.add(tr('TextureTransform con centro distinto de cero: la textura puede quedar desplazada.'));
  }
  if (texNode != null) {
    sm.wrapS = _b(texNode.fields['repeatS'], true) ? 0 : 1;
    sm.wrapT = _b(texNode.fields['repeatT'], true) ? 0 : 1;
  }
  c.materials.add(sm);
  final mi = MaterialInfo(sm.name, sm.baseColor)
    ..texture = texName.isEmpty ? null : texName
    ..alpha = sm.alphaMode == AlphaMode.blend ? 'mezcla' : 'opaco'
    ..emissive = sm.emissive != 0
    ..unlit = sm.unlit
    ..doubleSided = true
    ..roughness = sm.roughness;
  c.info.materials.add(mi);
  final idx = c.materials.length - 1;
  c.matCache[key] = idx;
  return idx;
}

int? _texture(_Ctx c, VNode t) {
  if (t.type == 'PixelTexture') {
    final img = _f(t.fields['image']);
    if (img.length < 3) return null;
    final w = img[0].toInt(), h = img[1].toInt(), comps = img[2].toInt();
    if (w <= 0 || h <= 0 || w * h > 4000000 || comps < 1 || comps > 4 || img.length < 3 + w * h) return null;
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      final v = img[3 + i].toInt();
      int r, g, b, a = 255;
      switch (comps) {
        case 1:
          r = g = b = v & 255;
        case 2:
          r = g = b = (v >> 8) & 255;
          a = v & 255;
        case 3:
          r = (v >> 16) & 255;
          g = (v >> 8) & 255;
          b = v & 255;
        default:
          r = (v >> 24) & 255;
          g = (v >> 16) & 255;
          b = (v >> 8) & 255;
          a = v & 255;
      }
      // VRML guarda la imagen de abajo arriba
      final row = h - 1 - i ~/ w;
      final o = (row * w + i % w) * 4;
      rgba[o] = r;
      rgba[o + 1] = g;
      rgba[o + 2] = b;
      rgba[o + 3] = a;
    }
    final key = 'pixel${identityHashCode(t)}';
    final cached = c.texIndex[key];
    if (cached != null) return cached;
    c.textures.add(SceneTexture('PixelTexture', encodePngRgba(w, h, rgba)));
    c.info.textures.add(TextureInfo('PixelTexture', width: w, height: h, role: 'color'));
    return c.texIndex[key] = c.textures.length - 1;
  }
  if (t.type != 'ImageTexture' && t.type != 'Texture2') return null;
  final urls = t.fields['url'] ?? t.fields['filename'];
  final refs = [
    for (final r in (urls is List<String> ? urls : (urls is String ? [urls] : <String>[])))
      if (r.trim().isNotEmpty) r,
  ];
  for (final r in refs) {
    final cached = c.texIndex[r];
    if (cached != null) return cached >= 0 ? cached : null;
    Uint8List? bytes;
    var nm = r.replaceAll('\\', '/').split('/').last;
    if (r.startsWith('data:')) {
      final comma = r.indexOf(',');
      if (comma > 0) {
        try {
          bytes = base64.decode(r.substring(comma + 1));
          nm = tr('imagen incrustada');
        } catch (_) {}
      }
    } else {
      final p = c.sib.find(r);
      if (p != null) bytes = File(p).readAsBytesSync();
    }
    if (bytes == null) continue;
    final ti = TextureInfo(nm, bytes: bytes.length, role: 'color');
    c.info.textures.add(ti);
    c.textures.add(SceneTexture(nm, bytes));
    return c.texIndex[r] = c.textures.length - 1;
  }
  if (refs.isNotEmpty) {
    final nm = refs.first.replaceAll('\\', '/').split('/').last;
    if (!c.texIndex.containsKey(refs.first)) {
      c.texIndex[refs.first] = -1;
      c.info.textures.add(TextureInfo(nm, role: 'color')..missing = true);
      c.info.missing.add(nm);
    }
  }
  return null;
}

// ---------------------------------------------------------------- VRML 1.0

class _V1State {
  _V1State();
  List<double> m = _id();
  VNode? material;
  List<double> coord = const [];
  List<double> normal = const [];
  List<double> tex = const [];
  String? textureFile;
  double crease = 0.5;
  bool ccw = true;
  bool solid = false;
  String matBinding = 'OVERALL';
  String nrmBinding = 'DEFAULT';
  VNode? textureNode;

  _V1State copy() => _V1State()
    ..m = List.of(m)
    ..material = material
    ..coord = coord
    ..normal = normal
    ..tex = tex
    ..textureFile = textureFile
    ..crease = crease
    ..ccw = ccw
    ..solid = solid
    ..matBinding = matBinding
    ..nrmBinding = nrmBinding
    ..textureNode = textureNode;
}

void _visitV1(_Ctx c, Object? o, int parent, _V1State st, int depth) {
  final n = c.res(o);
  if (n == null || depth > 200) return;
  final t = n.type;
  switch (t) {
    case 'Separator' || 'Group' || 'TransformSeparator' || 'WWWAnchor' || 'Anchor':
      final s2 = t == 'Group' || t == 'WWWAnchor' ? st : st.copy();
      var me = parent;
      if (n.def != null) {
        c.nodes.add(NodeData(n.def!, parent, -1, _id(), null));
        me = c.nodes.length - 1;
      }
      final saved = t == 'TransformSeparator' ? List.of(st.m) : null;
      for (final k in n.kids) {
        _visitV1(c, k, me, s2, depth + 1);
      }
      if (t == 'TransformSeparator' && saved != null) st.m = saved;
    case 'Switch':
      final which = _d(n.fields['whichChild'], -1).toInt();
      if (which >= 0 && which < n.kids.length) _visitV1(c, n.kids[which], parent, st.copy(), depth + 1);
      if (which == -3) {
        for (final k in n.kids) {
          _visitV1(c, k, parent, st.copy(), depth + 1);
        }
      }
    case 'LOD':
      if (n.kids.isNotEmpty) _visitV1(c, n.kids.first, parent, st.copy(), depth + 1);
    case 'Transform':
      List<double> g(String k, List<double> d) {
        final v = _f(n.fields[k]);
        return v.length >= d.length ? v : d;
      }

      final tl = g('translation', [0, 0, 0]), r = g('rotation', [0, 0, 1, 0]), s = g('scaleFactor', [1, 1, 1]);
      final so = g('scaleOrientation', [0, 0, 1, 0]), ce = g('center', [0, 0, 0]);
      var m = _translate(tl[0], tl[1], tl[2]);
      m = _mul(m, _translate(ce[0], ce[1], ce[2]));
      m = _mul(m, _rotation(r[0], r[1], r[2], r[3]));
      m = _mul(m, _rotation(so[0], so[1], so[2], so[3]));
      m = _mul(m, _scale(s[0], s[1], s[2]));
      m = _mul(m, _rotation(so[0], so[1], so[2], -so[3]));
      m = _mul(m, _translate(-ce[0], -ce[1], -ce[2]));
      st.m = _mul(st.m, m);
    case 'Translation':
      final v = _f(n.fields['translation']);
      if (v.length >= 3) st.m = _mul(st.m, _translate(v[0], v[1], v[2]));
    case 'Rotation':
      final v = _f(n.fields['rotation']);
      if (v.length >= 4) st.m = _mul(st.m, _rotation(v[0], v[1], v[2], v[3]));
    case 'Scale':
      final v = _f(n.fields['scaleFactor']);
      if (v.length >= 3) st.m = _mul(st.m, _scale(v[0], v[1], v[2]));
    case 'MatrixTransform':
      final v = _f(n.fields['matrix']);
      if (v.length >= 16) st.m = _mul(st.m, v.sublist(0, 16));
    case 'Material':
      st.material = n;
    case 'MaterialBinding':
      st.matBinding = (n.fields['value'] is String) ? n.fields['value'] as String : 'OVERALL';
    case 'NormalBinding':
      st.nrmBinding = (n.fields['value'] is String) ? n.fields['value'] as String : 'DEFAULT';
    case 'Coordinate3':
      st.coord = _f(n.fields['point']);
    case 'Normal':
      st.normal = _f(n.fields['vector']);
    case 'TextureCoordinate2':
      st.tex = _f(n.fields['point']);
    case 'Texture2':
      st.textureNode = n;
    case 'ShapeHints':
      st.crease = _d(n.fields['creaseAngle'], 0.5);
      st.ccw = n.fields['vertexOrdering'] != 'CLOCKWISE';
      st.solid = n.fields['shapeType'] == 'SOLID';
    case 'IndexedFaceSet' || 'IndexedLineSet' || 'PointSet' || 'Cube' || 'Sphere' || 'Cone' || 'Cylinder':
      _shapeV1(c, n, parent, st);
    case 'Info' || 'PerspectiveCamera' || 'OrthographicCamera' || 'DirectionalLight' || 'PointLight' || 'SpotLight' || 'LOD_' || 'FontStyle' || 'Texture2Transform' || 'WWWInline':
      break;
    case 'AsciiText':
      c.skip('Text');
    default:
      c.skip(t);
  }
}

void _shapeV1(_Ctx c, VNode g, int parent, _V1State st) {
  final label = g.def ?? tr('Forma {n}', {'n': ++c.shapeCount});
  VNode? geom;
  switch (g.type) {
    case 'Cube':
      geom = VNode('Box', null)..fields['size'] = [_d(g.fields['width'], 2), _d(g.fields['height'], 2), _d(g.fields['depth'], 2)];
    case 'Sphere':
      geom = VNode('Sphere', null)..fields['radius'] = [_d(g.fields['radius'], 1)];
    case 'Cone':
      geom = VNode('Cone', null)
        ..fields['bottomRadius'] = [_d(g.fields['bottomRadius'], 1)]
        ..fields['height'] = [_d(g.fields['height'], 2)];
    case 'Cylinder':
      geom = VNode('Cylinder', null)
        ..fields['radius'] = [_d(g.fields['radius'], 1)]
        ..fields['height'] = [_d(g.fields['height'], 2)];
    case 'IndexedFaceSet':
      geom = VNode('IndexedFaceSet', null)
        ..fields['coordIndex'] = _f(g.fields['coordIndex'])
        ..fields['coord'] = (VNode('Coordinate', null)..fields['point'] = st.coord)
        ..fields['ccw'] = st.ccw
        ..fields['creaseAngle'] = [st.crease];
      if (st.normal.isNotEmpty && st.nrmBinding.contains('VERTEX')) {
        geom.fields['normal'] = VNode('Normal', null)..fields['vector'] = st.normal;
        final ni = _f(g.fields['normalIndex']);
        if (ni.isNotEmpty && st.nrmBinding.contains('INDEXED')) geom.fields['normalIndex'] = ni;
      }
      if (st.tex.isNotEmpty) {
        geom.fields['texCoord'] = VNode('TextureCoordinate', null)..fields['point'] = st.tex;
        final ti = _f(g.fields['textureCoordIndex']);
        if (ti.isNotEmpty) geom.fields['texCoordIndex'] = ti;
      }
      final diff = _f(st.material?.fields['diffuseColor']);
      if (diff.length >= 6 && st.matBinding != 'OVERALL' && st.matBinding != 'DEFAULT') {
        geom.fields['color'] = VNode('Color', null)..fields['color'] = diff;
        final mi = _f(g.fields['materialIndex']);
        final perFace = st.matBinding.contains('FACE') || st.matBinding.contains('PART');
        geom.fields['colorPerVertex'] = !perFace;
        if (mi.isNotEmpty && st.matBinding.contains('INDEXED')) geom.fields['colorIndex'] = mi;
      }
    case 'IndexedLineSet':
      geom = VNode('IndexedLineSet', null)
        ..fields['coordIndex'] = _f(g.fields['coordIndex'])
        ..fields['coord'] = (VNode('Coordinate', null)..fields['point'] = st.coord);
    case 'PointSet':
      final start = _d(g.fields['startIndex'], 0).toInt();
      var num = _d(g.fields['numPoints'], -1).toInt();
      final all = st.coord;
      final from = (start * 3).clamp(0, all.length);
      final to = num < 0 ? all.length : (from + num * 3).clamp(from, all.length);
      geom = VNode('PointSet', null)..fields['coord'] = (VNode('Coordinate', null)..fields['point'] = all.sublist(from, to));
  }
  if (geom == null) return;
  // apariencia sintética a partir del estado
  final app = VNode('Appearance', null);
  final mat = st.material;
  if (mat != null) {
    final m = VNode('Material', mat.def);
    final d = _f(mat.fields['diffuseColor']);
    final e = _f(mat.fields['emissiveColor']);
    final s = _f(mat.fields['specularColor']);
    if (d.length >= 3) m.fields['diffuseColor'] = d.sublist(0, 3);
    if (e.length >= 3) m.fields['emissiveColor'] = e.sublist(0, 3);
    if (s.length >= 3) m.fields['specularColor'] = s.sublist(0, 3);
    m.fields['shininess'] = [_d(mat.fields['shininess'], 0.2)];
    m.fields['transparency'] = [_d(mat.fields['transparency'], 0)];
    app.fields['material'] = m;
  }
  final tn = st.textureNode;
  if (tn != null) {
    app.fields['texture'] = VNode('ImageTexture', null)..fields['url'] = [_firstString(tn.fields['filename']) ?? ''];
  }
  final key = '${identityHashCode(st.material)}|${identityHashCode(tn)}';
  final useApp = c.v1Apps.putIfAbsent(key, () => app);
  final mi = _meshFor(c, geom, useApp, label);
  if (mi == null) return;
  c.nodes.add(NodeData(label, parent, mi, List.of(st.m), null));
}
