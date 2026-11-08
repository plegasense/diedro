import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../l10n/l10n.dart';
import 'iso_run.dart';
import '../model/lines.dart';
import '../model/vector_info.dart';
import 'dxf_loader.dart';

/// Código privado de «unidad» para dibujos sin tamaño físico: 1 unidad = 1 px a 96 ppp.
const int kInsUnitsPx96 = 100;

const double _pxPerMm = 96 / 25.4;
const int _kMaxElements = 3000000;

class _T {
  const _T(this.a, this.b, this.c, this.d, this.e, this.f);
  static const identity = _T(1, 0, 0, 1, 0, 0);
  final double a, b, c, d, e, f;
  _T mul(_T o) => _T(
    a * o.a + c * o.b,
    b * o.a + d * o.b,
    a * o.c + c * o.d,
    b * o.c + d * o.d,
    a * o.e + c * o.f + e,
    b * o.e + d * o.f + f,
  );
  double x(double px, double py) => a * px + c * py + e;
  double y(double px, double py) => b * px + d * py + f;
  double get scale => math.sqrt((a * a + b * b + c * c + d * d) / 2);
}

/// Transformaciones SVG. Devuelve `null` si el texto no se puede interpretar.
_T? _parseTransform(String? s) {
  if (s == null || s.trim().isEmpty) return _T.identity;
  var t = _T.identity;
  var seen = 0;
  for (final m in RegExp(r'([A-Za-z]+)\s*\(([^)]*)\)').allMatches(s)) {
    seen++;
    final v = <double>[];
    for (final p in m.group(2)!.trim().split(RegExp(r'[\s,]+'))) {
      if (p.isEmpty) continue;
      final n = double.tryParse(p);
      if (n == null || !n.isFinite) return null;
      v.add(n);
    }
    switch (m.group(1)) {
      case 'matrix' when v.length >= 6:
        t = t.mul(_T(v[0], v[1], v[2], v[3], v[4], v[5]));
      case 'translate' when v.isNotEmpty:
        t = t.mul(_T(1, 0, 0, 1, v[0], v.length > 1 ? v[1] : 0));
      case 'scale' when v.isNotEmpty:
        t = t.mul(_T(v[0], 0, 0, v.length > 1 ? v[1] : v[0], 0, 0));
      case 'rotate' when v.isNotEmpty:
        final a = v[0] * math.pi / 180;
        final c = math.cos(a), s2 = math.sin(a);
        final r = _T(c, s2, -s2, c, 0, 0);
        if (v.length >= 3) {
          t = t
              .mul(_T(1, 0, 0, 1, v[1], v[2]))
              .mul(r)
              .mul(_T(1, 0, 0, 1, -v[1], -v[2]));
        } else {
          t = t.mul(r);
        }
      case 'skewX' when v.isNotEmpty:
        t = t.mul(_T(1, 0, math.tan(v[0] * math.pi / 180), 1, 0, 0));
      case 'skewY' when v.isNotEmpty:
        t = t.mul(_T(1, math.tan(v[0] * math.pi / 180), 0, 1, 0, 0));
      default:
        return null;
    }
  }
  return seen == 0 ? null : t;
}

/// Longitud con unidad → píxeles de usuario a 96 ppp. `ref` es la base de los porcentajes.
double? _lenPx(String? s, {double ref = 0, double em = 16}) {
  if (s == null) return null;
  final m = RegExp(
    r'^\s*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)\s*(px|mm|cm|in|pt|pc|Q|em|ex|%)?\s*$',
  ).firstMatch(s);
  if (m == null) return null;
  final v = double.tryParse(m.group(1)!);
  if (v == null || !v.isFinite) return null;
  return switch (m.group(2)) {
    'mm' => v * _pxPerMm,
    'cm' => v * 10 * _pxPerMm,
    'Q' => v * 0.25 * _pxPerMm,
    'in' => v * 96,
    'pt' => v * 96 / 72,
    'pc' => v * 16,
    'em' => v * em,
    'ex' => v * em / 2,
    '%' => v * ref / 100,
    _ => v,
  };
}

/// Matriz de un `viewBox` dentro de un área `w × h`, según `preserveAspectRatio` (meet, slice o none).
_T _viewBoxMap(List<double> vb, double w, double h, String? par) {
  final parts = (par ?? '').trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty && e != 'defer').toList();
  final align = parts.isNotEmpty ? parts[0] : 'xMidYMid';
  final sx = w / vb[2], sy = h / vb[3];
  if (align == 'none') return _T(sx, 0, 0, sy, -vb[0] * sx, -vb[1] * sy);
  final s = parts.contains('slice') ? math.max(sx, sy) : math.min(sx, sy);
  final rx = w - vb[2] * s, ry = h - vb[3] * s;
  final tx = align.contains('xMin') ? 0.0 : (align.contains('xMax') ? rx : rx / 2);
  final ty = align.contains('YMin') ? 0.0 : (align.contains('YMax') ? ry : ry / 2);
  return _T(s, 0, 0, s, tx - vb[0] * s, ty - vb[1] * s);
}

List<double>? _parseViewBox(String? s) {
  if (s == null) return null;
  final v = s.trim().split(RegExp(r'[\s,]+')).map(double.tryParse).toList();
  if (v.length != 4 || v.contains(null) || v[2]! <= 0 || v[3]! <= 0) return null;
  return [for (final e in v) e!];
}

bool _isPhysical(String? s) =>
    s != null && RegExp(r'(mm|cm|in|pt|pc|Q)\s*$').hasMatch(s.trim());

