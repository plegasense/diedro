import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/material.dart';
import '../model/mesh_info.dart';
import '../model/rig.dart';
import 'mesh_data.dart';
import 'draco_glue.dart';
import 'meshopt.dart';
import 'obj_loader.dart' show SiblingFiles;
import 'rich_mesh.dart';
import '../l10n/l10n.dart';

final List<double> _identity = <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

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

List<double> trsMatrix(List<double> t, List<double> q, List<double> s) {
  final x = q[0], y = q[1], z = q[2], w = q[3];
  return [
    (1 - 2 * (y * y + z * z)) * s[0],
    2 * (x * y + z * w) * s[0],
    2 * (x * z - y * w) * s[0],
    0,
    2 * (x * y - z * w) * s[1],
    (1 - 2 * (x * x + z * z)) * s[1],
    2 * (y * z + x * w) * s[1],
    0,
    2 * (x * z + y * w) * s[2],
    2 * (y * z - x * w) * s[2],
    (1 - 2 * (x * x + y * y)) * s[2],
    0,
    t[0],
    t[1],
    t[2],
    1,
  ];
}

/// Un accesor de glTF listo para leer a arreglos tipados.
class _Accessors {
  _Accessors(this.json, this.buffers, this.views);
  final Map<String, dynamic> json;
  final List<Uint8List> buffers;
  final List<Map<String, dynamic>> views;
  late final List<Map<String, dynamic>> accessors =
      (json['accessors'] as List? ?? const []).cast<Map<String, dynamic>>();

  static int comps(String t) => switch (t) {
    'SCALAR' => 1,
    'VEC2' => 2,
    'VEC3' => 3,
    'VEC4' => 4,
    'MAT2' => 4,
    'MAT3' => 9,
    'MAT4' => 16,
    _ => 1,
  };
  static int csize(int ct) => switch (ct) {
    5120 || 5121 => 1,
    5122 || 5123 => 2,
    _ => 4,
  };

  int count(int i) => accessors[i]['count'] as int;
  int ncomp(int i) => comps(accessors[i]['type'] as String);
  int ctype(int i) => accessors[i]['componentType'] as int;

  /// Bytes de una vista (ya descomprimida si usa meshopt).
  Uint8List viewBytes(int vi) => _viewCache.putIfAbsent(vi, () {
    final v = views[vi];
    final buf = buffers[v['buffer'] as int];
    final off = (v['byteOffset'] as int?) ?? 0;
    final len = v['byteLength'] as int;
    final ve = v['extensions'] as Map?;
    final mo = (ve?['EXT_meshopt_compression'] ?? ve?['KHR_meshopt_compression']) as Map<String, dynamic>?;
    if (mo != null) {
      final src = buffers[mo['buffer'] as int];
      final so = (mo['byteOffset'] as int?) ?? 0;
      return decodeMeshopt(
        Uint8List.sublistView(src, so, so + (mo['byteLength'] as int)),
        mo['count'] as int,
        mo['byteStride'] as int,
        mo['mode'] as String,
        (mo['filter'] as String?) ?? 'NONE',
      );
    }
    if (off + len > buf.length) {
      throw FormatException(tr('Una vista de datos sale del buffer ({end} > {size})', {'end': off + len, 'size': buf.length}));
    }
    return Uint8List.sublistView(buf, off, off + len);
  });
  final _viewCache = <int, Uint8List>{};

  /// Lee el accesor como flotantes (normalizando enteros si el accesor lo pide).
  Float32List floats(int i, {bool forceNormalize = false}) {
    final a = accessors[i];
    final n = a['count'] as int;
    final ct = a['componentType'] as int;
    final nc = comps(a['type'] as String);
    final normalized = a['normalized'] == true || forceNormalize;
    final out = Float32List(n * nc);
    if (a['bufferView'] != null) {
      final vi = a['bufferView'] as int;
      final bytes = viewBytes(vi);
      final base = (a['byteOffset'] as int?) ?? 0;
      final cs = csize(ct);
      var stride = (views[vi]['byteStride'] as int?) ?? 0;
      if (stride == 0) stride = cs * nc;
      if (base + (n - 1) * stride + nc * cs > bytes.length && n > 0) {
        throw FormatException(tr('Un accesor sale de su vista de datos'));
      }
      final bd = ByteData.sublistView(bytes);
      for (var k = 0; k < n; k++) {
        final o = base + k * stride;
        for (var c = 0; c < nc; c++) {
          final p = o + c * cs;
          double x;
          switch (ct) {
            case 5120:
              x = bd.getInt8(p).toDouble();
              if (normalized) x = math.max(x / 127, -1);
            case 5121:
              x = bytes[p].toDouble();
              if (normalized) x /= 255;
            case 5122:
              x = bd.getInt16(p, Endian.little).toDouble();
              if (normalized) x = math.max(x / 32767, -1);
            case 5123:
              x = bd.getUint16(p, Endian.little).toDouble();
              if (normalized) x /= 65535;
            case 5125:
              x = bd.getUint32(p, Endian.little).toDouble();
            default:
              x = bd.getFloat32(p, Endian.little);
          }
          out[k * nc + c] = x;
        }
      }
    }
    _sparse(a, n, nc, (idx, vals, j) {
      for (var c = 0; c < nc; c++) {
        out[idx * nc + c] = vals[j * nc + c];
      }
    }, normalized);
    return out;
  }

