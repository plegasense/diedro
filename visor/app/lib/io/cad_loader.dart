import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../l10n/l10n.dart';
import '../model/brep.dart';
import '../model/pmi.dart';
import '../src/datum_ffi.dart';
import 'mesh_builder.dart';
import 'mesh_data.dart';

/// Archivo de caché del documento ya convertido (clave: ruta, tamaño y fecha del original).
/// La conversión de Open CASCADE es lo más lento al abrir: en una tableta de gama media un STEP de
/// 15 MB pasa de 31 s a unos 8 s la segunda vez.
/// Carpeta de la caché de documentos convertidos; la fija `main` (en Android no se borra al actualizar).
String? cadCacheDir;

String? _cacheFileFor(String path, {String? dir0}) {
  try {
    final ext = path.split('.').last.toLowerCase();
    if (!{'stp', 'step', 'igs', 'iges'}.contains(ext)) return null;
    final f = File(path);
    final st = f.statSync();
    var h = 0xcbf29ce484222325;
    for (final c
        in '$path|${st.size}|${st.modified.millisecondsSinceEpoch}|v1'
            .codeUnits) {
      h = ((h ^ c) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    final base = dir0 ?? cadCacheDir;
    if (base == null) return null;
    final dir = Directory(base)..createSync(recursive: true);
    _evictCache(dir);
    return '${dir.path}/${h.toRadixString(16)}.xbf';
  } catch (_) {
    return null;
  }
}

/// ¿Hay un documento convertido de este archivo? (la apertura será mucho más rápida)
bool cadCacheHit(String path) {
  try {
    final f = _cacheFileFor(path);
    return f != null && File(f).existsSync() && File('$f.meta').existsSync();
  } catch (_) {
    return false;
  }
}

/// Mantiene la caché por debajo de ~600 MB borrando lo más antiguo.
void _evictCache(Directory dir) {
  try {
    final files = [
      for (final e in dir.listSync())
        if (e is File) e,
    ];
    var total = files.fold<int>(0, (a, f) => a + f.lengthSync());
    if (total < 600 * 1024 * 1024) return;
    files.sort(
      (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
    );
    for (final f in files) {
      if (total < 400 * 1024 * 1024) break;
      total -= f.lengthSync();
      f.deleteSync();
    }
  } catch (_) {}
}

/// Abre STEP/IGES/BREP con el núcleo C++ (Open CASCADE). Debe ejecutarse en un isolate.
SceneData parseCad(String path, {String? cacheDir}) {
  _checkStepFile(path);
  final cPath = path.toNativeUtf8();
  Pointer<Void> scene;
  try {
    datumCadSetLean(const bool.fromEnvironment('DATUM_LEAN') ? 1 : 0);
    final cache = const bool.fromEnvironment('DATUM_NOCACHE')
        ? null
        : _cacheFileFor(path, dir0: cacheDir);
    if (cache != null) {
      final cc = cache.toNativeUtf8();
      datumCadSetCacheFile(cc);
      malloc.free(cc);
    }
    scene = datumCadOpen(cPath, 0.001);
  } finally {
    malloc.free(cPath);
  }
  if (scene == nullptr) {
    final err = datumLastError().toDartString();
    throw Exception(err.isEmpty ? tr('No se pudo abrir el archivo') : _cppError(err));
  }
  var keep = false;
  try {
    final meshes = <MeshData>[];
    final brep = <PartBrepData>[];
    final parts = datumPartCount(scene);
    for (var i = 0; i < parts; i++) {
      final n = datumPartVertexCount(scene, i);
      final src = datumPartVertices(scene, i).asTypedList(n * 6);
      final verts = Float32List.fromList(
        src,
      ); // copia: la memoria nativa se libera al final
      final b = boundsOf(verts);
      final c = datumPartColor(scene, i);
      final tris = n ~/ 3;
      final faceCount = datumPartFaceCount(scene, i);
      final segN = datumPartEdgeSegmentCount(scene, i);
      final dens = malloc<Double>(1);
      final matName = datumPartMaterial(scene, i, dens).toDartString();
      final matDens = dens.value;
      malloc.free(dens);
      brep.add(
        PartBrepData(
          tris == 0
              ? Int32List(0)
              : Int32List.fromList(
                  datumPartFaceOfTriangle(scene, i).asTypedList(tris),
                ),
          faceCount,
          segN == 0
              ? Float32List(0)
              : Float32List.fromList(
                  datumPartEdgeSegments(scene, i).asTypedList(segN * 6),
                ),
          segN == 0
              ? Int32List(0)
              : Int32List.fromList(
                  datumPartEdgeOfSegment(scene, i).asTypedList(segN),
                ),
          datumPartEdgeCount(scene, i),
          materialName: matName,
          materialDensity: matDens,
        ),
      );
      meshes.add(
        MeshData(
          _cleanName(datumPartName(scene, i).toDartString()),
          verts,
          b.min,
          b.max,
          color: c == 0 ? null : c,
        ),
      );
    }
    final nodes = <NodeData>[];
    final count = datumNodeCount(scene);
    for (var i = 0; i < count; i++) {
      final m = datumNodeMatrix(scene, i).asTypedList(16);
      final c = datumNodeColor(scene, i);
      nodes.add(
        NodeData(
          _cleanName(datumNodeName(scene, i).toDartString()),
          datumNodeParent(scene, i),
          datumNodePart(scene, i),
          List<double>.of(m),
          c == 0 ? null : c,
        ),
      );
    }
    keep = true;
    return SceneData(
      path.split('/').last,
      meshes,
      const [],
      nodes: nodes,
      cad: CadData(
        scene.address,
        datumFileUnit(scene).toDartString(),
        datumFileOrigin(scene).toDartString(),
        datumFileSchema(scene).toDartString(),
        brep,
        _readPmi(scene),
      ),
    );
  } finally {
    // La geometría exacta se queda en memoria nativa mientras el documento esté abierto.
    if (!keep) datumSceneFree(scene);
  }
}

/// Quita extensiones de archivo que algunos exportadores dejan en el nombre del producto.
String _cleanName(String s) {
  final lower = s.toLowerCase();
  for (final ext in [
    '.step',
    '.stp',
    '.igs',
    '.iges',
    '.sldprt',
    '.sldasm',
    '.prt',
  ]) {
    if (lower.endsWith(ext)) return s.substring(0, s.length - ext.length);
  }
  return s;
}

List<PmiItem> _readPmi(Pointer<Void> scene) {
  final out = <PmiItem>[];
  final n = datumPmiCount(scene);
  final info = malloc<Double>(16);
  final ref = malloc<Int32>(3);
  try {
    for (var i = 0; i < n; i++) {
      datumPmiInfo(scene, i, info);
      final v = info.asTypedList(16).toList();
      final refs = <PmiRef>[];
      for (var k = 0; k < datumPmiRefCount(scene, i); k++) {
        datumPmiRef(scene, i, k, ref);
        final r = ref.asTypedList(3);
        refs.add(PmiRef(r[0], r[1] == 1, r[2]));
      }
      final segs = datumPmiSegmentCount(scene, i);
      out.add(
        PmiItem(
          kind: PmiKind.values[v[0].round().clamp(0, 2)],
          type: v[1].round(),
          v: v.sublist(2),
          text: datumPmiText(scene, i).toDartString(),
          refs: refs,
          segments: segs == 0
              ? Float32List(0)
              : Float32List.fromList(
                  datumPmiSegments(scene, i).asTypedList(segs * 6),
                ),
        ),
      );
    }
  } finally {
    malloc.free(info);
    malloc.free(ref);
  }
  return _mergeDatums(out);
}

/// Una referencia (datum) puede aparecer varias veces: se une por nombre.
List<PmiItem> _mergeDatums(List<PmiItem> list) {
  final out = <PmiItem>[];
  final byName = <String, int>{};
  for (final p in list) {
    if (p.kind != PmiKind.datum) {
      out.add(p);
      continue;
    }
    final key = p.text;
    final at = byName[key];
    if (at == null) {
      byName[key] = out.length;
      out.add(p);
    } else {
      final q = out[at];
      final seg = Float32List(q.segments.length + p.segments.length)
        ..setAll(0, q.segments)
        ..setAll(q.segments.length, p.segments);
      out[at] = PmiItem(
        kind: q.kind,
        type: q.type,
        v: q.v,
        text: q.text,
        refs: [...q.refs, ...p.refs],
        segments: seg,
      );
    }
  }
  return out;
}

/// Traduce el mensaje de error del núcleo C++ (que está en español); el texto de Open CASCADE se deja tal cual.
String _cppError(String err) {
  const p = 'Error de Open CASCADE: ';
  if (err.startsWith(p)) {
    return tr('Error de Open CASCADE: {m}', {'m': err.substring(p.length)});
  }
  return tr(err);
}

/// Comprobaciones previas para dar un mensaje claro cuando el archivo está vacío, cortado o no es STEP.
void _checkStepFile(String path) {
  final lower = path.toLowerCase();
  if (!(lower.endsWith('.step') || lower.endsWith('.stp'))) return;
  final f = File(path);
  final len = f.lengthSync();
  if (len == 0) throw Exception(tr('El archivo está vacío.'));
  final raf = f.openSync();
  try {
    final head = String.fromCharCodes(
      raf.readSync(len < 4096 ? len : 4096).where((b) => b < 128),
    );
    if (!head.contains('ISO-10303-21')) {
      throw Exception(
        '${tr('Este archivo no parece un STEP (no empieza con ISO-10303-21).')} '
        '${tr('Comprueba que no sea un archivo de otro formato con la extensión cambiada.')}',
      );
    }
    final tailLen = len < 2048 ? len : 2048;
    raf.setPositionSync(len - tailLen);
    final tail = String.fromCharCodes(
      raf.readSync(tailLen).where((b) => b < 128),
    );
    if (!tail.contains('END-ISO-10303-21')) {
      throw Exception(
        '${tr('El archivo está incompleto: termina antes de tiempo.')} '
        '${tr('¿Se cortó la descarga o la copia? Vuelve a descargarlo o exportarlo.')}',
      );
    }
  } finally {
    raf.closeSync();
  }
}
