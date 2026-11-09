// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
/// Paleta ACI de AutoCAD (índices 1–255) calculada, sin tabla de 256 entradas.
/// Devuelve 0xRRGGBB. El índice 7 es blanco (sobre fondo oscuro).
int aciColor(int index) {
  const fixed = <int, int>{
    1: 0xFF0000,
    2: 0xFFFF00,
    3: 0x00FF00,
    4: 0x00FFFF,
    5: 0x0000FF,
    6: 0xFF00FF,
    7: 0xFFFFFF,
    8: 0x808080,
    9: 0xC0C0C0,
  };
  if (index <= 0 || index > 255) return 0xFFFFFF;
  final f = fixed[index];
  if (f != null) return f;
  if (index >= 250) {
    final v = [51, 91, 132, 173, 214, 255][index - 250];
    return (v << 16) | (v << 8) | v;
  }
  final i = index - 10;
  final hue = (i ~/ 10) * 15.0;
  final p = i % 10;
  const values = [1.0, 0.65, 0.5, 0.3, 0.15];
  final value = values[p ~/ 2];
  final sat = p.isEven ? 1.0 : 0.5;
  return _hsv(hue, sat, value);
}

int _hsv(double h, double s, double v) {
  final c = v * s;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final m = v - c;
  double r, g, b;
  if (h < 60) {
    (r, g, b) = (c, x, 0);
  } else if (h < 120) {
    (r, g, b) = (x, c, 0);
  } else if (h < 180) {
    (r, g, b) = (0, c, x);
  } else if (h < 240) {
    (r, g, b) = (0, x, c);
  } else if (h < 300) {
    (r, g, b) = (x, 0, c);
  } else {
    (r, g, b) = (c, 0, x);
  }
  int ch(double t) => ((t + m) * 255).round().clamp(0, 255);
  return (ch(r) << 16) | (ch(g) << 8) | ch(b);
}