  /// Lee el accesor como enteros sin signo (índices, articulaciones).
  Uint32List ints(int i) {
    final a = accessors[i];
    final n = a['count'] as int;
    final ct = a['componentType'] as int;
    final nc = comps(a['type'] as String);
    final out = Uint32List(n * nc);
    if (a['bufferView'] != null) {
      final vi = a['bufferView'] as int;
      final bytes = viewBytes(vi);
      final base = (a['byteOffset'] as int?) ?? 0;
      final cs = csize(ct);
      var stride = (views[vi]['byteStride'] as int?) ?? 0;
      if (stride == 0) stride = cs * nc;
      if (base + (n - 1) * stride + nc * cs > bytes.length && n > 0) {
        throw FormatException(tr('Un accesor sale de su vista de datos'));
      }
      final bd = ByteData.sublistView(bytes);
      for (var k = 0; k < n; k++) {
        final o = base + k * stride;
        for (var c = 0; c < nc; c++) {
          final p = o + c * cs;
          out[k * nc + c] = switch (ct) {
            5121 => bytes[p],
            5123 => bd.getUint16(p, Endian.little),
            5125 => bd.getUint32(p, Endian.little),
            5120 => bd.getInt8(p) & 0xFF,
            5122 => bd.getInt16(p, Endian.little) & 0xFFFF,
            _ => bd.getFloat32(p, Endian.little).toInt(),
          };
        }
      }
    }
    return out;
  }

  void _sparse(
    Map<String, dynamic> a,
    int n,
    int nc,
    void Function(int idx, Float32List vals, int j) apply,
    bool normalized,
  ) {
    final sp = a['sparse'] as Map<String, dynamic>?;
    if (sp == null) return;
    final cnt = sp['count'] as int;
    final ind = sp['indices'] as Map<String, dynamic>;
    final val = sp['values'] as Map<String, dynamic>;
    final ibytes = viewBytes(ind['bufferView'] as int);
    final ioff = (ind['byteOffset'] as int?) ?? 0;
    final ict = ind['componentType'] as int;
    final vbytes = viewBytes(val['bufferView'] as int);
    final voff = (val['byteOffset'] as int?) ?? 0;
    final ct = a['componentType'] as int;
    final ibd = ByteData.sublistView(ibytes), vbd = ByteData.sublistView(vbytes);
    final vals = Float32List(cnt * nc);
    final cs = csize(ct);
    for (var j = 0; j < cnt * nc; j++) {
      final p = voff + j * cs;
      vals[j] = switch (ct) {
        5120 => vbd.getInt8(p).toDouble(),
        5121 => vbytes[p].toDouble(),
        5122 => vbd.getInt16(p, Endian.little).toDouble(),
        5123 => vbd.getUint16(p, Endian.little).toDouble(),
        5125 => vbd.getUint32(p, Endian.little).toDouble(),
        _ => vbd.getFloat32(p, Endian.little),
      };
    }
    for (var j = 0; j < cnt; j++) {
      final idx = switch (ict) {
        5121 => ibytes[ioff + j],
        5123 => ibd.getUint16(ioff + j * 2, Endian.little),
        _ => ibd.getUint32(ioff + j * 4, Endian.little),
      };
      if (idx < n) apply(idx, vals, j);
    }
  }
}

/// Lee glTF 2.0 (.gltf con buffers externos o incrustados, y .glb).
SceneData parseGltf(String path, {List<String> extraDirs = const []}) {
  try {
    return _parseGltf(path, extraDirs);
  } on FormatException {
    rethrow;
  } on Exception {
    rethrow;
  } on Error catch (e) {
    throw FormatException(tr('El glTF está dañado ({e})', {'e': e}));
  }
}

