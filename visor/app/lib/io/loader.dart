import 'dart:io';

import 'package:vector_math/vector_math.dart' as vm;

import '../l10n/l10n.dart';
import 'iso_run.dart';
import '../model/brep.dart';
import '../model/document.dart';
import '../model/lines.dart';
import '../model/mesh.dart';
import '../model/pointcloud.dart';
import '../model/scene.dart';
import 'cad_loader.dart';
import 'mesh_data_extra.dart';
import 'mesh_data.dart';
import '../model/mesh_info.dart';
import '../model/threemf.dart';
import 'texture_prep.dart';
import 'zip_lite.dart';

/// Formatos que Datum sabe abrir hoy.
const kSupportedExtensions = {
  'zip',
  'stl',
  'obj',
  '3mf',
  'ply',
  'gltf',
  'glb',
  'wrl',
  'wrz',
  'x3d',
  'x3dv',
  'step',
  'stp',
  'stpz',
  'iges',
  'igs',
  'brep',
  'dxf',
  'svg',
  'plt',
  'hpgl',
  'hgl',
  'hpg',
  'xyz',
  'pts',
  'pcd',
  'las',
  'laz',
  'e57',
  'gcode',
  'gco',
  'gc',
  'nc',
  'ngc',
  'tap',
  'cnc',
  'bgcode',
};

const kHpglExtensions = {'plt', 'hpgl', 'hgl', 'hpg', 'hp'};

const kGcodeExtensions = {'gcode', 'gco', 'gc', 'nc', 'ngc', 'tap', 'cnc'};

/// Formatos propietarios que se reconocen pero no se pueden abrir: se explica cómo exportarlos.
const kProprietary = {
  'sldprt': 'SolidWorks',
  'sldasm': 'SolidWorks',
  'slddrw': 'SolidWorks',
  'ipt': 'Autodesk Inventor',
  'iam': 'Autodesk Inventor',
  'idw': 'Autodesk Inventor',
  'prt': 'Siemens NX / PTC Creo',
  'catpart': 'CATIA',
  'catproduct': 'CATIA',
  'par': 'Solid Edge',
  'f3d': 'Autodesk Fusion',
  'dwg': 'AutoCAD',
};

class UnsupportedFormat implements Exception {
  UnsupportedFormat(this.extension, this.software);
  final String extension;
  final String? software;
  @override
  String toString() => extension == 'dwg'
      ? '${tr('Los archivos .dwg son formato nativo de AutoCAD y todavía no se pueden abrir.')} '
            '${tr('Guárdalo como DXF (Guardar como → DXF) y ábrelo aquí.')}'
      : software == null
      ? tr('Formato .{e} no soportado todavía.', {'e': extension})
      : '${tr('Los archivos .{e} son formato nativo de {s} y no se pueden abrir directamente.', {'e': extension, 's': software})} '
            '${tr('Expórtalo a STEP (.step) desde {s} y ábrelo aquí.', {'s': software})}';
}

/// Carpeta (en la caché de la app) donde el usuario deja las texturas y materiales que
/// faltan junto a un modelo; los lectores la miran además de la carpeta del archivo.
String extraFilesDir(String modelPath) {
  var h = 5381;
  for (final c in modelPath.codeUnits) {
    h = ((h << 5) + h + c) & 0x7FFFFFFF;
  }
  return '${extraBase ?? Directory.systemTemp.path}/datum_extra/$h';
}

/// Carpeta base de los archivos añadidos (la fija `main`).
String? extraBase;

List<String> _extra(String modelPath) {
  final d = extraFilesDir(modelPath);
  return Directory(d).existsSync() ? [d] : const [];
}

Future<Scene> loadScene(String path) async {
  final name = path.split('/').last;
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  if (ext != 'step' && ext != 'stp') throw UnsupportedFormat(ext, kProprietary[ext]);
  final cacheDir = cadCacheDir;
  final data = await isoRun(() => parseCad(path, cacheDir: cacheDir));
  return _sceneFrom(data);
}

CadBrep? _cad(CadData? c) =>
    c == null ? null : CadBrep(c.handle, c.unit, c.origin, c.schema, c.pmi);

