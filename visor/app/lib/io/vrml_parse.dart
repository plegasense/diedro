import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../l10n/l10n.dart';

/// Análisis sintáctico de VRML 1.0 / 2.0 (97) y de la codificación clásica de X3D: todos comparten
/// la misma gramática de nodos con campos, `DEF`/`USE`, `PROTO` y `ROUTE`.

class VNode {
  VNode(this.type, this.def);
  final String type;
  final String? def;
  final fields = <String, Object>{};

  /// Nodos hijos sin nombre de campo (VRML 1.0: `Separator { Material {…} … }`).
  final kids = <Object>[];

  /// Procede de una instancia de PROTO.
  bool fromProto = false;
}

class VUse {
  VUse(this.name);
  final String name;
}

class VNull {
  const VNull();
}

/// Valor de un campo del PROTO en el cuerpo (`campo IS nombre`).
class VIsRef {
  VIsRef(this.name);
  final String name;
}

class VProto {
  VProto(this.name, this.external);
  final String name;
  final bool external;
  final fields = <(String, Object?)>[];
  final body = <Object>[];
}

class VrmlDoc {
  final top = <Object>[];
  final defs = <String, VNode>{};
  final protos = <String, VProto>{};

  /// Instancias de PROTO externos que no se pueden resolver.
  final externProtoUses = <String, int>{};

  /// `ROUTE a.b TO c.d`: (nodo origen, evento origen, nodo destino, campo destino).
  final routes = <(String, String, String, String)>[];
  int nodeCount = 0;
}

/// Quita comillas y secuencias de escape de una cadena VRML.
String vrmlUnquote(String s) {
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    return s.substring(1, s.length - 1).replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
  }
  return s;
}

