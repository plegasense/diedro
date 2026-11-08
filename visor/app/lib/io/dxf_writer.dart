import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/document.dart';
import '../model/shapes.dart';

/// Escribe un dibujo como DXF ASCII (AutoCAD 2000): líneas, círculos, arcos, polilíneas y textos,
/// con una capa por capa del dibujo y su color. [layers] limita las capas que se exportan.
Uint8List writeDxf(DrawingDocument doc, {Set<String>? layers, List<Shape>? shapes}) {
  final out = StringBuffer();
  var handle = 0x30;
  String h() => (handle++).toRadixString(16).toUpperCase();
  void g(int code, Object v) => out
    ..writeln(code.toString().padLeft(3))
    ..writeln(v);
  String num(double v) => v.isFinite ? v.toStringAsFixed(6) : '0';

  final groups = doc.lines.groups;
  String layerOf(int gi) {
    final n = gi < groups.length ? groups[gi].name : '';
    return n.isEmpty ? '0' : n.replaceAll(RegExp(r'[<>/\\":;?*|=`\n\r]'), '_');
  }

  bool wanted(int gi) {
    if (gi < groups.length) {
      if (!groups[gi].visible && layers == null) return false;
      return layers == null || layers.contains(groups[gi].name);
    }
    return true;
  }

  int trueColor(int gi) {
    if (gi >= groups.length) return 0xFFFFFF;
    final g0 = groups[gi];
    if (g0.vertexCount == 0) return 0xFFFFFF;
    final v = doc.lines.vertices, i = g0.firstVertex * 6;
    int c(int k) => (v[i + k] * 255).round().clamp(0, 255);
    return (c(3) << 16) | (c(4) << 8) | c(5);
  }

  final b = doc.lines.bounds;
  g(0, 'SECTION');
  g(2, 'HEADER');
  g(9, r'$ACADVER');
  g(1, 'AC1015');
  g(9, r'$INSUNITS');
  g(70, doc.insUnits);
  g(9, r'$EXTMIN');
  g(10, num(b.min[0]));
  g(20, num(b.min[1]));
  g(30, 0);
  g(9, r'$EXTMAX');
  g(10, num(b.max[0]));
  g(20, num(b.max[1]));
  g(30, 0);
  g(0, 'ENDSEC');

  g(0, 'SECTION');
  g(2, 'TABLES');
  g(0, 'TABLE');
  g(2, 'LAYER');
  g(5, h());
  g(100, 'AcDbSymbolTable');
  final names = <String, int>{'0': 0xFFFFFF};
  for (var gi = 0; gi < math.max(groups.length, 1); gi++) {
    if (!wanted(gi)) continue;
    names.putIfAbsent(layerOf(gi), () => trueColor(gi));
  }
  g(70, names.length);
  for (final e in names.entries) {
    g(0, 'LAYER');
    g(5, h());
    g(100, 'AcDbSymbolTableRecord');
    g(100, 'AcDbLayerTableRecord');
    g(2, e.key);
    g(70, 0);
    g(62, 7);
    g(420, e.value);
    g(6, 'CONTINUOUS');
  }
  g(0, 'ENDTAB');
  g(0, 'ENDSEC');

  g(0, 'SECTION');
  g(2, 'ENTITIES');
  void head(String type, String sub, int gi) {
    g(0, type);
    g(5, h());
    g(100, 'AcDbEntity');
    g(8, layerOf(gi));
    g(100, sub);
  }

  void polyline(Shape s) {
    // rectángulos, polígonos y cadenas: LWPOLYLINE (la última coincide con la primera si cierra)
    final n = s.pointCount;
    final count = s.closed ? n - 1 : n;
    head('LWPOLYLINE', 'AcDbPolyline', s.group);
    g(90, count);
    g(70, s.closed ? 1 : 0);
    for (var i = 0; i < count; i++) {
      g(10, num(s.pts[i * 2]));
      g(20, num(s.pts[i * 2 + 1]));
    }
  }

  for (final s in shapes ?? buildShapes(doc.lines)) {
    if (!wanted(s.group)) continue;
    final n = s.pointCount;
    var kind = s.kind;
    if (kind == ShapeKind.circle || kind == ShapeKind.arc) {
      // sólo si la cadena de segmentos de verdad está sobre la circunferencia
      var chain = 0.0;
      for (var i = 0; i + 1 < n; i++) {
        chain += math.sqrt(math.pow(s.pts[i * 2] - s.pts[i * 2 + 2], 2) + math.pow(s.pts[i * 2 + 1] - s.pts[i * 2 + 3], 2));
      }
      if ((chain - s.length).abs() > chain * 0.01) kind = ShapeKind.polyline;
      for (var i = 0; i < n && kind != ShapeKind.polyline; i++) {
        final d = math.sqrt(math.pow(s.pts[i * 2] - s.cx, 2) + math.pow(s.pts[i * 2 + 1] - s.cy, 2));
        if ((d - s.radius).abs() > s.radius * 0.003) kind = ShapeKind.polyline;
      }
    }
    switch (kind) {
      case ShapeKind.circle:
        head('CIRCLE', 'AcDbCircle', s.group);
        g(10, num(s.cx));
        g(20, num(s.cy));
        g(30, 0);
        g(40, num(s.radius));
      case ShapeKind.arc:
        final a0 = math.atan2(s.pts[1] - s.cy, s.pts[0] - s.cx);
        final a1 = math.atan2(s.pts[(n - 1) * 2 + 1] - s.cy, s.pts[(n - 1) * 2] - s.cx);
        final m = n ~/ 2;
        final am = math.atan2(s.pts[m * 2 + 1] - s.cy, s.pts[m * 2] - s.cx);
        double norm(double a) => (a % (2 * math.pi) + 2 * math.pi) % (2 * math.pi);
        // ¿el punto medio está en el sentido antihorario desde el inicio?
        final ccw = norm(am - a0) < norm(a1 - a0);
        final st = ccw ? a0 : a1, en = ccw ? a1 : a0;
        if ((norm(en - st) - s.sweep).abs() > 0.02 * s.sweep + 1e-3) {
          // el centro ajustado no reproduce el arco (casi recto): se guarda como polilínea
          polyline(s);
          break;
        }
        head('ARC', 'AcDbCircle', s.group);
        g(10, num(s.cx));
        g(20, num(s.cy));
        g(30, 0);
        g(40, num(s.radius));
        g(100, 'AcDbArc');
        g(50, num(norm(st) * 180 / math.pi));
        g(51, num(norm(en) * 180 / math.pi));
      case ShapeKind.line:
        head('LINE', 'AcDbLine', s.group);
        g(10, num(s.pts[0]));
        g(20, num(s.pts[1]));
        g(30, 0);
        g(11, num(s.pts[2]));
        g(21, num(s.pts[3]));
        g(31, 0);
      default:
        polyline(s);
    }
  }
  for (final t in doc.texts) {
    head('TEXT', 'AcDbText', 0);
    g(10, num(t.x));
    g(20, num(t.y));
    g(30, 0);
    g(40, num(t.height));
    g(1, t.text.replaceAll(RegExp(r'[\r\n]+'), ' '));
    g(50, num(t.rotation));
    g(100, 'AcDbText');
  }
  g(0, 'ENDSEC');
  g(0, 'EOF');
  return Uint8List.fromList(utf8.encode(out.toString()));
}