Scene _sceneFrom(SceneData d) {
  if (d.placed.isEmpty && d.nodes.isEmpty)
    throw Exception(tr('El archivo no contiene geometría'));
  final parts = <Part>[
    for (var i = 0; i < d.meshes.length; i++)
      Part(
        id: i,
        name: d.meshes[i].name,
        mesh: d.meshes[i].toMesh(),
        color: d.meshes[i].color,
        brep: d.cad?.parts[i].toBrep(),
        material: d.meshes[i].material == null
            ? null
            : d.materials[d.meshes[i].material!],
      ),
  ];
  final root = SceneNode(name: d.name);
  if (d.nodes.isNotEmpty) {
    // Jerarquía de ensamblaje (STEP/IGES): el padre siempre aparece antes que sus hijos.
    final built = <SceneNode>[];
    for (final n in d.nodes) {
      final node = SceneNode(
        name: n.name,
        part: n.part >= 0 ? parts[n.part] : null,
        transform: vm.Matrix4.fromList(n.matrix),
        tag: n.tag,
      );
      built.add(node);
      (n.parent >= 0 ? built[n.parent] : root).children.add(node);
    }
    final scene = Scene(
      name: d.name,
      root: root,
      parts: parts,
      cad: _cad(d.cad),
      textures: d.textures,
    );
    if (d.extra is ThreeMfProject) threeMfOf[scene] = d.extra as ThreeMfProject;
    if (d.extra is MeshFileInfo) meshInfoOf[scene] = d.extra as MeshFileInfo;
    return scene;
  }
  for (final p in d.placed) {
    root.children.add(
      SceneNode(
        name: p.name,
        part: parts[p.meshIndex],
        transform: vm.Matrix4.fromList(p.matrix),
      ),
    );
  }
  final scene = Scene(name: d.name, root: root, parts: parts, textures: d.textures);
  if (d.extra is MeshFileInfo) meshInfoOf[scene] = d.extra as MeshFileInfo;
  return scene;
}

/// Diedro: solo STEP.
Future<Document> loadDocument(String path, {int? gcodePlate}) async =>
    _model(await loadScene(path));

/// Documento de modelo con sus texturas ya decodificadas.
Future<ModelDocument> _model(Scene s) async {
  if (s.textures.isNotEmpty) await prepareTextures(s.textures);
  return ModelDocument(s);
}

PointCloudDocument _cloud(PointData d) {
  final set = LineSet(vertices: d.verts, bounds: Bounds(d.min, d.max));
  final i = d.intensity, c = d.cls, r = d.ret, n = d.nret;
  return PointCloudDocument(
    PointCloud(
      name: d.name,
      points: set,
      hasColor: d.hasColor,
      attrs: (i != null || c != null || r != null) ? CloudAttrs(intensity: i, cls: c, ret: r, nret: n) : null,
      info: d.info,
      origin: d.origin,
    ),
  );
}

/// Extrae un ZIP con un modelo y sus archivos en una carpeta de la caché y devuelve la ruta
/// del modelo principal (glTF, GLB, OBJ, PLY, STL o 3MF).
String extractModelZip(String zipPath, String base) {
  final zip = ZipLite.open(zipPath);
  try {
    var h = 5381;
    for (final c in zipPath.codeUnits) {
      h = ((h << 5) + h + c) & 0x7FFFFFFF;
    }
    final dir = Directory('$base/datum_zip/$h')..createSync(recursive: true);
    String? main;
    var total = 0;
    const rank = {'glb': 0, 'gltf': 1, 'obj': 2, 'ply': 3, '3mf': 4, 'stl': 5, 'step': 6, 'stp': 6};
    var best = 99;
    for (final e in zip.entries.values) {
      final name = e.name.replaceAll('\\', '/');
      if (name.startsWith('/') || name.split('/').contains('..') || name.contains('__MACOSX')) continue;
      total += e.usize;
      if (total > 1500 * 1024 * 1024) {
        throw FormatException(tr('El ZIP descomprimido es demasiado grande (más de 1,5 GB)'));
      }
      final out = File('${dir.path}/$name')..parent.createSync(recursive: true);
      final sink = out.openSync(mode: FileMode.write);
      try {
        zip.stream(e.name, sink.writeFromSync);
      } finally {
        sink.closeSync();
      }
      final x = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      final r = rank[x];
      if (r != null && r < best) {
        best = r;
        main = out.path;
      }
    }
    if (main == null) throw FormatException(tr('El ZIP no contiene ningún modelo que Datum sepa abrir'));
    return main;
  } finally {
    zip.close();
  }
}
