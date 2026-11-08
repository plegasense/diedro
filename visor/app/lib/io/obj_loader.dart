import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../model/material.dart';
import '../model/mesh_info.dart';
import 'mesh_data.dart';
import 'mesh_data_extra.dart';
import 'rich_mesh.dart';
import 'vrml_geom.dart' show thinGeometry;
import '../l10n/l10n.dart';

/// Busca los archivos que cita un modelo (`.mtl`, texturas, `.bin`) junto a él y en las
/// carpetas de archivos añadidos por el usuario; tolera mayúsculas distintas y rutas con `\`.
class SiblingFiles {
  SiblingFiles(this.dirs);
  final List<String> dirs;
  final _lists = <String, Map<String, String>>{};

  Map<String, String> _list(String dir) => _lists.putIfAbsent(dir, () {
    final m = <String, String>{};
    try {
      for (final e in Directory(dir).listSync()) {
        if (e is File) m[e.path.split('/').last.toLowerCase()] = e.path;
      }
    } catch (_) {}
    return m;
  });

  /// Ruta del archivo [ref] (relativa o con separadores de Windows) si existe.
  String? find(String ref) {
    var r = ref.trim().replaceAll('\\', '/');
    if (r.startsWith('file://')) r = Uri.decodeFull(r.substring(7));
    final base = r.split('/').last;
    for (final d in dirs) {
      final direct = File('$d/$r');
      if (direct.existsSync()) return direct.path;
      final hit = _list(d)[base.toLowerCase()];
      if (hit != null) return hit;
    }
    // ruta absoluta del equipo que lo exportó: se prueba con el nombre solo
    return null;
  }
}

class _ObjMaterial {
  _ObjMaterial(this.name);
  final String name;
  double kr = 0.8, kg = 0.8, kb = 0.8, alpha = 1;
  double er = 0, eg = 0, eb = 0;
  String? mapKd, mapD, mapBump, mapKe;
  int illum = 2;
  bool hasD = false;
}

/// Lee los `.mtl` citados.
Map<String, _ObjMaterial> _readMtl(String path, MeshFileInfo info) {
  final out = <String, _ObjMaterial>{};
  _ObjMaterial? cur;
  String lastOpt(String rest) {
    // «map_Kd -s 1 1 1 textura.png»: se descartan las opciones que empiezan por «-»
    final t = rest.trim().split(RegExp(r'\s+'));
    var i = 0;
    while (i < t.length && t[i].startsWith('-')) {
      final opt = t[i];
      final n = const {'-s': 3, '-o': 3, '-t': 3, '-mm': 2, '-bm': 1, '-boost': 1, '-clamp': 1, '-blendu': 1, '-blendv': 1, '-cc': 1, '-texres': 1, '-imfchan': 1, '-type': 1}[opt] ?? 1;
      i += 1 + n;
    }
    // los nombres de archivo pueden llevar espacios
    return t.sublist(i.clamp(0, t.length)).join(' ');
  }

  for (final raw in const LineSplitter().convert(utf8.decode(File(path).readAsBytesSync(), allowMalformed: true))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final sp = line.indexOf(RegExp(r'\s'));
    final key = (sp < 0 ? line : line.substring(0, sp)).toLowerCase();
    final rest = sp < 0 ? '' : line.substring(sp + 1).trim();
    switch (key) {
      case 'newmtl':
        cur = _ObjMaterial(rest);
        out[rest] = cur;
      case 'kd':
        final v = rest.split(RegExp(r'\s+')).map(double.tryParse).toList();
        if (cur != null && v.length >= 3 && v[0] != null && v[1] != null && v[2] != null) {
          cur
            ..kr = v[0]!
            ..kg = v[1]!
            ..kb = v[2]!;
        }
      case 'ke':
        final v = rest.split(RegExp(r'\s+')).map(double.tryParse).toList();
        if (cur != null && v.length >= 3 && v[0] != null && v[1] != null && v[2] != null) {
          cur
            ..er = v[0]!
            ..eg = v[1]!
            ..eb = v[2]!;
        }
      case 'd':
        cur
          ?..alpha = double.tryParse(rest.split(' ').last) ?? 1
          ..hasD = true;
      case 'tr':
        // «Tr 1» lo escriben como «opaco» MeshLab y otros: un objeto totalmente transparente no tiene sentido
        final tr = double.tryParse(rest) ?? 0;
        if (cur != null && !cur.hasD) cur.alpha = tr >= 0.999 ? 1 : 1 - tr;
      case 'illum':
        cur?.illum = int.tryParse(rest) ?? 2;
      case 'map_kd':
        cur?.mapKd = lastOpt(rest);
      case 'map_d':
        cur?.mapD = lastOpt(rest);
      case 'map_bump' || 'bump' || 'norm':
        cur?.mapBump = lastOpt(rest);
      case 'map_ke':
        cur?.mapKe = lastOpt(rest);
    }
  }
  return out;
}