const _named = {
  'black': 0x000000,
  'white': 0xFFFFFF,
  'red': 0xFF0000,
  'green': 0x008000,
  'lime': 0x00FF00,
  'blue': 0x0000FF,
  'yellow': 0xFFFF00,
  'cyan': 0x00FFFF,
  'aqua': 0x00FFFF,
  'magenta': 0xFF00FF,
  'fuchsia': 0xFF00FF,
  'gray': 0x808080,
  'grey': 0x808080,
  'silver': 0xC0C0C0,
  'maroon': 0x800000,
  'olive': 0x808000,
  'navy': 0x000080,
  'teal': 0x008080,
  'orange': 0xFFA500,
  'purple': 0x800080,
  'brown': 0xA52A2A,
  'pink': 0xFFC0CB,
  'gold': 0xFFD700,
  'violet': 0xEE82EE,
  'indigo': 0x4B0082,
  'crimson': 0xDC143C,
  'coral': 0xFF7F50,
  'salmon': 0xFA8072,
  'khaki': 0xF0E68C,
  'turquoise': 0x40E0D0,
  'tan': 0xD2B48C,
  'lightgray': 0xD3D3D3,
  'lightgrey': 0xD3D3D3,
  'darkgray': 0xA9A9A9,
  'darkgrey': 0xA9A9A9,
  'dimgray': 0x696969,
  'darkred': 0x8B0000,
  'darkgreen': 0x006400,
  'darkblue': 0x00008B,
  'lightblue': 0xADD8E6,
  'lightgreen': 0x90EE90,
  'skyblue': 0x87CEEB,
  'royalblue': 0x4169E1,
  'steelblue': 0x4682B4,
  'orangered': 0xFF4500,
  'deeppink': 0xFF1493,
  'hotpink': 0xFF69B4,
  'chocolate': 0xD2691E,
  'sienna': 0xA0522D,
  'beige': 0xF5F5DC,
  'ivory': 0xFFFFF0,
  'lavender': 0xE6E6FA,
  'limegreen': 0x32CD32,
  'forestgreen': 0x228B22,
  'seagreen': 0x2E8B57,
  'slategray': 0x708090,
  'slategrey': 0x708090,
};

const int _none = -1;

/// Color de relleno o contorno. `null` = no se entiende (se hereda); `-1` = ninguno.
int? _parsePaint(String? raw, int current, VectorInfo info, [Map<String, XmlElement>? ids]) {
  if (raw == null) return null;
  var s = raw.trim().toLowerCase();
  if (s.isEmpty || s == 'inherit') return null;
  if (s == 'none' || s == 'transparent') return _none;
  if (s == 'currentcolor') return current;
  if (s.startsWith('url(')) {
    info.count(tr('degradados o patrones'));
    final fb = s.substring(s.indexOf(')') + 1).trim();
    if (fb.isNotEmpty) return _parsePaint(fb, current, info);
    // degradado: se usa el color de su primera parada (siguiendo `href` entre degradados)
    final m = RegExp(r'url\(\s*#?([^)\s]+)\s*\)').firstMatch(s);
    XmlElement? el;
    if (m != null && ids != null) el = ids[m.group(1)];
    for (var hop = 0; el != null && hop < 6; hop++) {
      if (el.name.local == 'linearGradient' || el.name.local == 'radialGradient') {
        for (final c in el.childElements) {
          if (c.name.local != 'stop') continue;
          final sc = c.getAttribute('stop-color') ?? _declarations(c.getAttribute('style') ?? '')['stop-color'];
          final v = sc == null ? null : _parsePaint(sc, current, info);
          if (v != null && v >= 0) return v;
        }
        final href = el.getAttribute('xlink:href') ?? el.getAttribute('href');
        XmlElement? nxt;
        if (href != null && href.startsWith('#') && ids != null) nxt = ids[href.substring(1)];
        el = nxt;
      } else {
        break;
      }
    }
    return 0x888888;
  }
  if (s.startsWith('#')) {
    final h = s.substring(1);
    final ok = RegExp(r'^[0-9a-f]+$').hasMatch(h);
    if (!ok) return null;
    if (h.length == 3 || h.length == 4) {
      return int.parse('${h[0]}${h[0]}${h[1]}${h[1]}${h[2]}${h[2]}', radix: 16);
    }
    if (h.length == 6 || h.length == 8) return int.parse(h.substring(0, 6), radix: 16);
    return null;
  }
  final m = RegExp(
    r'^rgba?\(\s*([\d.]+)(%?)[,\s]+([\d.]+)(%?)[,\s]+([\d.]+)(%?)',
  ).firstMatch(s);
  if (m != null) {
    int ch(int i) {
      final v = double.tryParse(m.group(i)!) ?? 0;
      final pct = m.group(i + 1) == '%';
      return (pct ? v * 2.55 : v).round().clamp(0, 255);
    }

    return (ch(1) << 16) | (ch(3) << 8) | ch(5);
  }
  final h = RegExp(
    r'^hsla?\(\s*([\d.]+)(?:deg)?[,\s]+([\d.]+)%[,\s]+([\d.]+)%',
  ).firstMatch(s);
  if (h != null) {
    final hh = ((double.tryParse(h.group(1)!) ?? 0) % 360) / 360;
    final ss = ((double.tryParse(h.group(2)!) ?? 0) / 100).clamp(0.0, 1.0);
    final ll = ((double.tryParse(h.group(3)!) ?? 0) / 100).clamp(0.0, 1.0);
    final q = ll < 0.5 ? ll * (1 + ss) : ll + ss - ll * ss;
    final p = 2 * ll - q;
    double f(double t) {
      t = t < 0 ? t + 1 : (t > 1 ? t - 1 : t);
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }

    int c(double v) => (v * 255).round().clamp(0, 255);
    return (c(f(hh + 1 / 3)) << 16) | (c(f(hh)) << 8) | c(f(hh - 1 / 3));
  }
  return _named[s];
}

String _hex(int rgb) =>
    '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';

// ---------------------------------------------------------------- CSS

class _CssRule {
  _CssRule(this.tag, this.id, this.classes, this.decls, this.order);
  final String? tag, id;
  final List<String> classes;
  final Map<String, String> decls;
  final int order;
  int get spec => (id != null ? 10000 : 0) + classes.length * 100 + (tag != null && tag != '*' ? 1 : 0);

  bool matches(String name, String? eid, Set<String> cls) {
    if (tag != null && tag != '*' && tag != name) return false;
    if (id != null && id != eid) return false;
    for (final c in classes) {
      if (!cls.contains(c)) return false;
    }
    return true;
  }
}

Map<String, String> _declarations(String text) {
  final out = <String, String>{};
  for (final part in text.split(';')) {
    final i = part.indexOf(':');
    if (i <= 0) continue;
    final k = part.substring(0, i).trim().toLowerCase();
    var v = part.substring(i + 1).trim();
    v = v.replaceAll(RegExp(r'\s*!important\s*$'), '');
    if (k.isNotEmpty) out[k] = v;
  }
  return out;
}

