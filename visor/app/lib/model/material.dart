// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:typed_data';

/// Cómo se mezcla el color con lo que hay detrás.
enum AlphaMode { opaque, mask, blend }

/// Imagen de textura de un archivo (PNG/JPEG/WebP codificados) y, una vez decodificada,
/// sus píxeles con la cadena de mapas de mip.
class SceneTexture {
  SceneTexture(this.name, this.encoded);
  final String name;
  final Uint8List encoded;

  /// Tras decodificar: ancho, alto y niveles (RGBA8) de mayor a menor.
  int width = 0, height = 0;
  List<Uint8List>? mips;
  bool failed = false;

  /// La imagen es un mapa de alturas (relieve de OBJ): al decodificar se convierte en mapa de normales.
  bool asHeight = false;

  /// Textura de GPU (la crea el renderizador al dibujar por primera vez).
  Object? gpu;

  int get bytes => mips == null ? 0 : mips!.fold(0, (a, m) => a + m.length);
}

/// Material de una pieza: factores y, si la hay, textura de color.
class SurfaceMaterial {
  SurfaceMaterial({
    this.name = '',
    this.baseColor = 0xFFFFFFFF,
    this.texture,
    this.alphaMode = AlphaMode.opaque,
    this.alphaCutoff = 0.5,
    this.doubleSided = false,
    this.emissive = 0,
    this.unlit = false,
    this.metallic = 0,
    this.roughness = 1,
  });
  String name;

  /// Factor de color (ARGB); el alfa es la opacidad.
  int baseColor;

  /// Índice en `Scene.textures`, o null.
  int? texture;
  AlphaMode alphaMode;
  double alphaCutoff;
  bool doubleSided;

  /// Color emitido (ARGB; 0 = ninguno).
  int emissive;
  bool unlit;
  double metallic, roughness;

  /// Sombreado físico simplificado (glTF): usa metal/rugosidad, normales, oclusión y emisión.
  bool pbr = false;

  /// Índices en `Scene.textures` de las texturas de metal-rugosidad (verde y azul), normales,
  /// oclusión (rojo) y emisión.
  int? mrTexture, normalTexture, occlusionTexture, emissiveTexture;
  double normalScale = 1, occlusionStrength = 1;

  /// Transformación de UV (KHR_texture_transform): desplazamiento, escala y giro.
  /// Direccionamiento de la textura: 0 repetir, 1 sujetar al borde, 2 espejo.
  int wrapS = 0, wrapT = 0;
  double uvOx = 0, uvOy = 0, uvSx = 1, uvSy = 1, uvRot = 0;
  bool get hasUvTransform =>
      uvOx != 0 || uvOy != 0 || uvSx != 1 || uvSy != 1 || uvRot != 0;
}
