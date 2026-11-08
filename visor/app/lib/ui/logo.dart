import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// Logo de Datum: vista explosionada de un ensamblaje. [explode] va de 0 (junto) a 1 (separado).
class DatumLogo extends StatelessWidget {
  const DatumLogo({super.key, required this.size, this.explode = 1});
  final double size;
  final double explode;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _LogoPainter(explode));
}

class _Face {
  _Face(this.pts, this.color);
  final List<Offset> pts;
  final Color color;
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.t);
  final double t;

  static const _neu = [Color(0xFFEAF3F4), Color(0xFFB7CACD), Color(0xFF8DA5A9)];
  static const _org = [Color(0xFFFDBA74), Color(0xFFFB923C), Color(0xFFE8590C)];
  static const _glass = [
    Color(0x2AFFFFFF),
    Color(0x3CFFFFFF),
    Color(0x22FFFFFF),
  ];
  static const _line = Color(0xFFEAF3F4);
  static const _mint = Color(0xFF5EEAD4);

  static Offset _p(double x, double y, double z) =>
      Offset(0.866 * (x - y), 0.5 * (x + y) - z);

  static List<_Face> _box(double h, double z0, double z1, List<Color> c) => [
    _Face([_p(-h, h, z0), _p(h, h, z0), _p(h, h, z1), _p(-h, h, z1)], c[1]),
    _Face([_p(h, -h, z0), _p(h, h, z0), _p(h, h, z1), _p(h, -h, z1)], c[2]),
    _Face([_p(-h, -h, z1), _p(h, -h, z1), _p(h, h, z1), _p(-h, h, z1)], c[0]),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    const h = 62.0;
    const gMax = 46.0;
    final g = gMax * t;
    // Escala estable: se calcula con la separación máxima para que no "salte" al animar.
    final extent = 24 + gMax + 52 + gMax + 24;
    final xs = h * 0.866 * 2, ys = extent + h;
    final k = size.width * 0.92 / math.max(xs, ys * 0.9);
    final cx = size.width / 2;
    final cy =
        size.height / 2 + (extent / 2 - (24 + g + 52 + g + 24) / 2) * k * 0.5;
    Offset tr(Offset o) => Offset(
      cx + o.dx * k,
      cy +
          (o.dy +
                  (h - extent / 2 + (extent - (24 + g + 52 + g + 24)) / 2) *
                      0) *
              k,
    );

    final zm = 24 + g;
    final zt = zm + 52 + g;
    final parts = <List<_Face>>[
      _box(h, 0, 24, _neu),
      _box(h, zm, zm + 52, _glass),
      _box(h, zt, zt + 24, _org),
    ];
    // Centro vertical: punto medio del conjunto separado.
    final mid = _p(0, 0, (zt + 24) / 2);
    Offset place(Offset o) =>
        Offset(cx + o.dx * k, size.height / 2 + (o.dy - mid.dy) * k);

    for (final p in parts) {
      for (final f in p) {
        final path = Path()
          ..addPolygon([for (final o in f.pts) place(o)], true);
        canvas.drawPath(
          path,
          Paint()
            ..color = f.color
            ..isAntiAlias = true,
        );
      }
    }
    // Contorno del bloque central (alambre).
    final outline = Paint()
      ..color = _line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7 * k
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    for (final f in parts[1]) {
      canvas.drawPath(
        Path()..addPolygon([for (final o in f.pts) place(o)], true),
        outline,
      );
    }
    // Guías discontinuas entre las piezas.
    if (t > 0.05) {
      final dash = Paint()
        ..color = _mint.withValues(alpha: (t * 1.4).clamp(0.0, 1.0))
        ..strokeWidth = 6 * k
        ..strokeCap = StrokeCap.butt;
      void guide(double x, double y, double za, double zb) {
        const n = 5;
        final a = place(_p(x, y, za)), b = place(_p(x, y, zb));
        for (var i = 0; i < n; i += 2) {
          canvas.drawLine(
            Offset.lerp(a, b, i / n)!,
            Offset.lerp(a, b, (i + 1) / n)!,
            dash,
          );
        }
      }

      for (final (x, y) in [(h, h), (-h, h), (h, -h)]) {
        guide(x, y, 24, zm);
        guide(x, y, zm + 52, zt);
      }
    }
    tr; // sin uso
  }

  @override
  bool shouldRepaint(covariant _LogoPainter old) => old.t != t;
}