List<_CssRule> _parseCss(String css) {
  css = css.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final rules = <_CssRule>[];
  var order = 0;
  for (final m in RegExp(r'([^{}@]+)\{([^{}]*)\}').allMatches(css)) {
    final decls = _declarations(m.group(2)!);
    if (decls.isEmpty) continue;
    for (final sel in m.group(1)!.split(',')) {
      final parts = sel.trim().split(RegExp(r'\s*[>+~]\s*|\s+'));
      final s = parts.isEmpty ? '' : parts.last;
      if (s.isEmpty || s.contains('[') || s.contains(':')) continue;
      final tag = RegExp(r'^(\*|[A-Za-z][\w-]*)').firstMatch(s)?.group(1);
      final id = RegExp(r'#([\w-]+)').firstMatch(s)?.group(1);
      final classes = [
        for (final c in RegExp(r'\.([\w-]+)').allMatches(s)) c.group(1)!,
      ];
      rules.add(_CssRule(tag, id, classes, decls, order++));
    }
  }
  rules.sort((a, b) {
    final c = a.spec.compareTo(b.spec);
    return c != 0 ? c : a.order.compareTo(b.order);
  });
  return rules;
}

const _styleProps = {
  'stroke',
  'fill',
  'display',
  'visibility',
  'stroke-width',
  'stroke-dasharray',
  'font-size',
  'color',
  'clip-path',
  'mask',
  'filter',
};

Map<String, String> _styleOf(XmlElement e, List<_CssRule> css) {
  final out = <String, String>{};
  for (final a in e.attributes) {
    final n = a.name.local;
    if (a.name.prefix == null && _styleProps.contains(n)) out[n] = a.value;
  }
  if (css.isNotEmpty) {
    final cls = (e.getAttribute('class') ?? '')
        .split(RegExp(r'\s+'))
        .where((c) => c.isNotEmpty)
        .toSet();
    final id = e.getAttribute('id');
    for (final r in css) {
      if (r.matches(e.name.local, id, cls)) out.addAll(r.decls);
    }
  }
  final st = e.getAttribute('style');
  if (st != null) out.addAll(_declarations(st));
  return out;
}

class _Paint {
  const _Paint({
    this.stroke = _none,
    this.fill = 0x000000,
    this.color = 0x000000,
    this.hidden = false,
    this.fontSize = 16,
  });
  final int stroke, fill, color;
  final bool hidden;
  final double fontSize;
}

// ---------------------------------------------------------------- Rutas

class _Scan {
  _Scan(this.s);
  final String s;
  int i = 0;

  void ws() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 32 || c == 9 || c == 10 || c == 13 || c == 44) {
        i++;
      } else {
        break;
      }
    }
  }

  bool get done {
    ws();
    return i >= s.length;
  }

  bool get atCommand {
    ws();
    if (i >= s.length) return false;
    return 'MmLlHhVvCcSsQqTtAaZz'.contains(s[i]);
  }

  String take() => s[i++];

  double? num() {
    ws();
    final start = i;
    if (i < s.length && (s[i] == '+' || s[i] == '-')) i++;
    var digits = 0;
    while (i < s.length && _isDigit(s.codeUnitAt(i))) {
      i++;
      digits++;
    }
    if (i < s.length && s[i] == '.') {
      i++;
      while (i < s.length && _isDigit(s.codeUnitAt(i))) {
        i++;
        digits++;
      }
    }
    if (digits == 0) {
      i = start;
      return null;
    }
    if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
      var j = i + 1;
      if (j < s.length && (s[j] == '+' || s[j] == '-')) j++;
      if (j < s.length && _isDigit(s.codeUnitAt(j))) {
        while (j < s.length && _isDigit(s.codeUnitAt(j))) {
          j++;
        }
        i = j;
      }
    }
    final v = double.tryParse(s.substring(start, i));
    return v != null && v.isFinite ? v : null;
  }

  bool? flag() {
    ws();
    if (i < s.length && (s[i] == '0' || s[i] == '1')) {
      return s[i++] == '1';
    }
    return null;
  }

  static bool _isDigit(int c) => c >= 48 && c <= 57;
}

