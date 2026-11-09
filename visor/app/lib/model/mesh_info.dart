// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
/// Datos de un archivo de malla (glTF, OBJ, PLY) que no son geometría: qué trae el archivo,
/// qué falta y qué avisos merece. Solo tipos simples (viaja entre isolates).
class TextureInfo {
  TextureInfo(this.name, {this.width = 0, this.height = 0, this.bytes = 0, this.role = ''});
  final String name;
  int width, height;

  /// Tamaño del archivo de imagen codificado.
  int bytes;

  /// Uso: «color», «normales», «emisión»…
  String role;
  bool missing = false;
}

class MaterialInfo {
  MaterialInfo(this.name, this.color);
  final String name;
  final int color; // ARGB base
  String? texture;
  String alpha = 'opaco'; // opaco, recorte, mezcla
  bool doubleSided = false;
  bool unlit = false;
  bool emissive = false;
  double metallic = 0, roughness = 1;
}

/// Una vista guardada en el archivo (cámara de glTF o `Viewpoint` de VRML), en coordenadas del modelo.
class ViewInfo {
  ViewInfo(this.name, this.position, this.direction);
  final String name;
  final List<double> position;

  /// Hacia dónde mira (vector unitario).
  final List<double> direction;
}

class AnimationInfo {
  AnimationInfo(this.name, this.seconds, this.channels);
  final String name;
  final double seconds;
  final int channels;
}

class MeshFileInfo {
  MeshFileInfo(this.format);

  /// «glTF 2.0», «OBJ», «PLY binario»…
  String format;
  String generator = '';
  String copyright = '';
  String license = '';
  String title = '';
  String author = '';

  int vertices = 0, faces = 0, triangles = 0;
  int nodes = 0, meshes = 0;
  bool hasNormals = false, hasUv = false, hasColors = false;
  bool normalsComputed = false;
  int skins = 0, morphTargets = 0, cameras = 0, lights = 0;

  final materials = <MaterialInfo>[];
  final textures = <TextureInfo>[];
  final animations = <AnimationInfo>[];

  /// Variantes de material del archivo (`KHR_materials_variants`): nombres, por pieza qué material
  /// toma en cada variante, y los materiales (objetos `SurfaceMaterial`).
  final variants = <String>[];
  final variantParts = <int, Map<int, int>>{};
  List<Object> variantMaterials = const [];

  /// Vistas que trae el archivo (cámaras de glTF, `Viewpoint` de VRML).
  final views = <ViewInfo>[];

  /// Archivos que el modelo cita y no están junto a él (texturas, `.mtl`, `.bin`).
  final missing = <String>[];
  final extensionsUsed = <String>[];
  final extensionsRequired = <String>[];
  final warnings = <String>[];

  /// Grupos u objetos con nombre (OBJ `o`/`g`).
  final groups = <String>[];
  int polygonsNonTri = 0;
  double unitScaleHint = 0;

  /// Mayor dimensión de la escena en unidades del archivo (VRML), o 0.
  double sizeNote = 0;

  /// Eje que el archivo usa como «arriba» según el formato o la forma: 'x', 'y' o 'z'.
  String up = 'z';

  /// ¿Se dedujo por la forma (no lo dice el formato)?
  bool upGuessed = false;

  /// Campo escalar de los vértices (PLY: calidad, intensidad, curvatura…) y su rango.
  String scalarName = '';
  double scalarMin = 0, scalarMax = 0;

  /// Esqueleto y animaciones (glTF): un `Rig`, o null.
  Object? rig;
}

/// Información del archivo de una escena abierta.
final meshInfoOf = Expando<MeshFileInfo>();