/// Lee un OBJ con su MTL y texturas. Cada combinación de objeto (`o`/`g`) y material es una pieza.
Object parseObj(String path, {List<String> extraDirs = const []}) {
  try {
    return _parseObj(path, extraDirs);
  } on FormatException {
    rethrow;
  } on Exception {
    rethrow;
  } on Error catch (e) {
    throw FormatException(tr('El OBJ está dañado ({e})', {'e': e}));
  }
}

Object _parseObj(String path, List<String> extraDirs) {
  final file = File(path);
  final bytes = file.readAsBytesSync();
  final name = path.split('/').last;
  final sib = SiblingFiles([file.parent.path, ...extraDirs]);
  final info = MeshFileInfo('OBJ');

  var pos = FloatBuf(), nrm = FloatBuf(), uvb = FloatBuf();
  Uint8List? colors8;
  var colorCount = 0;
  var vcol = Uint8List(0); // r g b por vértice
  var vcolN = 0;
  void vcolAdd(int r, int g, int b) {
    if ((vcolN + 3) > vcol.length) {
      final nb = Uint8List(vcol.length == 0 ? 3072 : vcol.length * 2);
      nb.setRange(0, vcolN, vcol);
      vcol = nb;
    }
    vcol[vcolN++] = r;
    vcol[vcolN++] = g;
    vcol[vcolN++] = b;
  }

  var hasVertexColor = false;
  final objLines = IntBuf();
  final tris = CornerTris(withUv: true, withNrm: true, withGroup: true);

  final groupKey = <String, int>{};
  final groupObj = <String>[];
  final groupMat = <String?>[];
  var curObj = 'objeto';
  String? curMat;
  var curGroup = 0;
  int groupFor(String obj, String? mat) {
    final k = '$obj\u0000${mat ?? ''}';
    return groupKey.putIfAbsent(k, () {
      groupObj.add(obj);
      groupMat.add(mat);
      return groupObj.length - 1;
    });
  }

  curGroup = groupFor(curObj, curMat);
  final mtlFiles = <String>[];
  var missingMtl = false;
  final n = bytes.length;
  var i = 0;

  bool isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0D;

  // lectura de números sobre la línea actual
  int p = 0, lineEnd = 0;
  double? number() {
    while (p < lineEnd && isSpace(bytes[p])) {
      p++;
    }
    if (p >= lineEnd) return null;
    var neg = false;
    if (bytes[p] == 0x2D || bytes[p] == 0x2B) {
      neg = bytes[p] == 0x2D;
      p++;
    }
    var m = 0.0;
    var any = false;
    while (p < lineEnd) {
      final d = bytes[p] - 48;
      if (d < 0 || d > 9) break;
      m = m * 10 + d;
      p++;
      any = true;
    }
    var sc = 0;
    if (p < lineEnd && bytes[p] == 0x2E) {
      p++;
      while (p < lineEnd) {
        final d = bytes[p] - 48;
        if (d < 0 || d > 9) break;
        m = m * 10 + d;
        sc--;
        p++;
        any = true;
      }
    }
    if (!any) {
      while (p < lineEnd && !isSpace(bytes[p])) {
        p++;
      }
      return 0;
    }
    if (p < lineEnd && (bytes[p] == 0x65 || bytes[p] == 0x45)) {
      p++;
      var en = false;
      if (p < lineEnd && (bytes[p] == 0x2D || bytes[p] == 0x2B)) {
        en = bytes[p] == 0x2D;
        p++;
      }
      var x = 0;
      while (p < lineEnd) {
        final d = bytes[p] - 48;
        if (d < 0 || d > 9) break;
        x = x * 10 + d;
        p++;
      }
      sc += en ? -x : x;
    }
    if (sc != 0) {
      var f = 1.0;
      final k = sc < 0 ? -sc : sc;
      for (var j = 0; j < k && j < 40; j++) {
        f *= 10;
      }
      m = sc < 0 ? m / f : m * f;
    }
    return neg ? -m : m;
  }

  // entero con signo; devuelve null si no hay dígitos
  int? integer() {
    var neg = false;
    if (p < lineEnd && bytes[p] == 0x2D) {
      neg = true;
      p++;
    } else if (p < lineEnd && bytes[p] == 0x2B) {
      p++;
    }
    var v = 0;
    var any = false;
    while (p < lineEnd) {
      final d = bytes[p] - 48;
      if (d < 0 || d > 9) break;
      v = v * 10 + d;
      p++;
      any = true;
    }
    if (!any) return null;
    return neg ? -v : v;
  }

  final poly = <int>[], polyT = <int>[], polyN = <int>[];
  var warnedBadIndex = false;
  var verts = 0, uvs = 0, norms = 0;

  while (i < n) {
    // fin de línea
    var e = i;
    while (e < n && bytes[e] != 10) {
      e++;
    }
    lineEnd = e;
    var s = i;
    while (s < lineEnd && isSpace(bytes[s])) {
      s++;
    }
    i = e + 1;
    if (s >= lineEnd) continue;
    final c0 = bytes[s];
    if (c0 == 0x23) continue; // #
    final c1 = s + 1 < lineEnd ? bytes[s + 1] : 0;
    if (c0 == 0x76 && isSpace(c1)) {
      // v x y z [r g b]
      p = s + 2;
      final x = number(), y = number(), z = number();
      if (x == null || y == null || z == null) continue;
      pos.add3(x, y, z);
      final r = number(), g = number(), b = number();
      if (r != null && g != null && b != null) {
        if (!hasVertexColor) {
          hasVertexColor = true;
          // los vértices anteriores no tenían color: blanco
          for (var k = 0; k < verts; k++) {
            vcolAdd(255, 255, 255);
          }
        }
        int ch(double v) => v.isFinite ? (v <= 1.0 ? v * 255 : v).round().clamp(0, 255) : 255;
        vcolAdd(ch(r), ch(g), ch(b));
        colorCount++;
      } else if (hasVertexColor) {
        vcolAdd(255, 255, 255);
      }
      verts++;
    } else if (c0 == 0x76 && c1 == 0x74 /* vt */) {
      p = s + 2;
      final u = number(), v = number();
      if (u == null) continue;
      uvb
        ..add(u)
        ..add(1 - (v ?? 0));
      uvs++;
    } else if (c0 == 0x76 && c1 == 0x6E /* vn */) {
      p = s + 2;
      final x = number(), y = number(), z = number();
      if (x == null || y == null || z == null) continue;
      nrm.add3(x, y, z);
      norms++;
    } else if (c0 == 0x66 && isSpace(c1)) {
      p = s + 1;
      poly.clear();
      polyT.clear();
      polyN.clear();
      while (true) {
        while (p < lineEnd && isSpace(bytes[p])) {
          p++;
        }
        if (p >= lineEnd) break;
        final a = integer();
        if (a == null) {
          while (p < lineEnd && !isSpace(bytes[p])) {
            p++;
          }
          continue;
        }
        int? b, c;
        if (p < lineEnd && bytes[p] == 0x2F) {
          p++;
          b = integer();
          if (p < lineEnd && bytes[p] == 0x2F) {
            p++;
            c = integer();
          }
        }
        int fix(int v, int count) => v < 0 ? count + v : v - 1;
        poly.add(fix(a, verts));
        polyT.add(b == null ? -1 : fix(b, uvs));
        polyN.add(c == null ? -1 : fix(c, norms));
      }
      if (poly.length < 3) continue;
      // índices fuera de rango (OBJ que cita vértices posteriores o inexistentes)
      var bad = false;
      for (var k = 0; k < poly.length; k++) {
        if (poly[k] < 0) bad = true;
      }
      if (bad) {
        if (!warnedBadIndex) {
          info.warnings.add(tr('Caras con índices de vértice no válidos: se omiten.'));
          warnedBadIndex = true;
        }
        continue;
      }
      if (poly.length > 3) info.polygonsNonTri++;
      info.faces++;
      if (poly.length == 3) {
        tris.tri(poly[0], poly[1], poly[2], g: curGroup, t0: polyT[0], t1: polyT[1], t2: polyT[2], n0: polyN[0], n1: polyN[1], n2: polyN[2]);
      } else {
        final t = triangulatePolygon(_view(pos), poly);
        for (var k = 0; k + 2 < t.length; k += 3) {
          final a = t[k], b = t[k + 1], c = t[k + 2];
          tris.tri(poly[a], poly[b], poly[c], g: curGroup, t0: polyT[a], t1: polyT[b], t2: polyT[c], n0: polyN[a], n1: polyN[b], n2: polyN[c]);
        }
      }
    } else if (c0 == 0x6C && isSpace(c1)) {
      // l: polilínea (se dibuja como tubos finos)
      final refs = String.fromCharCodes(bytes, s + 2, lineEnd).trim().split(RegExp(r'\s+'));
      var prev = -1;
      for (final r in refs) {
        final a = int.tryParse(r.split('/').first);
        if (a == null) {
          prev = -1;
          continue;
        }
        final vi = a < 0 ? verts + a : a - 1;
        if (vi < 0) {
          prev = -1;
          continue;
        }
        if (prev >= 0 && objLines.n < 4000000) {
          objLines
            ..add(prev)
            ..add(vi);
        }
        prev = vi;
      }
    } else if ((c0 == 0x6F || c0 == 0x67) && isSpace(c1)) {
      // o / g
      var t = String.fromCharCodes(bytes, s + 2, lineEnd).trim();
      if (t.isEmpty) t = 'objeto';
      curObj = t;
      curGroup = groupFor(curObj, curMat);
      if (!info.groups.contains(t)) info.groups.add(t);
    } else if (lineEnd - s > 6 && _starts(bytes, s, 'usemtl')) {
      curMat = String.fromCharCodes(bytes, s + 6, lineEnd).trim();
      if (curMat.isEmpty) curMat = null;
      curGroup = groupFor(curObj, curMat);
    } else if (lineEnd - s > 6 && _starts(bytes, s, 'mtllib')) {
      final names = String.fromCharCodes(bytes, s + 6, lineEnd).trim();
      mtlFiles.add(names);
    }
  }
  if (tris.triangleCount == 0) {
    if (verts == 0) throw FormatException(tr('El OBJ está vacío: no tiene vértices ni caras'));
    if (objLines.n >= 2) {
      final lp = pos.take();
      final lmesh = _lineMesh(objLines, lp, info);
      if (lmesh != null) {
        guessUpAxis(info, [lmesh], 'y');
        return SceneData(name, [lmesh], [PlacedData(0, <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1], name)], extra: info);
      }
    }
    // solo vértices: se muestra como nube de puntos
    final pb = PointBuilder()..hasColor = hasVertexColor;
    final pp = pos.take();
    for (var k = 0; k < verts; k++) {
      if (hasVertexColor && k * 3 + 2 < vcolN) {
        pb.add(pp[k * 3], pp[k * 3 + 1], pp[k * 3 + 2], vcol[k * 3] / 255, vcol[k * 3 + 1] / 255, vcol[k * 3 + 2] / 255);
      } else {
        pb.add(pp[k * 3], pp[k * 3 + 1], pp[k * 3 + 2]);
      }
    }
    return pb.build(name, format: 'OBJ');
  }
  final positions = pos.take();
  if (hasVertexColor) {
    colors8 = Uint8List(verts * 4);
    for (var k = 0; k < verts && k * 3 + 2 < vcolN; k++) {
      colors8[k * 4] = vcol[k * 3];
      colors8[k * 4 + 1] = vcol[k * 3 + 1];
      colors8[k * 4 + 2] = vcol[k * 3 + 2];
      colors8[k * 4 + 3] = 255;
    }
  }
  info
    ..vertices = verts
    ..triangles = tris.triangleCount
    ..hasNormals = norms > 0
    ..hasUv = uvs > 0
    ..hasColors = hasVertexColor
    ..normalsComputed = norms == 0;
  if (colorCount > 0 && colorCount < verts) {
    info.warnings.add(tr('Solo algunos vértices traen color.'));
  }

  // ---- materiales
  final mats = <String, _ObjMaterial>{};
  for (final f in mtlFiles) {
    // «mtllib a.mtl b.mtl» (varios) o un nombre con espacios
    final cands = <String>[f, ...f.split(RegExp(r'\s+'))];
    var ok = false;
    for (final c in cands) {
      final found = sib.find(c);
      if (found != null) {
        mats.addAll(_readMtl(found, info));
        ok = true;
        break;
      }
    }
    if (!ok) {
      missingMtl = true;
      info.missing.add(f);
    }
  }

  final materials = <SurfaceMaterial>[];
  final textures = <SceneTexture>[];
  final matIndex = <String, int>{};
  final texIndex = <String, int>{};
  int? textureFor(String ref, String role) {
    final cacheKey = '$ref|$role';
    final cached = texIndex[cacheKey];
    if (cached != null) return cached >= 0 ? cached : null;
    final ti = TextureInfo(ref.replaceAll('\\', '/').split('/').last, role: role);
    final found = sib.find(ref);
    if (found == null) {
      ti.missing = true;
      info.missing.add(ti.name);
      info.textures.add(ti);
      texIndex[cacheKey] = -1;
      return null;
    }
    final b = File(found).readAsBytesSync();
    ti.bytes = b.length;
    info.textures.add(ti);
    textures.add(SceneTexture(ti.name, b));
    return texIndex[cacheKey] = textures.length - 1;
  }

  int? materialFor(String? name) {
    if (name == null) return null;
    final cached = matIndex[name];
    if (cached != null) return cached;
    final m = mats[name];
    if (m == null) {
      if (!missingMtl) info.warnings.add(tr('Material «{name}» no definido en el MTL.', {'name': name}));
      return null;
    }
    int ch(double v) => v.isFinite ? (v.clamp(0.0, 1.0) * 255).round() : 255;
    final tex = m.mapKd != null && m.mapKd!.isNotEmpty ? textureFor(m.mapKd!, 'color') : null;
    int? bumpTex;
    if (m.mapBump != null && m.mapBump!.isNotEmpty) {
      bumpTex = textureFor(m.mapBump!, 'relieve');
      if (bumpTex != null) textures[bumpTex].asHeight = true;
    }
    final sm = SurfaceMaterial(
      name: name,
      baseColor: tex != null
          ? 0xFFFFFFFF
          : (((m.alpha.clamp(0.0, 1.0) * 255).round() << 24) | (ch(m.kr) << 16) | (ch(m.kg) << 8) | ch(m.kb)),
      texture: tex,
      emissive: (m.er + m.eg + m.eb) > 0 ? 0xFF000000 | (ch(m.er) << 16) | (ch(m.eg) << 8) | ch(m.eb) : 0,
      unlit: m.illum == 0,
    );
    if (bumpTex != null) {
      // el relieve se convierte en mapa de normales: pasa a sombreado con normales por píxel
      sm.pbr = true;
      sm.normalTexture = bumpTex;
      sm.normalScale = 1;
      sm.roughness = 0.75;
    }
    if (m.alpha < 0.999) {
      sm.alphaMode = AlphaMode.blend;
      if (tex != null) sm.baseColor = ((m.alpha.clamp(0.0, 1.0) * 255).round() << 24) | 0xFFFFFF;
    } else if (m.mapD != null && m.mapD!.isNotEmpty) {
      sm.alphaMode = AlphaMode.mask;
      sm.alphaCutoff = 0.5;
      if (tex == null) {
        final td = textureFor(m.mapD!, 'opacidad');
        sm.texture = td;
      }
    }
    materials.add(sm);
    final mi = MaterialInfo(name, sm.baseColor)
      ..texture = tex != null ? textures[tex].name : null
      ..alpha = sm.alphaMode == AlphaMode.blend ? 'mezcla' : (sm.alphaMode == AlphaMode.mask ? 'recorte' : 'opaco')
      ..emissive = sm.emissive != 0
      ..unlit = sm.unlit;
    info.materials.add(mi);
    return matIndex[name] = materials.length - 1;
  }

  final groupNames = <String>[];
  final groupMats = <int?>[];
  final multiObj = groupObj.toSet().length > 1;
  for (var g = 0; g < groupObj.length; g++) {
    final mi = materialFor(groupMat[g]);
    groupMats.add(mi);
    final matName = groupMat[g];
    groupNames.add(
      multiObj
          ? (matName != null && groupObj.where((o) => o == groupObj[g]).length > 1 ? '${groupObj[g]} · $matName' : groupObj[g])
          : (matName ?? groupObj[g]),
    );
  }

  final builder = RichMeshBuilder(
    pos: positions,
    nrm: norms > 0 ? nrm.take() : null,
    uv: uvs > 0 ? uvb.take() : null,
    col: colors8,
  );
  final out = builder.build(tris, groupNames, materials: groupMats);
  final meshes = <MeshData>[];
  final placed = <PlacedData>[];
  final identity = <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  for (final g in out) {
    meshes.add(g.toMeshData());
    placed.add(PlacedData(meshes.length - 1, identity, g.name));
  }
  final lm = _lineMesh(objLines, positions, info);
  if (lm != null) {
    meshes.add(lm);
    placed.add(PlacedData(meshes.length - 1, identity, tr('Líneas')));
  }
  guessUpAxis(info, meshes, 'y');
  return SceneData(
    name,
    meshes,
    placed,
    materials: materials,
    textures: textures,
    extra: info,
  );
}