/// Lee los bytes de un archivo VRML (admite gzip: `.wrz`) y los pasa a texto.
String readVrmlText(String path) {
  var bytes = File(path).readAsBytesSync();
  if (bytes.length > (300 << 20)) throw FormatException(tr('El archivo VRML es demasiado grande'));
  if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    try {
      bytes = Uint8List.fromList(gzip.decode(bytes));
    } catch (_) {
      throw FormatException(tr('El VRML comprimido (.wrz) está dañado'));
    }
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// Lista de fichas (palabras, números, cadenas y signos) como posiciones del texto: no se crea un
/// `String` por ficha, que en archivos de decenas de megas es lo que más tarda.
class VTokens {
  VTokens(this.src) {
    _scan();
  }
  final String src;
  Int32List _s = Int32List(1 << 16);
  Int32List _e = Int32List(1 << 16);
  int length = 0;

  void _add(int s, int e) {
    if (length == _s.length) {
      final ns = Int32List(length * 2)..setAll(0, _s);
      final ne = Int32List(length * 2)..setAll(0, _e);
      _s = ns;
      _e = ne;
    }
    _s[length] = s;
    _e[length] = e;
    length++;
  }

  void _scan() {
    final n = src.length;
    var k = 0;
    while (k < n) {
      final c = src.codeUnitAt(k);
      if (c == 32 || c == 44 || c == 9 || c == 10 || c == 13 || c == 0xFEFF || c == 0) {
        k++;
        continue;
      }
      if (c == 35 /* # */) {
        while (k < n && src.codeUnitAt(k) != 10 && src.codeUnitAt(k) != 13) {
          k++;
        }
        continue;
      }
      if (c == 123 || c == 125 || c == 91 || c == 93) {
        _add(k, k + 1);
        k++;
        continue;
      }
      if (c == 34 /* " */) {
        final s = k++;
        while (k < n && src.codeUnitAt(k) != 34) {
          if (src.codeUnitAt(k) == 92) k++;
          k++;
        }
        _add(s, k + 1 > n ? n : k + 1);
        k++;
        continue;
      }
      final s = k;
      while (k < n) {
        final d = src.codeUnitAt(k);
        if (d == 32 || d == 44 || d == 9 || d == 10 || d == 13 || d == 123 || d == 125 || d == 91 || d == 93 || d == 35 || d == 34) break;
        k++;
      }
      _add(s, k);
    }
  }

  String operator [](int i) => src.substring(_s[i], _e[i]);

  int first(int i) => src.codeUnitAt(_s[i]);
  int len(int i) => _e[i] - _s[i];

  /// ¿La ficha [i] es exactamente [w]?
  bool eq(int i, String w) {
    final s = _s[i];
    if (_e[i] - s != w.length) return false;
    for (var k = 0; k < w.length; k++) {
      if (src.codeUnitAt(s + k) != w.codeUnitAt(k)) return false;
    }
    return true;
  }

  bool isOpen(int i) => len(i) == 1 && first(i) == 123;
  bool isClose(int i) => len(i) == 1 && first(i) == 125;
  bool isLBracket(int i) => len(i) == 1 && first(i) == 91;
  bool isRBracket(int i) => len(i) == 1 && first(i) == 93;
  bool isString(int i) => first(i) == 34;

  /// Valor numérico de la ficha [i], o null si no es un número.
  double? num(int i) {
    var p = _s[i];
    final e = _e[i];
    var c = src.codeUnitAt(p);
    // descarte rápido: un número empieza por dígito, signo o punto
    if (!((c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46)) return null;
    var neg = false;
    if (c == 45 || c == 43) {
      neg = c == 45;
      p++;
      if (p >= e) return null;
      c = src.codeUnitAt(p);
    }
    var mant = 0;
    var digits = 0, scale = 0;
    var seenDot = false;
    while (p < e) {
      c = src.codeUnitAt(p);
      if (c >= 48 && c <= 57) {
        if (digits < 18) {
          mant = mant * 10 + (c - 48);
          digits++;
          if (seenDot) scale++;
        } else if (!seenDot) {
          scale--; // dígitos de más: se pierden pero la magnitud se conserva
        }
        p++;
      } else if (c == 46 && !seenDot) {
        seenDot = true;
        p++;
      } else {
        break;
      }
    }
    if (digits == 0) return _slow(i);
    var exp = 0;
    if (p < e) {
      if (c == 101 || c == 69) {
        p++;
        var eneg = false;
        if (p < e && (src.codeUnitAt(p) == 45 || src.codeUnitAt(p) == 43)) {
          eneg = src.codeUnitAt(p) == 45;
          p++;
        }
        var ed = 0;
        while (p < e) {
          final d = src.codeUnitAt(p);
          if (d < 48 || d > 57) return _slow(i);
          exp = exp * 10 + (d - 48);
          ed++;
          p++;
          if (ed > 5) return _slow(i);
        }
        if (ed == 0) return _slow(i);
        if (eneg) exp = -exp;
      } else {
        return _slow(i);
      }
    }
    final e10 = exp - scale;
    double v = mant.toDouble();
    if (e10 != 0) {
      if (e10 > 22 || e10 < -22) return _slow(i);
      v = e10 > 0 ? v * _pow10[e10] : v / _pow10[-e10];
    }
    return neg ? -v : v;
  }

  double? _slow(int i) => vrmlNum(this[i]);

  static const _pow10 = [
    1.0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
  ];
}

/// Lista de números con crecimiento sobre un `Float64List` (sin un objeto por número).
class _NumBuf {
  Float64List a = Float64List(64);
  int n = 0;
  void add(double v) {
    if (n == a.length) {
      final b = Float64List(n * 2)..setAll(0, a);
      a = b;
    }
    a[n++] = v;
  }

  List<double> take() => Float64List.sublistView(a, 0, n);
}

double? vrmlNum(String s) {
  final d = double.tryParse(s);
  if (d != null) return d;
  if (s.startsWith('0x') || s.startsWith('0X')) return int.tryParse(s.substring(2), radix: 16)?.toDouble();
  return null;
}

class VrmlParser {
  VrmlParser(this.t, this.doc);
  final VTokens t;
  final VrmlDoc doc;
  int i = 0;
  int _depth = 0;
  int _protoExpansions = 0;
  static const int maxNodes = 4000000;

  bool get _more => i < t.length;

  /// Lee `ROUTE a.b TO c.d` (la ficha actual es ROUTE) y avanza.
  void _route() {
    if (i + 3 < t.length && t.eq(i + 2, 'TO')) {
      final a = t[i + 1], b = t[i + 3];
      final da = a.lastIndexOf('.'), db = b.lastIndexOf('.');
      if (da > 0 && db > 0) doc.routes.add((a.substring(0, da), a.substring(da + 1), b.substring(0, db), b.substring(db + 1)));
      i += 4;
    } else {
      i = (i + 4 <= t.length) ? i + 4 : t.length;
    }
  }

  bool _isNodeStart() {
    if (!_more) return false;
    if (t.eq(i, 'DEF') || t.eq(i, 'USE')) return true;
    return i + 1 < t.length && t.isOpen(i + 1) && !t.isOpen(i) && !t.isLBracket(i);
  }

  Object _value() {
    if (t.isLBracket(i)) {
      i++;
      final nums = _NumBuf();
      final strs = <String>[];
      final nodes = <Object>[];
      while (_more && !t.isRBracket(i)) {
        final n = t.num(i);
        if (n != null) {
          nums.add(n);
          i++;
        } else if (t.isString(i)) {
          strs.add(vrmlUnquote(t[i]));
          i++;
        } else if (t.eq(i, 'ROUTE')) {
          _route();
        } else if (t.isOpen(i) || t.isClose(i) || t.isLBracket(i)) {
          throw FormatException(tr('Estructura del VRML no válida (llave o corchete inesperado)'));
        } else if (_isNodeStart()) {
          nodes.add(_node());
        } else {
          strs.add(t[i]);
          i++;
        }
      }
      i++;
      if (nodes.isNotEmpty) return nodes;
      if (strs.isNotEmpty) return strs;
      return nums.take();
    }
    final n0 = t.num(i);
    if (n0 != null) {
      final nums = _NumBuf()..add(n0);
      i++;
      while (_more) {
        final v = t.num(i);
        if (v == null) break;
        nums.add(v);
        i++;
      }
      return nums.take();
    }
    if (t.isString(i)) {
      return vrmlUnquote(t[i++]);
    }
    if (t.eq(i, 'TRUE') || t.eq(i, 'true')) {
      i++;
      return true;
    }
    if (t.eq(i, 'FALSE') || t.eq(i, 'false')) {
      i++;
      return false;
    }
    if (t.eq(i, 'NULL')) {
      i++;
      return const VNull();
    }
    if (_isNodeStart()) return _node();
    return t[i++];
  }

  Object _node() {
    if (++_depth > 300) throw FormatException(tr('VRML con anidamiento excesivo'));
    try {
      var tok = t[i++];
      if (tok == 'USE') {
        if (!_more) throw FormatException(tr('USE sin nombre'));
        return VUse(t[i++]);
      }
      String? def;
      if (tok == 'DEF') {
        if (i + 1 >= t.length) throw FormatException(tr('DEF sin nodo'));
        def = t[i++];
        tok = t[i++];
        if (tok == 'USE' && _more) return VUse(t[i++]);
      }
      if (++doc.nodeCount > maxNodes) throw FormatException(tr('El VRML tiene demasiados nodos'));
      final node = VNode(tok, def);
      if (_more && t.isOpen(i)) {
        i++;
        if (tok == 'Script' || tok == 'ComposedShader' || tok == 'ShaderPart' || tok == 'PackagedShader') {
          _skipBlock();
        } else {
          _body(node);
        }
        if (_more && t.isClose(i)) i++;
      }
      if (def != null) doc.defs[def] = node;
      final proto = doc.protos[tok];
      if (proto != null) return _instantiate(proto, node);
      return node;
    } finally {
      _depth--;
    }
  }

  void _skipBlock() {
    var depth = 1;
    while (_more && depth > 0) {
      if (t.isOpen(i)) depth++;
      if (t.isClose(i)) depth--;
      i++;
    }
    if (depth == 0) i--; // el cierre lo consume quien llama
  }

  void _body(VNode node) {
    while (_more && !t.isClose(i)) {
      if (t.eq(i, 'ROUTE')) {
        _route();
      } else if (t.eq(i, 'PROTO') || t.eq(i, 'EXTERNPROTO')) {
        _protoDef();
      } else if (t.eq(i, 'IS') || t.isLBracket(i) || t.isRBracket(i) || t.isOpen(i)) {
        throw FormatException(tr('Estructura del VRML no válida'));
      } else if (_isNodeStart()) {
        node.kids.add(_node());
      } else {
        final tok = t[i++];
        if (!_more || t.isClose(i)) break;
        if (t.eq(i, 'IS')) {
          i++;
          if (_more) node.fields[tok] = VIsRef(t[i++]);
        } else {
          node.fields[tok] = _value();
        }
      }
    }
  }

  void _protoDef() {
    final external = t[i++] == 'EXTERNPROTO';
    if (!_more) return;
    final proto = VProto(t[i++], external);
    if (_more && t.isLBracket(i)) {
      i++;
      while (_more && !t.isRBracket(i)) {
        final kind = t[i++];
        if (!_more || t.isRBracket(i)) break;
        final type = t[i++];
        if (!_more) break;
        final name = t[i++];
        Object? def;
        if (!external && (kind == 'field' || kind == 'exposedField' || kind == 'initializeOnly' || kind == 'inputOutput')) {
          if (type == 'SFNode' || type == 'MFNode') {
            def = _more && !t.isRBracket(i) ? _value() : null;
          } else if (_more) {
            def = _value();
          }
        }
        if (kind == 'field' || kind == 'exposedField' || kind == 'initializeOnly' || kind == 'inputOutput') {
          proto.fields.add((name, def));
        }
      }
      i++;
    }
    if (external) {
      if (_more) _value(); // url
      doc.protos[proto.name] = proto;
      return;
    }
    if (_more && t.isOpen(i)) {
      i++;
      while (_more && !t.isClose(i)) {
        if (t.eq(i, 'ROUTE')) {
          _route();
        } else if (t.eq(i, 'PROTO') || t.eq(i, 'EXTERNPROTO')) {
          _protoDef();
        } else if (_isNodeStart()) {
          proto.body.add(_node());
        } else {
          i++;
        }
      }
      i++;
    }
    doc.protos[proto.name] = proto;
  }

  Object _instantiate(VProto p, VNode inst) {
    if (p.external) {
      doc.externProtoUses[p.name] = (doc.externProtoUses[p.name] ?? 0) + 1;
      return VNode('Group', null)..fromProto = true;
    }
    if (++_protoExpansions > 50000) throw FormatException(tr('Demasiadas instancias de PROTO'));
    final args = <String, Object?>{for (final f in p.fields) f.$1: f.$2};
    for (final e in inst.fields.entries) {
      args[e.key] = e.value;
    }
    final g = VNode('Group', inst.def)..fromProto = true;
    for (final b in p.body) {
      final c = _clone(b, args, 0);
      if (c != null) g.kids.add(c);
    }
    return g;
  }

  Object? _clone(Object o, Map<String, Object?> args, int depth) {
    if (depth > 200) return null;
    if (o is VUse) return o;
    if (o is! VNode) return o;
    final n = VNode(o.type, null)..fromProto = o.fromProto;
    for (final e in o.fields.entries) {
      final v = e.value;
      if (v is VIsRef) {
        final a = args[v.name];
        if (a != null) n.fields[e.key] = a;
      } else {
        n.fields[e.key] = _cloneValue(v, args, depth);
      }
    }
    for (final k in o.kids) {
      final c = _clone(k, args, depth + 1);
      if (c != null) n.kids.add(c);
    }
    return n;
  }

  Object _cloneValue(Object v, Map<String, Object?> args, int depth) {
    if (v is VNode) return _clone(v, args, depth + 1) ?? const VNull();
    if (v is List<Object>) return [for (final e in v) _clone(e, args, depth + 1) ?? const VNull()];
    return v;
  }

  void parseTop() {
    while (_more) {
      if (t.eq(i, 'ROUTE')) {
        _route();
      } else if (t.eq(i, 'PROTO') || t.eq(i, 'EXTERNPROTO')) {
        _protoDef();
      } else if (t.eq(i, 'PROFILE') || t.eq(i, 'COMPONENT')) {
        i = (i + 2 <= t.length) ? i + 2 : t.length;
      } else if (t.eq(i, 'META') || t.eq(i, 'UNIT') || t.eq(i, 'IMPORT') || t.eq(i, 'EXPORT')) {
        i = (i + 3 <= t.length) ? i + 3 : t.length;
      } else if (_isNodeStart()) {
        doc.top.add(_node());
      } else {
        i++;
      }
    }
  }
}
