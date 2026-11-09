// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:typed_data';

/// Decodificador del formato de imagen QOI (miniaturas de PrusaSlicer). Devuelve RGBA.
({int width, int height, Uint8List rgba})? decodeQoi(Uint8List d) {
  if (d.length < 22 ||
      d[0] != 0x71 ||
      d[1] != 0x6F ||
      d[2] != 0x69 ||
      d[3] != 0x66) {
    return null;
  }
  final bd = ByteData.sublistView(d);
  final w = bd.getUint32(4), h = bd.getUint32(8);
  if (w == 0 || h == 0 || w * h > 16 * 1024 * 1024) return null;
  final out = Uint8List(w * h * 4);
  final index = Uint8List(64 * 4);
  var r = 0, g = 0, b = 0, a = 255;
  var p = 14, o = 0;
  final end = d.length - 8;
  while (o < out.length && p < end) {
    final b1 = d[p++];
    if (b1 == 0xFE) {
      r = d[p++];
      g = d[p++];
      b = d[p++];
    } else if (b1 == 0xFF) {
      r = d[p++];
      g = d[p++];
      b = d[p++];
      a = d[p++];
    } else {
      switch (b1 & 0xC0) {
        case 0x00:
          final i = (b1 & 63) * 4;
          r = index[i];
          g = index[i + 1];
          b = index[i + 2];
          a = index[i + 3];
        case 0x40:
          r = (r + ((b1 >> 4) & 3) - 2) & 255;
          g = (g + ((b1 >> 2) & 3) - 2) & 255;
          b = (b + (b1 & 3) - 2) & 255;
        case 0x80:
          final b2 = d[p++];
          final dg = (b1 & 63) - 32;
          r = (r + dg - 8 + ((b2 >> 4) & 15)) & 255;
          g = (g + dg) & 255;
          b = (b + dg - 8 + (b2 & 15)) & 255;
        default:
          var run = b1 & 63;
          while (run-- >= 0 && o < out.length) {
            out[o++] = r;
            out[o++] = g;
            out[o++] = b;
            out[o++] = a;
          }
          continue;
      }
    }
    final i = ((r * 3 + g * 5 + b * 7 + a * 11) % 64) * 4;
    index[i] = r;
    index[i + 1] = g;
    index[i + 2] = b;
    index[i + 3] = a;
    out[o++] = r;
    out[o++] = g;
    out[o++] = b;
    out[o++] = a;
  }
  return (width: w, height: h, rgba: out);
}