/// Lee una cadena `d` y devuelve los subtrazados (x,y,x,y…) ya transformados.
/// `bad` pasa a verdadero si había datos erróneos: se dibuja hasta el error, como los navegadores.
List<List<double>> _flatten(
  String d,
  _T t,
  double tol,
  void Function() bad,
) {
  final subs = <List<double>>[];
  var cur = <double>[];
  final sc = _Scan(d);
  double cx = 0, cy = 0, sx = 0, sy = 0, lcx = 0, lcy = 0;
  var cmd = '';
  var prev = '';
  var started = false;

  void flush() {
    if (cur.length >= 4) subs.add(cur);
    cur = <double>[];
  }

  void pt(double x, double y) {
    cur
      ..add(t.x(x, y))
      ..add(t.y(x, y));
  }

  void begin(double x, double y) {
    flush();
    pt(x, y);
  }

  void ensure() {
    if (cur.isEmpty) pt(cx, cy);
  }

  void cubic(double x1, double y1, double x2, double y2, double x3, double y3) {
    ensure();
    final len =
        (x1 - cx).abs() + (y1 - cy).abs() + (x2 - x1).abs() + (y2 - y1).abs() + (x3 - x2).abs() + (y3 - y2).abs();
    final n = ((len * t.scale) / (tol * 40)).ceil().clamp(4, 96);
    final ox = cx, oy = cy;
    for (var k = 1; k <= n; k++) {
      final s = k / n, u = 1 - s;
      pt(
        u * u * u * ox + 3 * u * u * s * x1 + 3 * u * s * s * x2 + s * s * s * x3,
        u * u * u * oy + 3 * u * u * s * y1 + 3 * u * s * s * y2 + s * s * s * y3,
      );
    }
    lcx = x2;
    lcy = y2;
    cx = x3;
    cy = y3;
  }

  void arc(double rx, double ry, double phi, bool large, bool sweep, double x, double y) {
    ensure();
    if (x == cx && y == cy) return;
    if (rx == 0 || ry == 0) {
      pt(x, y);
      cx = x;
      cy = y;
      return;
    }
    rx = rx.abs();
    ry = ry.abs();
    final p = phi * math.pi / 180, cp = math.cos(p), sp = math.sin(p);
    final dx = (cx - x) / 2, dy = (cy - y) / 2;
    final x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy;
    final lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
    if (lam > 1) {
      rx *= math.sqrt(lam);
      ry *= math.sqrt(lam);
    }
    final sign = large == sweep ? -1.0 : 1.0;
    final num2 = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
    final den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
    final co = den == 0 ? 0.0 : sign * math.sqrt(math.max(0, num2 / den));
    final cxp = co * rx * y1 / ry, cyp = -co * ry * x1 / rx;
    final ccx = cp * cxp - sp * cyp + (cx + x) / 2, ccy = sp * cxp + cp * cyp + (cy + y) / 2;
    double ang(double ux, double uy, double vx, double vy) => math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
    final th1 = ang(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry);
    var dth = ang((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry);
    if (!sweep && dth > 0) dth -= 2 * math.pi;
    if (sweep && dth < 0) dth += 2 * math.pi;
    final n = ((dth.abs() * math.max(rx, ry) * t.scale) / (tol * 30)).ceil().clamp(6, 180);
    for (var k = 1; k <= n; k++) {
      final a = th1 + dth * k / n;
      pt(
        cp * rx * math.cos(a) - sp * ry * math.sin(a) + ccx,
        sp * rx * math.cos(a) + cp * ry * math.sin(a) + ccy,
      );
    }
    cx = x;
    cy = y;
  }

  loop:
  while (!sc.done) {
    if (sc.atCommand) {
      cmd = sc.take();
      if (!started && cmd != 'M' && cmd != 'm') {
        bad();
        break;
      }
    } else if (cmd.isEmpty || cmd == 'z' || cmd == 'Z') {
      bad();
      break;
    }
    started = true;
    final rel = cmd == cmd.toLowerCase();
    final up = cmd.toUpperCase();
    double? n() => sc.num();
    switch (up) {
      case 'M':
        final a = n(), b = n();
        if (a == null || b == null) {
          bad();
          break loop;
        }
        final x = a + (rel ? cx : 0), y = b + (rel ? cy : 0);
        begin(x, y);
        cx = sx = x;
        cy = sy = y;
        cmd = rel ? 'l' : 'L';
      case 'L':
        final a = n(), b = n();
        if (a == null || b == null) {
          bad();
          break loop;
        }
        ensure();
        final x = a + (rel ? cx : 0), y = b + (rel ? cy : 0);
        pt(x, y);
        cx = x;
        cy = y;
      case 'H':
        final a = n();
        if (a == null) {
          bad();
          break loop;
        }
        ensure();
        cx = a + (rel ? cx : 0);
        pt(cx, cy);
      case 'V':
        final a = n();
        if (a == null) {
          bad();
          break loop;
        }
        ensure();
        cy = a + (rel ? cy : 0);
        pt(cx, cy);
      case 'C':
        final v = [n(), n(), n(), n(), n(), n()];
        if (v.contains(null)) {
          bad();
          break loop;
        }
        final ox = rel ? cx : 0.0, oy = rel ? cy : 0.0;
        cubic(v[0]! + ox, v[1]! + oy, v[2]! + ox, v[3]! + oy, v[4]! + ox, v[5]! + oy);
      case 'S':
        final v = [n(), n(), n(), n()];
        if (v.contains(null)) {
          bad();
          break loop;
        }
        final ox = rel ? cx : 0.0, oy = rel ? cy : 0.0;
        final smooth = prev == 'C' || prev == 'S';
        cubic(smooth ? 2 * cx - lcx : cx, smooth ? 2 * cy - lcy : cy, v[0]! + ox, v[1]! + oy, v[2]! + ox, v[3]! + oy);
      case 'Q':
        final v = [n(), n(), n(), n()];
        if (v.contains(null)) {
          bad();
          break loop;
        }
        final ox = rel ? cx : 0.0, oy = rel ? cy : 0.0;
        final qx = v[0]! + ox, qy = v[1]! + oy, x = v[2]! + ox, y = v[3]! + oy;
        final fx = cx, fy = cy;
        cubic(fx + 2 / 3 * (qx - fx), fy + 2 / 3 * (qy - fy), x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y), x, y);
        lcx = qx;
        lcy = qy;
      case 'T':
        final a = n(), b = n();
        if (a == null || b == null) {
          bad();
          break loop;
        }
        final x = a + (rel ? cx : 0), y = b + (rel ? cy : 0);
        final smooth = prev == 'Q' || prev == 'T';
        final qx = smooth ? 2 * cx - lcx : cx, qy = smooth ? 2 * cy - lcy : cy;
        final fx = cx, fy = cy;
        cubic(fx + 2 / 3 * (qx - fx), fy + 2 / 3 * (qy - fy), x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y), x, y);
        lcx = qx;
        lcy = qy;
      case 'A':
        final rx = n(), ry = n(), phi = n();
        final large = sc.flag(), sweep = sc.flag();
        final a = n(), b = n();
        if (rx == null || ry == null || phi == null || large == null || sweep == null || a == null || b == null) {
          bad();
          break loop;
        }
        arc(rx, ry, phi, large, sweep, a + (rel ? cx : 0), b + (rel ? cy : 0));
      case 'Z':
        ensure();
        pt(sx, sy);
        flush();
        cx = sx;
        cy = sy;
    }
    prev = up;
  }
  flush();
  return subs;
}

// ---------------------------------------------------------------- Lectura

String _readText(String path) {
  final bytes = File(path).readAsBytesSync();
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.startsWith('﻿')) text = text.substring(1);
  // Illustrator declara entidades en el DOCTYPE; las sustituimos una vez y quitamos el DOCTYPE.
  final dt = RegExp(r'<!DOCTYPE[^\[>]*\[(.*?)\]\s*>', dotAll: true).firstMatch(text);
  if (dt != null) {
    final ents = <String, String>{};
    for (final m in RegExp(r'<!ENTITY\s+([\w.-]+)\s+"([^"]{0,300})"\s*>').allMatches(dt.group(1)!)) {
      ents[m.group(1)!] = m.group(2)!;
    }
    text = text.replaceRange(dt.start, dt.end, '');
    if (ents.isNotEmpty) {
      text = text.replaceAllMapped(RegExp(r'&([\w.-]+);'), (m) => ents[m.group(1)] ?? m.group(0)!);
    }
  }
  return text;
}