/// OBJ y PLY no dicen cuál es su eje vertical: se parte de la costumbre del formato (Y en OBJ,
/// Z en PLY) y se cambia si la forma lo contradice con claridad (una figura más alta que ancha).
void guessUpAxis(MeshFileInfo info, List<MeshData> meshes, String formatDefault) {
  final mn = [double.infinity, double.infinity, double.infinity];
  final mx = [-double.infinity, -double.infinity, -double.infinity];
  for (final m in meshes) {
    for (var k = 0; k < 3; k++) {
      if (m.min[k] < mn[k]) mn[k] = m.min[k];
      if (m.max[k] > mx[k]) mx[k] = m.max[k];
    }
  }
  final e = [for (var k = 0; k < 3; k++) mx[k] - mn[k]];
  info.up = formatDefault;
  info.upGuessed = true;
  final di = formatDefault == 'y' ? 1 : 2;
  final other = formatDefault == 'y' ? 2 : 1;
  // el eje alternativo manda si es claramente el más largo y supera al habitual
  if (e[other] > 1.3 * e[di] && e[other] >= e[0]) {
    info.up = formatDefault == 'y' ? 'z' : 'y';
  }
}

bool _starts(Uint8List b, int at, String s) {
  if (at + s.length > b.length) return false;
  for (var k = 0; k < s.length; k++) {
    if (b[at + k] != s.codeUnitAt(k)) return false;
  }
  return true;
}

