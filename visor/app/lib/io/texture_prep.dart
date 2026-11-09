// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../model/material.dart';
import 'iso_run.dart';

/// Niveles de mip (RGBA8) de una imagen: filtro de caja 2×2, de mayor a menor.
List<Uint8List> buildMips(Uint8List base, int w, int h) {
  final levels = math.max(1, math.min(w, h).bitLength - 1);
  final out = <Uint8List>[base];
  var pw = w, ph = h;
  var prev = base;
  for (var l = 1; l < levels; l++) {
    final nw = math.max(1, pw >> 1), nh = math.max(1, ph >> 1);
    final cur = Uint8List(nw * nh * 4);
    for (var y = 0; y < nh; y++) {
      final y0 = math.min(y * 2, ph - 1), y1 = math.min(y * 2 + 1, ph - 1);
      for (var x = 0; x < nw; x++) {
        final x0 = math.min(x * 2, pw - 1), x1 = math.min(x * 2 + 1, pw - 1);
        final a = (y0 * pw + x0) * 4,
            b = (y0 * pw + x1) * 4,
            c = (y1 * pw + x0) * 4,
            d = (y1 * pw + x1) * 4;
        final o = (y * nw + x) * 4;
        for (var k = 0; k < 4; k++) {
          cur[o + k] = (prev[a + k] + prev[b + k] + prev[c + k] + prev[d + k] + 2) >> 2;
        }
      }
    }
    out.add(cur);
    prev = cur;
    pw = nw;
    ph = nh;
  }
  return out;
}

/// Convierte un mapa de alturas (RGBA8, la luminancia es la altura) en un mapa de normales de
/// espacio tangente (convención de glTF: verde hacia arriba de la imagen).
Uint8List heightToNormals(Uint8List rgba, int w, int h, {double strength = 2.0}) {
  final hgt = Float32List(w * h);
  for (var i = 0; i < w * h; i++) {
    hgt[i] = (0.2126 * rgba[i * 4] + 0.7152 * rgba[i * 4 + 1] + 0.0722 * rgba[i * 4 + 2]) / 255;
  }
  final out = Uint8List(w * h * 4);
  double at(int x, int y) => hgt[y.clamp(0, h - 1) * w + x.clamp(0, w - 1)];
  // la fuerza se normaliza por el tamaño: una imagen grande tiene gradientes por píxel más suaves
  final k = strength * math.max(w, h) / 256;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = (at(x + 1, y) - at(x - 1, y)) * 0.5 * k;
      final dy = (at(x, y + 1) - at(x, y - 1)) * 0.5 * k;
      var nx = -dx, ny = dy, nz = 1.0;
      final l = math.sqrt(nx * nx + ny * ny + nz * nz);
      nx /= l;
      ny /= l;
      nz /= l;
      final o = (y * w + x) * 4;
      out[o] = ((nx * 0.5 + 0.5) * 255).round();
      out[o + 1] = ((ny * 0.5 + 0.5) * 255).round();
      out[o + 2] = ((nz * 0.5 + 0.5) * 255).round();
      out[o + 3] = 255;
    }
  }
  return out;
}

/// Decodifica las texturas (PNG, JPEG, WebP…) y les construye los mips. Las que no se
/// pueden leer quedan marcadas como falladas (el material se ve con su color base).
Future<void> prepareTextures(
  List<SceneTexture> list, {
  int maxDim = 4096,
}) async {
  for (final t in list) {
    if (t.mips != null) continue;
    try {
      var codec = await ui.instantiateImageCodec(t.encoded);
      var img = (await codec.getNextFrame()).image;
      if (math.max(img.width, img.height) > maxDim) {
        final wide = img.width >= img.height;
        img.dispose();
        codec.dispose();
        codec = await ui.instantiateImageCodec(
          t.encoded,
          targetWidth: wide ? maxDim : null,
          targetHeight: wide ? null : maxDim,
        );
        img = (await codec.getNextFrame()).image;
      }
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = img.width, h = img.height;
      img.dispose();
      codec.dispose();
      if (bd == null || w < 1 || h < 1) {
        t.failed = true;
        continue;
      }
      final base = TransferableTypedData.fromList([
        bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
      ]);
      final height = t.asHeight;
      final mips = await isoRun(() {
        var b = base.materialize().asUint8List();
        if (height) b = heightToNormals(b, w, h);
        final l = buildMips(b, w, h);
        return [for (final m in l) TransferableTypedData.fromList([m])];
      });
      t
        ..width = w
        ..height = h
        ..mips = [for (final m in mips) m.materialize().asUint8List()];
    } catch (_) {
      t.failed = true;
    }
  }
}