String? _generator(String text, XmlElement root) {
  final head = text.length > 6000 ? text.substring(0, 6000) : text;
  final inkV = root.attributes.where((a) => a.name.local == 'version' && a.name.prefix == 'inkscape');
  if (inkV.isNotEmpty) return 'Inkscape ${inkV.first.value.split(' ').first}';
  final ill = RegExp(r'Adobe Illustrator\s*([\d.]+)?').firstMatch(head);
  if (ill != null) return 'Adobe Illustrator${ill.group(1) != null ? ' ${ill.group(1)}' : ''}';
  for (final g in [
    ('LightBurn', 'LightBurn'),
    ('vpype', 'vpype'),
    ('Inkscape', 'Inkscape'),
    ('matplotlib', 'Matplotlib'),
    ('Sketch', 'Sketch'),
    ('Figma', 'Figma'),
    ('CorelDRAW', 'CorelDRAW'),
    ('Affinity', 'Affinity'),
    ('Fusion', 'Autodesk Fusion'),
    ('svgwrite', 'svgwrite'),
    ('Generated by', tr('Generado por programa')),
  ]) {
    if (head.contains(g.$1)) return g.$2;
  }
  if (head.contains('cairo')) return 'Cairo';
  return null;
}

/// Lee SVG: formas, trazados, transformaciones, estilos CSS, `use`, capas de Inkscape y texto.
/// La geometría sale en mm cuando el archivo declara su tamaño y en px de 96 ppp si no.
DxfData parseSvg(String path) {
  try {
    return _parseSvg(path);
  } on FormatException {
    rethrow;
  } on Error catch (e) {
    throw FormatException(tr('El SVG no se puede interpretar ({t})', {'t': e.runtimeType}));
  }
}