/// Vista de solo lectura sobre el acumulador (la triangulación necesita posiciones).
Float32List _view(FloatBuf b) => Float32List.sublistView(b.a, 0, b.n);


/// Polilíneas `l` del OBJ como tubos finos (Datum sólo dibuja mallas).
MeshData? _lineMesh(IntBuf lines, Float32List positions, MeshFileInfo info) {
  if (lines.n < 2) return null;
  final nv = positions.length ~/ 3;
  final mn = [double.infinity, double.infinity, double.infinity], mx = [-double.infinity, -double.infinity, -double.infinity];
  for (var i = 0; i < nv; i++) {
    for (var k = 0; k < 3; k++) {
      final v = positions[i * 3 + k];
      if (v < mn[k]) mn[k] = v;
      if (v > mx[k]) mx[k] = v;
    }
  }
  final diag = math.sqrt(math.pow(mx[0] - mn[0], 2) + math.pow(mx[1] - mn[1], 2) + math.pow(mx[2] - mn[2], 2));
  final segs = <List<double>>[];
  final li = lines.take();
  for (var i = 0; i + 1 < li.length; i += 2) {
    final a = li[i], b = li[i + 1];
    if (a >= nv || b >= nv) continue;
    segs.add([positions[a * 3], positions[a * 3 + 1], positions[a * 3 + 2], positions[b * 3], positions[b * 3 + 1], positions[b * 3 + 2]]);
  }
  final g = thinGeometry(segments: segs, radius: (diag.isFinite && diag > 0 ? diag : 1) * 0.002);
  final m = g?.build(tr('Líneas'), null);
  if (m != null) info.warnings.add(tr('{n} segmentos de línea (l): se dibujan como tubos finos.', {'n': segs.length}));
  return m;
}