SceneData _parseGltf(String path, List<String> extraDirs) {
  final file = File(path);
  final bytes = file.readAsBytesSync();
  final name = path.split('/').last;
  final sib = SiblingFiles([file.parent.path, ...extraDirs]);
  final info = MeshFileInfo('glTF 2.0');
  late final Rig rig;

  late Map<String, dynamic> json;
  Uint8List? glbBin;
  final isGlb =
      bytes.length > 12 && bytes[0] == 0x67 && bytes[1] == 0x6C && bytes[2] == 0x54 && bytes[3] == 0x46;
  try {
    if (isGlb) {
      info.format = 'glTF binario (GLB)';
      final bd = ByteData.sublistView(bytes);
      var o = 12;
      Map<String, dynamic>? j;
      while (o + 8 <= bytes.length) {
        final len = bd.getUint32(o, Endian.little);
        final type = bd.getUint32(o + 4, Endian.little);
        final start = o + 8;
        if (start + len > bytes.length) {
          throw FormatException(tr('El GLB está cortado'));
        }
        if (type == 0x4E4F534A) {
          j = jsonDecode(utf8.decode(Uint8List.sublistView(bytes, start, start + len))) as Map<String, dynamic>;
        } else if (type == 0x004E4942 && glbBin == null) {
          glbBin = Uint8List.sublistView(bytes, start, start + len);
        }
        o = start + ((len + 3) & ~3);
      }
      if (j == null) throw FormatException(tr('El GLB no tiene la parte JSON'));
      json = j;
    } else {
      info.format = 'glTF (texto)';
      json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    }
  } on FormatException {
    rethrow;
  } catch (e) {
    throw FormatException(tr('El archivo no es un glTF válido ({e})', {'e': e}));
  }

  final asset = (json['asset'] as Map?)?.cast<String, dynamic>() ?? const {};
  final ver = '${asset['version'] ?? ''}';
  if (ver.isNotEmpty && !ver.startsWith('2')) {
    throw FormatException(tr('glTF {ver} no está soportado (solo 2.0)', {'ver': ver}));
  }
  info
    ..generator = '${asset['generator'] ?? ''}'
    ..copyright = '${asset['copyright'] ?? ''}';
  final extras = (asset['extras'] as Map?)?.cast<String, dynamic>() ?? const {};
  info
    ..title = '${extras['title'] ?? ''}'
    ..author = '${extras['author'] ?? ''}'
    ..license = '${extras['license'] ?? ''}';
  final used = (json['extensionsUsed'] as List?)?.cast<String>() ?? const [];
  final required = (json['extensionsRequired'] as List?)?.cast<String>() ?? const [];
  info.extensionsUsed.addAll(used);
  info.extensionsRequired.addAll(required);
  for (final r in required) {
    if (r == 'KHR_texture_basisu') {
      info.warnings.add(tr('Texturas KTX2/Basis: no se pueden leer, se ven sin textura.'));
    }
  }

  // ---- buffers
  final buffers = <Uint8List>[];
  for (final b in (json['buffers'] as List? ?? const [])) {
    final uri = b['uri'] as String?;
    if (uri == null) {
      final be = (b['extensions'] as Map?);
      final fb = ((be?['EXT_meshopt_compression'] ?? be?['KHR_meshopt_compression']) as Map?)?['fallback'] == true;
      if (glbBin == null && fb) {
        buffers.add(Uint8List(0)); // copia sin comprimir que no se usa
        continue;
      }
      if (glbBin == null) throw FormatException(tr('Falta el bloque binario del GLB'));
      buffers.add(glbBin);
    } else if (uri.startsWith('data:')) {
      buffers.add(base64Decode(uri.substring(uri.indexOf(',') + 1)));
    } else {
      final f = sib.find(Uri.decodeFull(uri));
      if (f == null) {
        info.missing.add(Uri.decodeFull(uri));
        throw FormatException(tr('Falta el archivo de datos: {file}', {'file': Uri.decodeFull(uri)}));
      }
      buffers.add(File(f).readAsBytesSync());
    }
  }
  final views = (json['bufferViews'] as List? ?? const []).cast<Map<String, dynamic>>();
  final acc = _Accessors(json, buffers, views);

  // ---- imágenes y texturas
  final images = (json['images'] as List? ?? const []).cast<Map<String, dynamic>>();
  final gtextures = (json['textures'] as List? ?? const []).cast<Map<String, dynamic>>();
  final samplers = (json['samplers'] as List? ?? const []).cast<Map<String, dynamic>>();
  final sceneTextures = <SceneTexture>[];
  final imageIndex = <int, int>{}; // imagen glTF → SceneTexture (−1 = falló)
  int? imageFor(int img, String role) {
    final cached = imageIndex[img];
    if (cached != null) return cached >= 0 ? cached : null;
    if (img < 0 || img >= images.length) return null;
    final im = images[img];
    final label = (im['name'] as String?) ?? (im['uri'] as String?) ?? tr('imagen {n}', {'n': img});
    final ti = TextureInfo(label.startsWith('data:') ? tr('imagen {n}', {'n': img}) : Uri.decodeFull(label.split('/').last), role: role);
    Uint8List? data;
    if (im['bufferView'] != null) {
      data = Uint8List.fromList(acc.viewBytes(im['bufferView'] as int));
    } else if (im['uri'] is String) {
      final uri = im['uri'] as String;
      if (uri.startsWith('data:')) {
        data = base64Decode(uri.substring(uri.indexOf(',') + 1));
      } else {
        final f = sib.find(Uri.decodeFull(uri));
        if (f == null) {
          ti.missing = true;
          info.missing.add(Uri.decodeFull(uri));
        } else {
          data = File(f).readAsBytesSync();
        }
      }
    }
    if (data != null) {
      final mime = (im['mimeType'] as String?) ?? '';
      if (mime == 'image/ktx2' || (data.length > 4 && data[0] == 0xAB && data[1] == 0x4B && data[2] == 0x54 && data[3] == 0x58)) {
        info.warnings.add(tr('«{name}» es KTX2/Basis: no se puede decodificar.', {'name': ti.name}));
        data = null;
      }
    }
    info.textures.add(ti);
    if (data == null) {
      imageIndex[img] = -1;
      return null;
    }
    ti.bytes = data.length;
    sceneTextures.add(SceneTexture(ti.name, data));
    return imageIndex[img] = sceneTextures.length - 1;
  }

  /// Imagen de una referencia a textura (con soporte de WebP, KTX2 y similares).
  int? textureRef(Map<String, dynamic>? ref, String role) {
    if (ref == null) return null;
    final ti = ref['index'] as int?;
    if (ti == null || ti < 0 || ti >= gtextures.length) return null;
    final t = gtextures[ti];
    final ext = (t['extensions'] as Map?)?.cast<String, dynamic>() ?? const {};
    final src = (t['source'] as int?) ??
        (ext['EXT_texture_webp'] as Map?)?['source'] as int? ??
        (ext['KHR_texture_basisu'] as Map?)?['source'] as int?;
    if (src == null) return null;
    return imageFor(src, role);
  }

  // ---- materiales
  final gmaterials = (json['materials'] as List? ?? const []).cast<Map<String, dynamic>>();
  final materials = <SurfaceMaterial>[];
  final matIndex = <int, int>{};
  final unsupported = <String>{};
  int ch(num v) => (v.clamp(0, 1) * 255).round();
  int argb(List f) => (ch(f.length > 3 ? f[3] as num : 1) << 24) | (ch(f[0] as num) << 16) | (ch(f[1] as num) << 8) | ch(f[2] as num);

  /// Conjunto de UV (TEXCOORD_n) de la textura de color del material.
  final matUvSet = <int, int>{};

  int materialFor(int gi) {
    final cached = matIndex[gi];
    if (cached != null) return cached;
    final g = gmaterials[gi];
    final pbr = (g['pbrMetallicRoughness'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ext = (g['extensions'] as Map?)?.cast<String, dynamic>() ?? const {};
    var base = 0xFFFFFFFF;
    final bf = pbr['baseColorFactor'] as List?;
    if (bf != null && bf.length >= 3) base = argb(bf);
    Map<String, dynamic>? baseTex = (pbr['baseColorTexture'] as Map?)?.cast<String, dynamic>();
    // Especular-brillo (heredado): el color difuso hace de color base
    final sg = (ext['KHR_materials_pbrSpecularGlossiness'] as Map?)?.cast<String, dynamic>();
    if (sg != null) {
      final df = sg['diffuseFactor'] as List?;
      if (df != null && df.length >= 3) base = argb(df);
      baseTex = (sg['diffuseTexture'] as Map?)?.cast<String, dynamic>() ?? baseTex;
      unsupported.add(tr('especular-brillo aproximado con el color difuso'));
    }
    final tex = textureRef(baseTex, 'color');
    final sm = SurfaceMaterial(
      name: (g['name'] as String?) ?? tr('Material {n}', {'n': gi}),
      baseColor: base,
      texture: tex,
      doubleSided: g['doubleSided'] == true,
      metallic: ((pbr['metallicFactor'] as num?) ?? 1).toDouble(),
      roughness: ((pbr['roughnessFactor'] as num?) ?? 1).toDouble(),
    );
    final am = (g['alphaMode'] as String?) ?? 'OPAQUE';
    sm.alphaMode = am == 'BLEND' ? AlphaMode.blend : (am == 'MASK' ? AlphaMode.mask : AlphaMode.opaque);
    sm.alphaCutoff = ((g['alphaCutoff'] as num?) ?? 0.5).toDouble();
    // Transmisión (vidrio): se aproxima con mezcla
    final trm = (ext['KHR_materials_transmission'] as Map?)?['transmissionFactor'];
    if (trm is num && trm > 0 && sm.alphaMode == AlphaMode.opaque) {
      sm.alphaMode = AlphaMode.blend;
      final a = ((base >> 24) & 255) * (1 - 0.7 * trm.clamp(0, 1)).toDouble();
      sm.baseColor = (a.round() << 24) | (base & 0xFFFFFF);
      unsupported.add(tr('transmisión aproximada con transparencia'));
    }
    if (ext.containsKey('KHR_materials_unlit')) sm.unlit = true;
    final ef = g['emissiveFactor'] as List?;
    if (ef != null && ef.length >= 3) {
      var s = 1.0;
      final es = (ext['KHR_materials_emissive_strength'] as Map?)?['emissiveStrength'];
      if (es is num) s = es.toDouble();
      final r = ef[0] * s, gg = ef[1] * s, b = ef[2] * s;
      if (r + gg + b > 0) sm.emissive = 0xFF000000 | (ch(r) << 16) | (ch(gg) << 8) | ch(b);
    }
    // Transformación de UV y conjunto de coordenadas de la textura de color
    var uvSet = (baseTex?['texCoord'] as int?) ?? 0;
    final tt = ((baseTex?['extensions'] as Map?)?['KHR_texture_transform'] as Map?)?.cast<String, dynamic>();
    if (tt != null) {
      final o = (tt['offset'] as List?) ?? const [0, 0];
      final s = (tt['scale'] as List?) ?? const [1, 1];
      sm
        ..uvOx = (o[0] as num).toDouble()
        ..uvOy = (o[1] as num).toDouble()
        ..uvSx = (s[0] as num).toDouble()
        ..uvSy = (s[1] as num).toDouble()
        ..uvRot = ((tt['rotation'] as num?) ?? 0).toDouble();
      if (tt['texCoord'] is int) uvSet = tt['texCoord'] as int;
    }
    // Direccionamiento de la textura
    if (baseTex != null) {
      final ti = baseTex['index'] as int?;
      final si = ti != null && ti < gtextures.length ? gtextures[ti]['sampler'] as int? : null;
      if (si != null && si < samplers.length) {
        int mode(dynamic v) => v == 33071 ? 1 : (v == 33648 ? 2 : 0); // clamp, mirror, repeat
        sm
          ..wrapS = mode(samplers[si]['wrapS'])
          ..wrapT = mode(samplers[si]['wrapT']);
      }
    }
    // Sombreado físico: metal/rugosidad, normales, oclusión y emisión
    sm.pbr = !sm.unlit;
    if (sg != null) {
      sm.metallic = 0;
      sm.roughness = 1 - (((sg['glossinessFactor'] as num?) ?? 1).toDouble()).clamp(0.0, 1.0);
    }
    sm.mrTexture = sg == null ? textureRef((pbr['metallicRoughnessTexture'] as Map?)?.cast<String, dynamic>(), tr('metal/rugosidad')) : null;
    final nt = (g['normalTexture'] as Map?)?.cast<String, dynamic>();
    sm.normalTexture = textureRef(nt, tr('normales'));
    sm.normalScale = ((nt?['scale'] as num?) ?? 1).toDouble();
    final ot = (g['occlusionTexture'] as Map?)?.cast<String, dynamic>();
    sm.occlusionTexture = textureRef(ot, tr('oclusión'));
    sm.occlusionStrength = ((ot?['strength'] as num?) ?? 1).toDouble();
    sm.emissiveTexture = textureRef((g['emissiveTexture'] as Map?)?.cast<String, dynamic>(), tr('emisión'));
    if (sm.emissiveTexture != null && sm.emissive == 0) sm.emissive = 0xFF000000;
    for (final k in ext.keys) {
      if (const {
        'KHR_materials_clearcoat',
        'KHR_materials_sheen',
        'KHR_materials_iridescence',
        'KHR_materials_anisotropy',
        'KHR_materials_volume',
        'KHR_materials_specular',
        'KHR_materials_ior',
        'KHR_materials_dispersion',
        'KHR_materials_diffuse_transmission',
      }.contains(k)) {
        unsupported.add(tr('efecto {name}', {'name': k.replaceFirst('KHR_materials_', '')}));
      }
    }
    materials.add(sm);
    matUvSet[materials.length - 1] = uvSet;
    final mi = MaterialInfo(sm.name, sm.baseColor)
      ..texture = tex != null ? sceneTextures[tex].name : null
      ..alpha = sm.alphaMode == AlphaMode.blend ? 'mezcla' : (sm.alphaMode == AlphaMode.mask ? 'recorte' : 'opaco')
      ..doubleSided = sm.doubleSided
      ..unlit = sm.unlit
      ..emissive = sm.emissive != 0
      ..metallic = sm.metallic
      ..roughness = sm.roughness;
    info.materials.add(mi);
    return matIndex[gi] = materials.length - 1;
  }

  // ---- mallas
  final meshes = <MeshData>[];
  final cache = <String, List<int>>{}; // «malla:peso» → índices de MeshData
  final gmeshes = (json['meshes'] as List? ?? const []).cast<Map<String, dynamic>>();
  var skippedPrims = 0;
  var tris = 0;
  var vtotal = 0;

  /// Mallas (una por primitiva con triángulos) de una malla de glTF.
  List<int> meshPrims(int mi, String label, List<double>? weights, int nodeIdx, int skinIdx) {
    final hasMorph = ((gmeshes[mi]['primitives'] as List).first as Map)['targets'] != null;
    final key = '$mi:${weights?.join(',') ?? ''}:$skinIdx:${hasMorph ? nodeIdx : -1}';
    final c = cache[key];
    if (c != null) return c;
    final out = <int>[];
    final prims = (gmeshes[mi]['primitives'] as List).cast<Map<String, dynamic>>();
    for (var pi = 0; pi < prims.length; pi++) {
      final prim = prims[pi];
      final mode = (prim['mode'] as int?) ?? 4;
      final attrs = (prim['attributes'] as Map).cast<String, dynamic>();
      if (attrs['POSITION'] == null || mode < 4) {
        skippedPrims++;
        continue;
      }
      // Draco: los datos del primitivo vienen de un bloque comprimido
      final dr = ((prim['extensions'] as Map?)?['KHR_draco_mesh_compression'] as Map?)?.cast<String, dynamic>();
      DracoPrim? draco;
      if (dr != null) {
        draco = decodeDraco(acc.viewBytes(dr['bufferView'] as int), {
          for (final e in (dr['attributes'] as Map).entries) e.key as String: e.value as int,
        });
      }
      Float32List? fl(String name, {bool forceNorm = false}) {
        final a = attrs[name];
        if (a == null) return null;
        final d = draco?.attrs[name];
        if (d != null) {
          final ct = acc.ctype(a as int);
          if ((acc.accessors[a]['normalized'] == true || forceNorm) && ct != 5126) {
            final mx = switch (ct) { 5121 => 255.0, 5123 => 65535.0, 5120 => 127.0, _ => 32767.0 };
            final r = Float32List(d.length);
            for (var i = 0; i < d.length; i++) {
              r[i] = d[i] / mx;
            }
            return r;
          }
          return d;
        }
        return acc.floats(a as int, forceNormalize: forceNorm);
      }

      var pos = fl('POSITION')!;
      final basePos = pos;
      final vcount = pos.length ~/ 3;
      final targets = (prim['targets'] as List?)?.cast<Map<String, dynamic>>();
      if (targets != null && weights != null) {
        pos = Float32List.fromList(pos);
        for (var t = 0; t < targets.length && t < weights.length; t++) {
          final w = weights[t];
          final pa = targets[t]['POSITION'];
          if (w == 0 || pa == null) continue;
          final d = acc.floats(pa as int);
          for (var k = 0; k < pos.length && k < d.length; k++) {
            pos[k] += d[k] * w;
          }
        }
      }
      Uint32List idx;
      if (draco != null) {
        idx = draco.indices;
      } else if (prim['indices'] != null) {
        idx = acc.ints(prim['indices'] as int);
      } else {
        idx = Uint32List.fromList(List<int>.generate(vcount, (i) => i));
      }
      // modo → lista de triángulos
      Uint32List triIdx;
      if (mode == 4) {
        triIdx = Uint32List.sublistView(idx, 0, idx.length - idx.length % 3);
      } else {
        final l = <int>[];
        if (mode == 5) {
          for (var i = 0; i + 2 < idx.length; i++) {
            i.isEven ? l.addAll([idx[i], idx[i + 1], idx[i + 2]]) : l.addAll([idx[i + 1], idx[i], idx[i + 2]]);
          }
        } else {
          for (var i = 1; i + 1 < idx.length; i++) {
            l.addAll([idx[0], idx[i], idx[i + 1]]);
          }
        }
        triIdx = Uint32List.fromList(l);
      }
      // índices fuera de rango → se descartan esos triángulos
      var maxI = 0;
      for (final v in triIdx) {
        if (v > maxI) maxI = v;
      }
      if (maxI >= vcount) {
        final ok = <int>[];
        for (var i = 0; i + 2 < triIdx.length; i += 3) {
          if (triIdx[i] < vcount && triIdx[i + 1] < vcount && triIdx[i + 2] < vcount) {
            ok.addAll([triIdx[i], triIdx[i + 1], triIdx[i + 2]]);
          }
        }
        triIdx = Uint32List.fromList(ok);
        info.warnings.add(tr('Índices fuera de rango en «{label}»: se omiten esos triángulos.', {'label': label}));
      }
      if (triIdx.isEmpty) continue;
      final mat = prim['material'] as int?;
      final mIdx = mat != null && mat < gmaterials.length ? materialFor(mat) : null;
      final uvSet = mIdx != null ? (matUvSet[mIdx] ?? 0) : 0;
      final uvAcc = attrs['TEXCOORD_$uvSet'] ?? attrs['TEXCOORD_0'];
      final uv = uvAcc != null ? fl(attrs['TEXCOORD_$uvSet'] != null ? 'TEXCOORD_$uvSet' : 'TEXCOORD_0') : null;
      final colAcc = attrs['COLOR_0'];
      Float32List? col;
      var colN = 4;
      if (colAcc != null) {
        colN = acc.ncomp(colAcc as int);
        col = fl('COLOR_0', forceNorm: acc.ctype(colAcc) != 5126);
      }
      final hasNormals = attrs['NORMAL'] != null;
      tris += triIdx.length ~/ 3;
      vtotal += vcount;
      info.hasUv = info.hasUv || uv != null;
      info.hasColors = info.hasColors || col != null;
      info.hasNormals = info.hasNormals || hasNormals;
      if (targets != null) info.morphTargets += targets.length;
      if (hasNormals) {
        // camino rápido: vértices únicos con normales del archivo
        final nor = fl('NORMAL')!;
        final needRig = (skinIdx >= 0 && attrs['JOINTS_0'] != null && attrs['WEIGHTS_0'] != null) ||
            (targets != null && targets.any((t) => t['POSITION'] != null));
        final verts = Float32List(vcount * 6);
        final mn = [double.infinity, double.infinity, double.infinity];
        final mx = [-double.infinity, -double.infinity, -double.infinity];
        for (var i = 0; i < vcount; i++) {
          final px = pos[i * 3], py = pos[i * 3 + 1], pz = pos[i * 3 + 2];
          verts[i * 6] = px;
          verts[i * 6 + 1] = py;
          verts[i * 6 + 2] = pz;
          if (i * 3 + 2 < nor.length) {
            verts[i * 6 + 3] = nor[i * 3];
            verts[i * 6 + 4] = nor[i * 3 + 1];
            verts[i * 6 + 5] = nor[i * 3 + 2];
          }
          if (px < mn[0]) mn[0] = px;
          if (py < mn[1]) mn[1] = py;
          if (pz < mn[2]) mn[2] = pz;
          if (px > mx[0]) mx[0] = px;
          if (py > mx[1]) mx[1] = py;
          if (pz > mx[2]) mx[2] = pz;
        }
        Float32List? extra;
        if (uv != null || col != null) {
          extra = Float32List(vcount * 6);
          for (var i = 0; i < vcount; i++) {
            if (uv != null && i * 2 + 1 < uv.length) {
              extra[i * 6] = uv[i * 2];
              extra[i * 6 + 1] = uv[i * 2 + 1];
            }
            if (col != null && i * colN + colN - 1 < col.length) {
              extra[i * 6 + 2] = col[i * colN];
              extra[i * 6 + 3] = col[i * colN + 1];
              extra[i * 6 + 4] = col[i * colN + 2];
              extra[i * 6 + 5] = colN == 4 ? col[i * colN + 3] : 1;
            } else {
              extra[i * 6 + 2] = 1;
              extra[i * 6 + 3] = 1;
              extra[i * 6 + 4] = 1;
              extra[i * 6 + 5] = 1;
            }
          }
        }
        meshes.add(MeshData(label, verts, mn, mx, indices: triIdx, extra: extra, material: mIdx));
        final vmap = ((prim['extensions'] as Map?)?['KHR_materials_variants'] as Map?)?['mappings'] as List?;
        if (vmap != null) {
          final m = <int, int>{};
          for (final e in vmap) {
            final mm = (e as Map)['material'] as int?;
            if (mm == null || mm >= gmaterials.length) continue;
            final mi2 = materialFor(mm);
            for (final v in (e['variants'] as List? ?? const [])) {
              m[v as int] = mi2;
            }
          }
          if (m.isNotEmpty) info.variantParts[meshes.length - 1] = m;
        }
        if (needRig) {
          final rp = RigPrim(meshes.length - 1, nodeIdx)
            ..basePos = basePos
            ..baseNor = nor
            ..baseWeights = weights ?? ((gmeshes[mi]['weights'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? const []);
          if (skinIdx >= 0 && attrs['JOINTS_0'] != null && attrs['WEIGHTS_0'] != null) {
            final j = draco != null && draco.attrs['JOINTS_0'] != null
                ? Uint32List.fromList([for (final x in draco.attrs['JOINTS_0']!) x.round()])
                : acc.ints(attrs['JOINTS_0'] as int);
            rp
              ..skin = skinIdx
              ..joints = Uint16List.fromList(j)
              ..weights = fl('WEIGHTS_0', forceNorm: true);
          }
          if (targets != null) {
            rp.morphDeltas = [
              for (final t in targets) t['POSITION'] != null ? acc.floats(t['POSITION'] as int) : Float32List(pos.length),
            ];
          }
          rig.prims.add(rp);
        }
      } else {
        // sin normales: planas, como pide la especificación
        final ct = CornerTris(withUv: true);
        for (var i = 0; i + 2 < triIdx.length; i += 3) {
          ct.tri(triIdx[i], triIdx[i + 1], triIdx[i + 2], t0: triIdx[i], t1: triIdx[i + 1], t2: triIdx[i + 2]);
        }
        Uint8List? c8;
        if (col != null) {
          c8 = Uint8List(vcount * 4);
          for (var i = 0; i < vcount; i++) {
            c8[i * 4] = (col[i * colN] * 255).round().clamp(0, 255);
            c8[i * 4 + 1] = (col[i * colN + 1] * 255).round().clamp(0, 255);
            c8[i * 4 + 2] = (col[i * colN + 2] * 255).round().clamp(0, 255);
            c8[i * 4 + 3] = colN == 4 ? (col[i * colN + 3] * 255).round().clamp(0, 255) : 255;
          }
        }
        final b = RichMeshBuilder(pos: pos, uv: uv, col: c8, flatWithoutNormals: true);
        for (final g in b.build(ct, [label], materials: [mIdx])) {
          meshes.add(g.toMeshData());
        }
        info.normalsComputed = true;
      }
      out.add(meshes.length - 1);
    }
    return cache[key] = out;
  }

  // ---- nodos
  final gnodes = (json['nodes'] as List? ?? const []).cast<Map<String, dynamic>>();
  final nodes = <NodeData>[];
  rig = Rig(gnodes.length);
  rig.t = Float32List(gnodes.length * 3);
  rig.r = Float32List(gnodes.length * 4);
  rig.s = Float32List(gnodes.length * 3);
  rig.matrix = List<Float64List?>.filled(gnodes.length, null);
  for (var i = 0; i < gnodes.length; i++) {
    final n = gnodes[i];
    rig.parent.add(-1);
    rig.r[i * 4 + 3] = 1;
    rig.s[i * 3] = rig.s[i * 3 + 1] = rig.s[i * 3 + 2] = 1;
    if (n['matrix'] != null) {
      rig.hasMatrix.add(true);
      rig.matrix[i] = Float64List.fromList([for (final v in n['matrix'] as List) (v as num).toDouble()]);
    } else {
      rig.hasMatrix.add(false);
      final t = n['translation'] as List?, r = n['rotation'] as List?, sc = n['scale'] as List?;
      for (var k = 0; t != null && k < 3; k++) {
        rig.t[i * 3 + k] = (t[k] as num).toDouble();
      }
      for (var k = 0; r != null && k < 4; k++) {
        rig.r[i * 4 + k] = (r[k] as num).toDouble();
      }
      for (var k = 0; sc != null && k < 3; k++) {
        rig.s[i * 3 + k] = (sc[k] as num).toDouble();
      }
    }
  }
  for (var i = 0; i < gnodes.length; i++) {
    for (final c in (gnodes[i]['children'] as List?)?.cast<int>() ?? const <int>[]) {
      if (c >= 0 && c < gnodes.length) rig.parent[c] = i;
    }
  }
  // glTF usa Y hacia arriba; Datum usa Z (convención CAD): el visor gira la escena según `info.up`.
  nodes.add(NodeData(name, -1, -1, _identity, null));
  info.up = 'y';

  List<double> nodeMatrix(Map<String, dynamic> n) {
    if (n['matrix'] != null) {
      return [for (final v in n['matrix'] as List) (v as num).toDouble()];
    }
    final t = ((n['translation'] as List?) ?? const [0, 0, 0]).map((e) => (e as num).toDouble()).toList();
    final q = ((n['rotation'] as List?) ?? const [0, 0, 0, 1]).map((e) => (e as num).toDouble()).toList();
    final s = ((n['scale'] as List?) ?? const [1, 1, 1]).map((e) => (e as num).toDouble()).toList();
    return trsMatrix(t, q, s);
  }

  var instancingNodes = 0;
  void visit(int idx, int parent, List<double> parentWorld, int depth, Set<int> stack) {
    if (depth > 128 || idx < 0 || idx >= gnodes.length || stack.contains(idx)) return;
    stack.add(idx);
    final n = gnodes[idx];
    final label = (n['name'] as String?) ?? tr('Nodo {n}', {'n': idx});
    final local = nodeMatrix(n);
    final world = _mul(parentWorld, local);
    if (n['camera'] is int && info.views.length < 64) {
      final ci = n['camera'] as int;
      final cams = json['cameras'] as List?;
      final cn = cams != null && ci >= 0 && ci < cams.length ? (cams[ci] as Map)['name'] as String? : null;
      final d = [-world[8], -world[9], -world[10]];
      final l = math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
      if (l > 1e-9) info.views.add(ViewInfo(cn ?? label, [world[12], world[13], world[14]], [d[0] / l, d[1] / l, d[2] / l]));
    }
    final prims = <int>[];
    if (n['mesh'] != null && (n['mesh'] as int) < gmeshes.length) {
      final mi = n['mesh'] as int;
      final w = ((n['weights'] as List?) ?? (gmeshes[mi]['weights'] as List?))?.map((e) => (e as num).toDouble()).toList();
      prims.addAll(meshPrims(mi, label, w, idx, (n['skin'] as int?) ?? -1));
    }
    // Una malla con piel ignora la transformación de sus ancestros: se cancela para que quede en reposo.
    var myLocal = local;
    final skinned = n['skin'] != null && prims.isNotEmpty;
    if (skinned) info.skins++;
    // Instanciado por GPU
    final inst = ((n['extensions'] as Map?)?['EXT_mesh_gpu_instancing'] as Map?)?['attributes'] as Map?;
    List<List<double>>? instMats;
    if (inst != null && prims.isNotEmpty) {
      final tA = inst['TRANSLATION'] as int?, rA = inst['ROTATION'] as int?, sA = inst['SCALE'] as int?;
      final cnt = acc.count((tA ?? rA ?? sA)!);
      final tt = tA != null ? acc.floats(tA) : null;
      final rr = rA != null ? acc.floats(rA, forceNormalize: true) : null;
      final ss = sA != null ? acc.floats(sA) : null;
      instMats = [
        for (var i = 0; i < cnt; i++)
          trsMatrix(
            tt != null ? [tt[i * 3], tt[i * 3 + 1], tt[i * 3 + 2]] : [0, 0, 0],
            rr != null ? [rr[i * 4], rr[i * 4 + 1], rr[i * 4 + 2], rr[i * 4 + 3]] : [0, 0, 0, 1],
            ss != null ? [ss[i * 3], ss[i * 3 + 1], ss[i * 3 + 2]] : [1, 1, 1],
          ),
      ];
      instancingNodes += cnt;
    }
    final children = (n['children'] as List?)?.cast<int>() ?? const [];
    info.nodes++;
    if (skinned) {
      // La malla con piel va en el espacio global: cuelga de la raíz con matriz identidad.
      for (final m in prims) {
        nodes.add(NodeData(label, 0, m, _identity, null));
      }
      nodes.add(NodeData(label, parent, -1, local, null, tag: [4, idx]));
      final me = nodes.length - 1;
      for (final c in children) {
        visit(c, me, world, depth + 1, stack);
      }
    } else if (instMats == null && prims.length == 1 && children.isEmpty) {
      nodes.add(NodeData(label, parent, prims.first, myLocal, null, tag: [4, idx]));
    } else {
      nodes.add(NodeData(label, parent, -1, myLocal, null, tag: [4, idx]));
      final me = nodes.length - 1;
      if (instMats != null) {
        for (final m in instMats) {
          for (final p in prims) {
            nodes.add(NodeData(label, me, p, m, null));
          }
        }
      } else {
        for (final m in prims) {
          nodes.add(NodeData(label, me, m, _identity, null));
        }
      }
      for (final c in children) {
        visit(c, me, world, depth + 1, stack);
      }
    }
    stack.remove(idx);
  }

  final scenes = (json['scenes'] as List? ?? const []).cast<Map<String, dynamic>>();
  final sceneIdx = (json['scene'] as int?) ?? 0;
  List<int> roots;
  if (scenes.isNotEmpty && sceneIdx < scenes.length) {
    roots = (scenes[sceneIdx]['nodes'] as List?)?.cast<int>() ?? const [];
  } else {
    // sin escena: nodos que no son hijos de otro
    final child = <int>{for (final n in gnodes) ...((n['children'] as List?)?.cast<int>() ?? const <int>[])};
    roots = [for (var i = 0; i < gnodes.length; i++) if (!child.contains(i)) i];
  }
  if (scenes.length > 1) info.warnings.add(tr('Hay {n} escenas: se muestra la predeterminada.', {'n': scenes.length}));
  for (final r in roots) {
    visit(r, 0, _identity, 0, <int>{});
  }
  info.meshes = gmeshes.length;
  info.cameras = (json['cameras'] as List?)?.length ?? 0;
  info.lights = (((json['extensions'] as Map?)?['KHR_lights_punctual'] as Map?)?['lights'] as List?)?.length ?? 0;

  // esqueletos
  for (final sk in (json['skins'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    final joints = ((sk['joints'] as List?) ?? const []).cast<int>();
    final ibm = sk['inverseBindMatrices'] != null
        ? acc.floats(sk['inverseBindMatrices'] as int)
        : Float32List.fromList([for (var i = 0; i < joints.length; i++) ..._identity]);
    rig.skins.add(RigSkin(joints, ibm));
  }

  // animaciones
  for (final a in (json['animations'] as List? ?? const []).cast<Map<String, dynamic>>()) {
    var dur = 0.0;
    final samps = (a['samplers'] as List? ?? const []).cast<Map<String, dynamic>>();
    final channels = <RigChannel>[];
    for (final ch in (a['channels'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final tg = (ch['target'] as Map?)?.cast<String, dynamic>();
      final si = ch['sampler'] as int?;
      if (tg == null || si == null || si >= samps.length) continue;
      final node = tg['node'] as int?;
      final path = switch (tg['path']) {
        'translation' => 0,
        'rotation' => 1,
        'scale' => 2,
        'weights' => 3,
        _ => -1,
      };
      if (node == null || node < 0 || node >= gnodes.length || path < 0) continue;
      final sm = samps[si];
      final inp = sm['input'] as int?, outp = sm['output'] as int?;
      if (inp == null || outp == null) continue;
      try {
        final times = acc.floats(inp);
        final vals = acc.floats(outp);
        final interp = switch (sm['interpolation']) {
          'STEP' => 1,
          'CUBICSPLINE' => 2,
          _ => 0,
        };
        if (times.isEmpty) continue;
        dur = math.max(dur, times.last);
        channels.add(RigChannel(node, path, interp, times, vals));
      } catch (_) {
        info.warnings.add(tr('Un canal de animación está dañado y se omite.'));
      }
    }
    final nm = (a['name'] as String?) ?? tr('Animación {n}', {'n': info.animations.length + 1});
    info.animations.add(AnimationInfo(nm, dur, channels.length));
    if (channels.isNotEmpty) rig.animations.add(RigAnimation(nm, dur, channels));
  }
  if (rig.animations.isNotEmpty || rig.prims.isNotEmpty) info.rig = rig;

  if (meshes.isEmpty) {
    throw FormatException(tr('El glTF no contiene mallas de triángulos'));
  }
  if (skippedPrims > 0) {
    info.warnings.add(tr('{n} primitivas de puntos o líneas no se dibujan.', {'n': skippedPrims}));
  }
  if (instancingNodes > 0) info.warnings.add(tr('Instanciado por GPU: {n} instancias.', {'n': instancingNodes}));
  if (unsupported.isNotEmpty) {
    info.warnings.add(tr('No se aplican: {list}.', {'list': unsupported.join(', ')}));
  }
  final vlist = ((json['extensions'] as Map?)?['KHR_materials_variants'] as Map?)?['variants'] as List?;
  if (vlist != null && info.variantParts.isNotEmpty) {
    for (final v in vlist) {
      info.variants.add(((v as Map)['name'] as String?) ?? tr('Variante {n}', {'n': info.variants.length + 1}));
    }
    info.variantMaterials = List<Object>.of(materials);
  } else {
    info.variantParts.clear();
  }
  info.triangles = tris;
  info.vertices = vtotal;
  return SceneData(
    name,
    meshes,
    const [],
    nodes: nodes,
    materials: materials,
    textures: sceneTextures,
    extra: info,
  );
}