DxfData _parseSvg(String path) {
  final name = path.split('/').last;
  final text = _readText(path);
  late final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } on XmlException catch (e) {
    throw FormatException(tr('El SVG está mal formado: {m}', {'m': e.message}));
  }
  final root = doc.rootElement;
  if (root.name.local != 'svg') {
    throw FormatException(tr('El archivo no es un SVG (falta el elemento raíz «svg»)'));
  }
  final info = VectorInfo('SVG')..generator = _generator(text, root);

  // ---- Tamaño, viewBox y unidades
  final vb = _parseViewBox(root.getAttribute('viewBox'));
  final wAttr = root.getAttribute('width'), hAttr = root.getAttribute('height');
  final physical = _isPhysical(wAttr) || _isPhysical(hAttr);
  double? wPx = _lenPx(wAttr, ref: vb?[2] ?? 0);
  double? hPx = _lenPx(hAttr, ref: vb?[3] ?? 0);
  if (wPx != null && wPx <= 0) wPx = null;
  if (hPx != null && hPx <= 0) hPx = null;
  if (vb != null) {
    final ratio = vb[2] / vb[3];
    if (wPx == null && hPx == null) {
      wPx = vb[2];
      hPx = vb[3];
    } else if (wPx == null) {
      wPx = hPx! * ratio;
    } else if (hPx == null) {
      hPx = wPx / ratio;
    }
  }
  var base = _T.identity;
  var vbW = vb?[2] ?? wPx ?? 1000.0, vbH = vb?[3] ?? hPx ?? 1000.0;
  if (vb != null) base = _viewBoxMap(vb, wPx!, hPx!, root.getAttribute('preserveAspectRatio'));
  var insUnits = kInsUnitsPx96;
  if (physical && wPx != null && hPx != null) {
    insUnits = 4;
    info
      ..declaredWidthMm = wPx / _pxPerMm
      ..declaredHeightMm = hPx / _pxPerMm
      ..unitNote = tr('Tamaño declarado por el archivo: se leen las medidas en milímetros reales.');
    base = _T(1 / _pxPerMm, 0, 0, 1 / _pxPerMm, 0, 0).mul(base);
  } else {
    info.unitNote = tr('El archivo no declara un tamaño físico: se toma 1 unidad = 1 px a 96 ppp (Inkscape, navegadores). Illustrator antiguo usa 72 ppp: cámbialo en «Datos de corte» si no cuadra.');
    if (wPx != null && hPx != null) {
      info
        ..declaredWidthMm = null
        ..declaredHeightMm = null;
    }
  }
  final diag = math.sqrt(vbW * vbW + vbH * vbH) * base.scale;
  final tol = math.max(diag * 1e-4, 1e-5);

  // ---- Estilos y referencias
  final css = <_CssRule>[];
  final ids = <String, XmlElement>{};
  for (final e in root.descendantElements) {
    final id = e.getAttribute('id');
    if (id != null) ids.putIfAbsent(id, () => e);
    if (e.name.local == 'style') {
      final type = e.getAttribute('type');
      if (type == null || type.isEmpty || type.contains('css')) css.addAll(_parseCss(e.innerText));
    }
  }
  if (css.length > 1) {
    css.sort((a, b) {
      final c = a.spec.compareTo(b.spec);
      return c != 0 ? c : a.order.compareTo(b.order);
    });
  }
  info.usesCss = css.isNotEmpty;

  // ---- Salida
  final perLayer = <String, List<double>>{};
  final texts = <DrawingText>[];
  var elements = 0;

  final clipStack = <List<double>>[]; // polígonos convexos (x,y,…) en las coordenadas de salida

  /// Recorta un segmento contra un polígono convexo (Cyrus–Beck); devuelve null si queda fuera.
  List<double>? clipSeg(List<double> poly, double x0, double y0, double x1, double y1) {
    final n = poly.length ~/ 2;
    // orientación del polígono para saber qué lado es el interior
    var area = 0.0;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      area += poly[i * 2] * poly[j * 2 + 1] - poly[j * 2] * poly[i * 2 + 1];
    }
    final sgn = area >= 0 ? 1.0 : -1.0;
    var t0 = 0.0, t1 = 1.0;
    final dx = x1 - x0, dy = y1 - y0;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final ex = poly[j * 2] - poly[i * 2], ey = poly[j * 2 + 1] - poly[i * 2 + 1];
      // normal hacia el interior
      final nx = -ey * sgn, ny = ex * sgn;
      final num = nx * (x0 - poly[i * 2]) + ny * (y0 - poly[i * 2 + 1]);
      final den = nx * dx + ny * dy;
      if (den.abs() < 1e-15) {
        if (num < 0) return null;
        continue;
      }
      final t = -num / den;
      if (den > 0) {
        if (t > t0) t0 = t;
      } else {
        if (t < t1) t1 = t;
      }
      if (t0 > t1) return null;
    }
    return [x0 + dx * t0, y0 + dy * t0, x0 + dx * t1, y0 + dy * t1];
  }

  void seg(String layer, int rgb, double x0, double y0, double x1, double y1) {
    for (final cp in clipStack) {
      final c = clipSeg(cp, x0, y0, x1, y1);
      if (c == null) return;
      x0 = c[0];
      y0 = c[1];
      x1 = c[2];
      y1 = c[3];
    }
    final l = perLayer.putIfAbsent(layer, () => <double>[]);
    var r = ((rgb >> 16) & 255).toDouble(), g = ((rgb >> 8) & 255).toDouble(), b = (rgb & 255).toDouble();
    final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    final lift = ((140 - lum) / 140).clamp(0.0, 1.0) * 0.7;
    r += (255 - r) * lift;
    g += (255 - g) * lift;
    b += (255 - b) * lift;
    l.addAll([x0, -y0, 0, r / 255, g / 255, b / 255, x1, -y1, 0, r / 255, g / 255, b / 255]);
  }

  void poly(String layer, int rgb, List<double> pts, bool closed) {
    final n = pts.length ~/ 2;
    for (var i = 0; i + 1 < n; i++) {
      seg(layer, rgb, pts[i * 2], pts[i * 2 + 1], pts[i * 2 + 2], pts[i * 2 + 3]);
    }
    if (closed && n > 2) seg(layer, rgb, pts[(n - 1) * 2], pts[(n - 1) * 2 + 1], pts[0], pts[1]);
  }

  const skip = {
    'defs', 'clipPath', 'mask', 'pattern', 'marker', 'symbol', 'metadata', 'title', 'desc', 'style',
    'script', 'filter', 'linearGradient', 'radialGradient', 'foreignObject', 'namedview', 'font',
    'font-face', 'cursor', 'view', 'animate', 'set', 'animateTransform',
  };

  final useStack = <String>[];

  void emit(XmlElement e, _T t, String? inkLayer, _Paint inherited, int depth) {
    if (++elements > _kMaxElements) {
      throw FormatException(tr('El SVG tiene demasiados elementos (más de 3 millones)'));
    }
    if (depth > 64) {
      info.count(tr('anidamiento excesivo'));
      return;
    }
    final local = e.name.local;
    if (skip.contains(local)) return;
    final st = _styleOf(e, css);
    if ((st['display'] ?? '').trim() == 'none') {
      info.count(tr('elementos ocultos'));
      return;
    }
    final color = _parsePaint(st['color'], inherited.color, info, ids) ?? inherited.color;
    final stroke = _parsePaint(st['stroke'], color, info, ids) ?? inherited.stroke;
    final fill = _parsePaint(st['fill'], color, info, ids) ?? inherited.fill;
    final vis = (st['visibility'] ?? '').trim();
    final hidden = vis == 'hidden' || vis == 'collapse' ? true : (vis == 'visible' ? false : inherited.hidden);
    var fs = inherited.fontSize;
    if (st['font-size'] != null) fs = _lenPx(st['font-size'], ref: inherited.fontSize, em: inherited.fontSize) ?? fs;
    final paint = _Paint(stroke: stroke, fill: fill, color: color, hidden: hidden, fontSize: fs);

    final xf = _parseTransform(e.getAttribute('transform'));
    if (e.getAttribute('transform') != null && xf == null) {
      info.count(tr('transformaciones inválidas'));
    }
    final tt = t.mul(xf ?? _T.identity);
    var pushedClip = false;
    final cpAttr = st['clip-path'];
    if (cpAttr != null && cpAttr != 'none') {
      final cm = RegExp(r'url\(\s*#?([^)\s]+)\s*\)').firstMatch(cpAttr);
      final cel = cm == null ? null : ids[cm.group(1)];
      List<double>? poly;
      if (cel != null && cel.name.local == 'clipPath' && cel.getAttribute('transform') == null) {
        final kids = cel.childElements.toList();
        if (kids.length == 1 && kids.first.name.local == 'rect' && kids.first.getAttribute('transform') == null) {
          final r = kids.first;
          final x = _lenPx(r.getAttribute('x')) ?? 0, y = _lenPx(r.getAttribute('y')) ?? 0;
          final w = _lenPx(r.getAttribute('width'), ref: vbW) ?? 0, h = _lenPx(r.getAttribute('height'), ref: vbH) ?? 0;
          if (w > 0 && h > 0) {
            poly = [
              tt.x(x, y), tt.y(x, y),
              tt.x(x + w, y), tt.y(x + w, y),
              tt.x(x + w, y + h), tt.y(x + w, y + h),
              tt.x(x, y + h), tt.y(x, y + h),
            ];
          }
        }
      }
      if (poly != null) {
        clipStack.add(poly);
        pushedClip = true;
        info.count(tr('recortes aplicados'));
      } else {
        info.count(tr('recortes (clip-path)'));
      }
    }
    if (st['mask'] != null && st['mask'] != 'none') info.count(tr('máscaras'));
    if (st['filter'] != null && st['filter'] != 'none') info.count(tr('filtros'));

    double len(String n, [double ref = 0]) => _lenPx(e.getAttribute(n), ref: ref, em: fs) ?? 0;

    void shape(String layerName, List<double> pts, bool closed) {
      if (hidden) return;
      final drawn = stroke != _none ? stroke : fill;
      if (drawn == _none) {
        info.count(tr('sin contorno ni relleno'));
        return;
      }
      final dash = (st['stroke-dasharray'] ?? 'none').trim();
      if (stroke != _none && dash != 'none' && dash.isNotEmpty && dash != '0') info.count(tr('trazos discontinuos'));
      poly(layerName, drawn, pts, closed);
    }

    String layerFor() {
      if (inkLayer != null) return inkLayer;
      final drawn = stroke != _none ? stroke : fill;
      if (drawn == _none) return tr('Dibujo');
      return stroke != _none ? _hex(drawn) : tr('{c} sin contorno', {'c': _hex(drawn)});
    }

    try {
    switch (local) {
      case 'g' || 'svg' || 'a' || 'switch':
        String? lay = inkLayer;
        if (local == 'g' && e.getAttribute('inkscape:groupmode') == 'layer') {
          lay = (e.getAttribute('inkscape:label') ?? e.getAttribute('id') ?? tr('Capa')).trim();
          info.count(tr('capas de Inkscape'));
        }
        var tn = tt;
        final savedW = vbW, savedH = vbH;
        if (local == 'svg' && depth > 0) {
          tn = tn.mul(_T(1, 0, 0, 1, len('x', vbW), len('y', vbH)));
          final nw = _lenPx(e.getAttribute('width'), ref: vbW) ?? vbW;
          final nh = _lenPx(e.getAttribute('height'), ref: vbH) ?? vbH;
          final nvb = _parseViewBox(e.getAttribute('viewBox'));
          if (nvb != null && nw > 0 && nh > 0) {
            tn = tn.mul(_viewBoxMap(nvb, nw, nh, e.getAttribute('preserveAspectRatio')));
            vbW = nvb[2];
            vbH = nvb[3];
          } else {
            vbW = nw;
            vbH = nh;
          }
        }
        if (local == 'switch') {
          for (final c in e.childElements) {
            final sl = c.getAttribute('systemLanguage');
            if (sl != null && !sl.split(',').any((l) => l.trim().toLowerCase().startsWith('en') || l.trim().toLowerCase().startsWith('es'))) {
              continue;
            }
            emit(c, tn, lay, paint, depth + 1);
            break;
          }
          return;
        }
        for (final c in e.childElements) {
          emit(c, tn, lay, paint, depth + 1);
        }
        vbW = savedW;
        vbH = savedH;
      case 'use':
        final href = (e.getAttribute('xlink:href') ?? e.getAttribute('href') ?? '').trim();
        if (!href.startsWith('#')) {
          info.count(tr('referencias externas'));
          return;
        }
        final id = href.substring(1);
        final target = ids[id];
        if (target == null) return;
        if (useStack.contains(id)) {
          info.count(tr('referencias circulares'));
          return;
        }
        info.count(tr('instancias (use)'));
        final tu = tt.mul(_T(1, 0, 0, 1, len('x', vbW), len('y', vbH)));
        useStack.add(id);
        if (target.name.local == 'symbol' || (target.name.local == 'svg')) {
          var ts = tu;
          final savedW = vbW, savedH = vbH;
          final uw = _lenPx(e.getAttribute('width'), ref: vbW) ?? vbW;
          final uh = _lenPx(e.getAttribute('height'), ref: vbH) ?? vbH;
          final nvb = _parseViewBox(target.getAttribute('viewBox'));
          if (nvb != null && uw > 0 && uh > 0) {
            ts = ts.mul(_viewBoxMap(nvb, uw, uh, target.getAttribute('preserveAspectRatio')));
            vbW = nvb[2];
            vbH = nvb[3];
          }
          for (final c in target.childElements) {
            emit(c, ts, inkLayer, paint, depth + 1);
          }
          vbW = savedW;
          vbH = savedH;
        } else {
          emit(target, tu, inkLayer, paint, depth + 1);
        }
        useStack.removeLast();
      case 'path':
        info.count(tr('trazados'));
        var bad = false;
        final subs = _flatten(e.getAttribute('d') ?? '', tt, tol, () => bad = true);
        if (bad) info.count(tr('trazados con datos erróneos'));
        final lay = layerFor();
        for (final s in subs) {
          shape(lay, s, false);
        }
      case 'rect':
        info.count(tr('formas básicas'));
        final x = len('x', vbW), y = len('y', vbH), rw = len('width', vbW), rh = len('height', vbH);
        if (rw <= 0 || rh <= 0) return;
        var rx = _lenPx(e.getAttribute('rx'), ref: vbW, em: fs), ry = _lenPx(e.getAttribute('ry'), ref: vbH, em: fs);
        if (rx != null && rx < 0) rx = null;
        if (ry != null && ry < 0) ry = null;
        rx ??= ry;
        ry ??= rx;
        final pts = <double>[];
        if (rx == null || ry == null || rx == 0 || ry == 0) {
          for (final p in [(x, y), (x + rw, y), (x + rw, y + rh), (x, y + rh)]) {
            pts
              ..add(tt.x(p.$1, p.$2))
              ..add(tt.y(p.$1, p.$2));
          }
        } else {
          final ex = math.min(rx, rw / 2), ey = math.min(ry, rh / 2);
          void corner(double cx, double cy, double a0) {
            for (var k = 0; k <= 8; k++) {
              final ang = a0 + k * math.pi / 16;
              final px = cx + ex * math.cos(ang), py = cy + ey * math.sin(ang);
              pts
                ..add(tt.x(px, py))
                ..add(tt.y(px, py));
            }
          }

          corner(x + rw - ex, y + ey, -math.pi / 2);
          corner(x + rw - ex, y + rh - ey, 0);
          corner(x + ex, y + rh - ey, math.pi / 2);
          corner(x + ex, y + ey, math.pi);
        }
        shape(layerFor(), pts, true);
      case 'circle' || 'ellipse':
        info.count(tr('formas básicas'));
        final cx = len('cx', vbW), cy = len('cy', vbH);
        var rx = local == 'circle' ? len('r', math.sqrt((vbW * vbW + vbH * vbH) / 2)) : len('rx', vbW);
        var ry = local == 'circle' ? rx : len('ry', vbH);
        if (local == 'ellipse') {
          if (e.getAttribute('rx') == null) rx = ry;
          if (e.getAttribute('ry') == null) ry = rx;
        }
        if (rx <= 0 || ry <= 0) return;
        final n = ((2 * math.pi * math.max(rx, ry) * tt.scale) / (tol * 30)).ceil().clamp(16, 360);
        final pts = <double>[];
        for (var k = 0; k < n; k++) {
          final ang = 2 * math.pi * k / n;
          final px = cx + rx * math.cos(ang), py = cy + ry * math.sin(ang);
          pts
            ..add(tt.x(px, py))
            ..add(tt.y(px, py));
        }
        shape(layerFor(), pts, true);
      case 'line':
        info.count(tr('formas básicas'));
        final x1 = len('x1', vbW), y1 = len('y1', vbH), x2 = len('x2', vbW), y2 = len('y2', vbH);
        shape(layerFor(), [tt.x(x1, y1), tt.y(x1, y1), tt.x(x2, y2), tt.y(x2, y2)], false);
      case 'polyline' || 'polygon':
        info.count(tr('formas básicas'));
        final v = <double>[];
        for (final s in (e.getAttribute('points') ?? '').trim().split(RegExp(r'[\s,]+'))) {
          if (s.isEmpty) continue;
          final n = double.tryParse(s);
          if (n == null || !n.isFinite) break;
          v.add(n);
        }
        final pts = <double>[];
        for (var k = 0; k + 1 < v.length; k += 2) {
          pts
            ..add(tt.x(v[k], v[k + 1]))
            ..add(tt.y(v[k], v[k + 1]));
        }
        shape(layerFor(), pts, local == 'polygon');
      case 'text':
        if (hidden) return;
        final content = e.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (content.isEmpty) return;
        double first(String n) {
          final s = e.getAttribute(n)?.trim().split(RegExp(r'[\s,]+')).first;
          return _lenPx(s, ref: n == 'x' ? vbW : vbH, em: fs) ?? 0;
        }

        final x = first('x'), y = first('y');
        info.count(tr('textos'));
        texts.add(
          DrawingText(
            tt.x(x, y),
            -tt.y(x, y),
            fs * tt.scale,
            -math.atan2(tt.b, tt.a) * 180 / math.pi,
            content,
          ),
        );
      case 'image':
        info.count(tr('imágenes'));
    }
    } finally {
      if (pushedClip) clipStack.removeLast();
    }
  }

  emit(root, base, null, const _Paint(), 0);
  if (perLayer.isEmpty && texts.isEmpty) {
    throw FormatException(tr('El SVG no contiene trazados que se puedan dibujar'));
  }
  if (perLayer.isEmpty) {
    info.warn(tr('Solo hay texto: no hay ninguna línea que cortar.'));
  }

  final c = info.counts;
  final nText = c[tr('textos')] ?? 0, nImg = c[tr('imágenes')] ?? 0, nDash = c[tr('trazos discontinuos')] ?? 0;
  final nBad = c[tr('trazados con datos erróneos')] ?? 0;
  if (nText > 0) {
    info.warn(nText == 1
        ? tr('{n} texto sin convertir a trazados: una cortadora no los verá. En Inkscape: Trazado ▸ Objeto a trazado.', {'n': nText})
        : tr('{n} textos sin convertir a trazados: una cortadora no los verá. En Inkscape: Trazado ▸ Objeto a trazado.', {'n': nText}));
  }
  if (nImg > 0) {
    info.warn(nImg == 1
        ? tr('{n} imagen incrustada: no se dibujan (no son vectores).', {'n': nImg})
        : tr('{n} imágenes incrustadas: no se dibujan (no son vectores).', {'n': nImg}));
  }
  if ((c[tr('recortes (clip-path)')] ?? 0) + (c[tr('máscaras')] ?? 0) > 0) {
    info.warn(tr('Hay recortes o máscaras: se dibuja la geometría completa, sin recortar.'));
  }
  if (nDash > 0) {
    info.warn(tr('{n} trazos discontinuos se dibujan continuos (suelen ser líneas de plegado o de guía).', {'n': nDash}));
  }
  if ((c[tr('degradados o patrones')] ?? 0) > 0) {
    info.warn(tr('Degradados y patrones se dibujan con un color liso.'));
  }
  if (nBad > 0) {
    info.warn(tr('{n} trazados tienen datos erróneos: se dibujan hasta el error.', {'n': nBad}));
  }
  if ((c[tr('referencias externas')] ?? 0) > 0) {
    info.warn(tr('Hay referencias a otros archivos que no se cargan.'));
  }
  return _pack(name, perLayer, texts, info, insUnits);
}

DxfData _pack(String name, Map<String, List<double>> perLayer, List<DrawingText> texts, VectorInfo info, int insUnits) {
  final names = perLayer.keys.toList();
  final total = perLayer.values.fold<int>(0, (a, l) => a + l.length);
  final verts = Float32List(total);
  final groups = <(String, int, int)>[];
  var off = 0;
  final mn = [double.infinity, double.infinity, 0.0], mx = [-double.infinity, -double.infinity, 0.0];
  for (final n in names) {
    final l = perLayer[n]!;
    verts.setAll(off, l);
    groups.add((n, off ~/ 6, l.length ~/ 6));
    off += l.length;
    // Los viajes en vacío (pluma arriba) no cuentan para el tamaño del dibujo.
    if (isTravelLayerName(n) && names.length > 1) continue;
    for (var k = 0; k < l.length; k += 6) {
      if (l[k] < mn[0]) mn[0] = l[k];
      if (l[k] > mx[0]) mx[0] = l[k];
      if (l[k + 1] < mn[1]) mn[1] = l[k + 1];
      if (l[k + 1] > mx[1]) mx[1] = l[k + 1];
    }
  }
  if (names.isEmpty) {
    mn[0] = mn[1] = 0;
    mx[0] = mx[1] = 1;
    for (final t in texts) {
      mn[0] = math.min(mn[0], t.x);
      mn[1] = math.min(mn[1], t.y);
      mx[0] = math.max(mx[0], t.x + t.height);
      mx[1] = math.max(mx[1], t.y + t.height);
    }
  }
  return DxfData(name, verts, groups, mn, mx, texts, insUnits)..info = info;
}

Future<DxfData> loadSvg(String path) => isoRun(() => parseSvg(path));

/// Une las capas ya calculadas de un HPGL en un `DxfData`.
DxfData packVector(String name, Map<String, List<double>> perLayer, List<DrawingText> texts, VectorInfo info, int insUnits) =>
    _pack(name, perLayer, texts, info, insUnits);
