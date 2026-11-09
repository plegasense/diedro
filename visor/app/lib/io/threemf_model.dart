// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:convert';
import 'dart:typed_data';

/// Componente de un objeto compuesto: otro objeto (en este u otro archivo) con su transformación.
class RawComp {
  RawComp(this.objectId, this.path, this.m);
  final String objectId;
  final String? path;
  final List<double> m; // 4x4 column-major
}

/// Objeto de un `.model`: una malla, una lista de componentes, o ambas cosas.
class RawObject {
  RawObject(this.id);
  final String id;
  String name = '';
  String type = 'model';
  String? pid;
  int pindex = 0;
  Float32List? pos;
  Uint32List? tri;

  /// Estado de pintura por triángulo (extrusor, 0 = ninguno); 255 = subdividido (ver [complex]).
  Uint8List? paint;
  Map<int, String>? complex;

  /// Propiedad de color por triángulo (`pid`/`p1`) cuando el archivo las trae.
  Int32List? triPid, triP1, triP2, triP3;
  final comps = <RawComp>[];
  bool hasLattice = false, hasSlices = false;

  /// Vigas de la retícula: v1, v2, r1, r2 por viga (los radios ya resueltos).
  Float32List? beams;
}

class RawItem {
  RawItem(this.objectId, this.m, this.printable, this.partNumber, this.path);
  final String objectId;
  final String? path; // objeto en otro archivo (extensión de producción)
  final List<double> m;
  final bool printable;
  final String? partNumber;
}

/// Contenido de un archivo `.model` de un 3MF.
class RawModel {
  String unit = 'millimeter';
  String requiredExtensions = '';
  final metadata = <String, String>{};
  final objects = <String, RawObject>{};
  final items = <RawItem>[];

  /// Recurso de color: id -> colores ARGB (basematerials, colorgroup).
  final colors = <String, List<int>>{};
  final colorNames = <String, List<String>>{};
  final textured = <String>{};
  bool hasComposite = false;
}

final List<double> kIdentity4 = <double>[
  1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, //
];

/// Transformación de 3MF (12 números, vector fila) a 4x4 column-major.
List<double> matrix3mf(String? t) {
  if (t == null) return kIdentity4;
  final s = t.trim();
  if (s.isEmpty) return kIdentity4;
  final v = <double>[];
  for (final p in s.split(RegExp(r'\s+'))) {
    final d = double.tryParse(p);
    if (d == null) return kIdentity4;
    v.add(d);
  }
  if (v.length != 12) return kIdentity4;
  return [
    v[0], v[1], v[2], 0, //
    v[3], v[4], v[5], 0,
    v[6], v[7], v[8], 0,
    v[9], v[10], v[11], 1,
  ];
}

List<double> mul4(List<double> a, List<double> b) {
  final r = List<double>.filled(16, 0);
  for (var c = 0; c < 4; c++) {
    for (var rr = 0; rr < 4; rr++) {
      var s = 0.0;
      for (var k = 0; k < 4; k++) {
        s += a[k * 4 + rr] * b[c * 4 + k];
      }
      r[c * 4 + rr] = s;
    }
  }
  return r;
}

class _F32 {
  Float32List a = Float32List(1024);
  int n = 0;
  void add3(double x, double y, double z) {
    if (n + 3 > a.length) {
      final b = Float32List(a.length * 2);
      b.setRange(0, n, a);
      a = b;
    }
    a[n++] = x;
    a[n++] = y;
    a[n++] = z;
  }

  Float32List take() => Float32List.sublistView(a, 0, n);
}

class _U32 {
  Uint32List a = Uint32List(1024);
  int n = 0;
  void add3(int x, int y, int z) {
    if (n + 3 > a.length) {
      final b = Uint32List(a.length * 2);
      b.setRange(0, n, a);
      a = b;
    }
    a[n++] = x;
    a[n++] = y;
    a[n++] = z;
  }

  Uint32List take() => Uint32List.sublistView(a, 0, n);
}

class _U8 {
  Uint8List a = Uint8List(1024);
  int n = 0;
  void add(int v) {
    if (n >= a.length) {
      final b = Uint8List(a.length * 2);
      b.setRange(0, n, a);
      a = b;
    }
    a[n++] = v;
  }

  Uint8List take() => Uint8List.sublistView(a, 0, n);
}

class _I32 {
  Int32List a = Int32List(1024);
  int n = 0;
  void add(int v) {
    if (n >= a.length) {
      final b = Int32List(a.length * 2);
      b.setRange(0, n, a);
      a = b;
    }
    a[n++] = v;
  }

  void fillTo(int len, int v) {
    while (n < len) {
      add(v);
    }
  }

  Int32List take() => Int32List.sublistView(a, 0, n);
}

/// Estado de pintura de un `paint_color` / `mmu_segmentation`: extrusor si es una hoja
/// simple, -1 si el triángulo está subdividido (hay que decodificarlo con [decodePaint]).
int paintSimple(String s) {
  if (s.isEmpty) return 0;
  final n = s.length;
  int hex(int c) =>
      c >= 48 && c <= 57 ? c - 48 : (c | 32) >= 97 && (c | 32) <= 102 ? (c | 32) - 87 : 0;
  if (n == 1) {
    final c = hex(s.codeUnitAt(0));
    return (c & 3) == 0 && (c & 12) != 12 ? c >> 2 : -1;
  }
  if (n == 2) {
    final c = hex(s.codeUnitAt(1));
    if ((c & 3) == 0 && (c & 12) == 12) {
      final d = hex(s.codeUnitAt(0));
      if (d != 15) return d + 3;
    }
  }
  return -1;
}

/// Lector por trozos de un `.model`: no necesita el XML entero en memoria.
class ModelParser {
  ModelParser() {
    model = RawModel();
  }
  late final RawModel model;

  Uint8List _carry = Uint8List(0);
  RawObject? _obj;
  _F32? _vx;
  _U32? _tr;
  _U8? _pa;
  _I32? _tp, _t1, _t2, _t3;
  Map<int, String>? _cx;
  _F32? _bm; // vigas: 4 números por viga
  double _latticeR = 1;
  bool _inMesh = false;
  String? _res; // recurso de color abierto
  String _resKind = '';

  void feed(Uint8List chunk) {
    Uint8List b;
    if (_carry.isEmpty) {
      b = chunk;
    } else {
      b = Uint8List(_carry.length + chunk.length)
        ..setRange(0, _carry.length, _carry)
        ..setRange(_carry.length, _carry.length + chunk.length, chunk);
    }
    final n = b.length;
    var i = 0;
    while (true) {
      // buscar '<'
      while (i < n && b[i] != 0x3C) {
        i++;
      }
      if (i >= n) {
        _carry = Uint8List(0);
        return;
      }
      // buscar '>' (respetando comillas)
      var j = i + 1;
      int q = 0;
      while (j < n) {
        final c = b[j];
        if (q != 0) {
          if (c == q) q = 0;
        } else if (c == 0x22 || c == 0x27) {
          q = c;
        } else if (c == 0x3E) {
          break;
        }
        j++;
      }
      if (j >= n) {
        _carry = Uint8List.sublistView(b, i);
        _carry = Uint8List.fromList(_carry);
        return;
      }
      // <metadata name="..">texto</metadata>: necesita el cierre
      if (_startsWith(b, i + 1, 'metadata') &&
          b[i + 9] == 0x20 &&
          b[j - 1] != 0x2F) {
        var k = j + 1;
        while (k < n && b[k] != 0x3C) {
          k++;
        }
        if (k >= n) {
          _carry = Uint8List.fromList(Uint8List.sublistView(b, i));
          return;
        }
        final name = _attrStr(b, i, j, 'name');
        if (name != null && k - (j + 1) < 4096) {
          model.metadata[name] = _unesc(
            utf8.decode(Uint8List.sublistView(b, j + 1, k), allowMalformed: true),
          );
        }
        i = k;
        continue;
      }
      _tag(b, i, j);
      i = j + 1;
    }
  }

  void finish() {
    _carry = Uint8List(0);
    _closeObject();
  }

  static bool _startsWith(Uint8List b, int p, String s) {
    if (p + s.length > b.length) return false;
    for (var k = 0; k < s.length; k++) {
      if (b[p + k] != s.codeUnitAt(k)) return false;
    }
    return true;
  }

  static bool _isNameEnd(int c) => c == 0x20 || c == 0x2F || c == 0x3E || c == 0x09 || c == 0x0A || c == 0x0D;

  void _tag(Uint8List b, int s, int e) {
    // s apunta a '<', e a '>'
    var p = s + 1;
    if (p >= e) return;
    final c0 = b[p];
    if (c0 == 0x21 || c0 == 0x3F) return; // <!-- <?
    final closing = c0 == 0x2F;
    if (closing) p++;
    // nombre sin prefijo
    var ns = p;
    var q = p;
    while (q < e && !_isNameEnd(b[q])) {
      if (b[q] == 0x3A) ns = q + 1;
      q++;
    }
    final nlen = q - ns;
    bool is_(String t) => nlen == t.length && _startsWith(b, ns, t);

    if (closing) {
      if (is_('object')) {
        _closeObject();
      } else if (is_('mesh')) {
        _inMesh = false;
      } else if (is_('basematerials') || is_('colorgroup') || is_('texture2dgroup')) {
        _res = null;
      }
      return;
    }
    if (_inMesh) {
      if (is_('vertex')) {
        _vertex(b, q, e);
        return;
      }
      if (is_('triangle')) {
        _triangle(b, q, e);
        return;
      }
    }
    if (is_('component')) {
      final o = _obj;
      if (o == null) return;
      final id = _attrStr(b, q, e, 'objectid');
      if (id == null) return;
      o.comps.add(
        RawComp(id, _attrStr(b, q, e, 'path'), matrix3mf(_attrStr(b, q, e, 'transform'))),
      );
    } else if (is_('object')) {
      _closeObject();
      final id = _attrStr(b, q, e, 'id');
      if (id == null) return;
      final o = RawObject(id)
        ..name = _unesc(_attrStr(b, q, e, 'name') ?? '')
        ..type = _attrStr(b, q, e, 'type') ?? 'model'
        ..pid = _attrStr(b, q, e, 'pid')
        ..pindex = int.tryParse(_attrStr(b, q, e, 'pindex') ?? '') ?? 0;
      if (_attrStr(b, q, e, 'slicestackid') != null) o.hasSlices = true;
      _obj = o;
    } else if (is_('mesh')) {
      if (_obj == null) return;
      _inMesh = true;
      _vx = _F32();
      _tr = _U32();
      _pa = _U8();
      _tp = null;
      _t1 = null;
      _t2 = null;
      _t3 = null;
      _cx = null;
      _bm = null;
    } else if (is_('item')) {
      final id = _attrStr(b, q, e, 'objectid');
      if (id != null) {
        model.items.add(
          RawItem(
            id,
            matrix3mf(_attrStr(b, q, e, 'transform')),
            _attrStr(b, q, e, 'printable') != '0',
            _attrStr(b, q, e, 'partnumber'),
            _attrStr(b, q, e, 'path'),
          ),
        );
      }
    } else if (is_('model')) {
      model.unit = _attrStr(b, q, e, 'unit') ?? 'millimeter';
      model.requiredExtensions = _attrStr(b, q, e, 'requiredextensions') ?? '';
    } else if (is_('basematerials')) {
      _res = _attrStr(b, q, e, 'id');
      _resKind = 'base';
      if (_res != null) {
        model.colors[_res!] = [];
        model.colorNames[_res!] = [];
      }
    } else if (is_('colorgroup')) {
      _res = _attrStr(b, q, e, 'id');
      _resKind = 'color';
      if (_res != null) {
        model.colors[_res!] = [];
        model.colorNames[_res!] = [];
      }
    } else if (is_('texture2dgroup')) {
      final id = _attrStr(b, q, e, 'id');
      if (id != null) model.textured.add(id);
    } else if (is_('base') && _res != null && _resKind == 'base') {
      final col = _attrStr(b, q, e, 'displaycolor');
      model.colors[_res!]!.add(_parseColor(col) ?? 0xFFC8CDD0);
      model.colorNames[_res!]!.add(_unesc(_attrStr(b, q, e, 'name') ?? ''));
    } else if (is_('color') && _res != null && _resKind == 'color') {
      model.colors[_res!]!.add(_parseColor(_attrStr(b, q, e, 'color')) ?? 0xFFC8CDD0);
      model.colorNames[_res!]!.add('');
    } else if (is_('compositematerials') || is_('multiproperties')) {
      model.hasComposite = true;
    } else if (is_('beamlattice')) {
      _obj?.hasLattice = true;
      _latticeR = double.tryParse(_attrStr(b, q, e, 'radius') ?? '') ?? 1;
      _bm = _F32();
    } else if (is_('beam') && _bm != null) {
      final v1 = int.tryParse(_attrStr(b, q, e, 'v1') ?? '');
      final v2 = int.tryParse(_attrStr(b, q, e, 'v2') ?? '');
      if (v1 != null && v2 != null) {
        final r1 = double.tryParse(_attrStr(b, q, e, 'r1') ?? '') ?? _latticeR;
        final r2 = double.tryParse(_attrStr(b, q, e, 'r2') ?? '') ?? r1;
        final bm = _bm!;
        bm.add3(v1.toDouble(), v2.toDouble(), r1);
        bm.add3(r2, 0, 0);
      }
    } else if (is_('slicestack')) {
      _obj?.hasSlices = true;
    }
  }

  void _closeObject() {
    final o = _obj;
    if (o == null) return;
    final v = _vx, t = _tr;
    if (v != null && t != null && (t.n > 0 || (_bm?.n ?? 0) > 0)) {
      if (_bm != null && _bm!.n > 0) o.beams = _bm!.take();
      o.pos = v.take();
      o.tri = t.take();
      o.paint = _pa!.take();
      o.complex = _cx;
      if (_t1 != null) {
        final nt = t.n ~/ 3;
        _t1!.fillTo(nt, -1);
        _t2!.fillTo(nt, -1);
        _t3!.fillTo(nt, -1);
        _tp!.fillTo(nt, -1);
        o.triP1 = _t1!.take();
        o.triP2 = _t2!.take();
        o.triP3 = _t3!.take();
        o.triPid = _tp!.take();
      }
    }
    model.objects[o.id] = o;
    _obj = null;
    _inMesh = false;
    _vx = null;
    _tr = null;
    _pa = null;
    _tp = null;
    _t1 = null;
    _t2 = null;
    _t3 = null;
    _cx = null;
    _bm = null;
  }

  // ---- números y atributos (sin crear cadenas en las etiquetas calientes)

  static double _num(Uint8List b, int s, int e) {
    var i = s;
    var neg = false;
    if (i < e && (b[i] == 0x2D || b[i] == 0x2B)) {
      neg = b[i] == 0x2D;
      i++;
    }
    var m = 0.0;
    while (i < e) {
      final d = b[i] - 48;
      if (d < 0 || d > 9) break;
      m = m * 10 + d;
      i++;
    }
    var sc = 0;
    if (i < e && b[i] == 0x2E) {
      i++;
      while (i < e) {
        final d = b[i] - 48;
        if (d < 0 || d > 9) break;
        m = m * 10 + d;
        sc--;
        i++;
      }
    }
    if (i < e && (b[i] == 0x65 || b[i] == 0x45)) {
      i++;
      var en = false;
      if (i < e && (b[i] == 0x2D || b[i] == 0x2B)) {
        en = b[i] == 0x2D;
        i++;
      }
      var x = 0;
      while (i < e) {
        final d = b[i] - 48;
        if (d < 0 || d > 9) break;
        x = x * 10 + d;
        i++;
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

  static int _int(Uint8List b, int s, int e) {
    var v = 0;
    for (var i = s; i < e; i++) {
      final d = b[i] - 48;
      if (d < 0 || d > 9) break;
      v = v * 10 + d;
    }
    return v;
  }

  void _vertex(Uint8List b, int p, int e) {
    var x = 0.0, y = 0.0, z = 0.0;
    var i = p;
    while (i < e) {
      while (i < e && (b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D)) {
        i++;
      }
      final ns = i;
      while (i < e && b[i] != 0x3D && b[i] != 0x2F) {
        i++;
      }
      if (i >= e || b[i] != 0x3D) break;
      final ne = i;
      i++;
      if (i >= e) break;
      final qc = b[i];
      i++;
      final vs = i;
      while (i < e && b[i] != qc) {
        i++;
      }
      final ve = i;
      i++;
      if (ne - ns == 1) {
        final c = b[ns];
        if (c == 0x78) {
          x = _num(b, vs, ve);
        } else if (c == 0x79) {
          y = _num(b, vs, ve);
        } else if (c == 0x7A) {
          z = _num(b, vs, ve);
        }
      }
    }
    _vx!.add3(x, y, z);
  }

  void _triangle(Uint8List b, int p, int e) {
    var v1 = 0, v2 = 0, v3 = 0, pid = -2, p1 = -1, p2 = -1, p3 = -1;
    int ps = -1, pe = -1;
    var i = p;
    while (i < e) {
      while (i < e && (b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D)) {
        i++;
      }
      final ns = i;
      while (i < e && b[i] != 0x3D && b[i] != 0x2F) {
        i++;
      }
      if (i >= e || b[i] != 0x3D) break;
      final ne = i;
      i++;
      if (i >= e) break;
      final qc = b[i];
      i++;
      final vs = i;
      while (i < e && b[i] != qc) {
        i++;
      }
      final ve = i;
      i++;
      final len = ne - ns;
      if (len == 2 && b[ns] == 0x76) {
        final d = b[ns + 1];
        if (d == 0x31) {
          v1 = _int(b, vs, ve);
        } else if (d == 0x32) {
          v2 = _int(b, vs, ve);
        } else if (d == 0x33) {
          v3 = _int(b, vs, ve);
        }
      } else if (len == 2 && b[ns] == 0x70 && b[ns + 1] == 0x31) {
        p1 = _int(b, vs, ve);
      } else if (len == 2 && b[ns] == 0x70 && b[ns + 1] == 0x32) {
        p2 = _int(b, vs, ve);
      } else if (len == 2 && b[ns] == 0x70 && b[ns + 1] == 0x33) {
        p3 = _int(b, vs, ve);
      } else if (len == 3 && b[ns] == 0x70 && b[ns + 1] == 0x69 && b[ns + 2] == 0x64) {
        pid = _int(b, vs, ve);
      } else if (len >= 11 && b[ns + len - 1] == 0x72 && b[ns + len - 2] == 0x6F) {
        // paint_color
        if (_startsWith(b, ns + len - 11, 'paint_color')) {
          ps = vs;
          pe = ve;
        }
      } else if (len >= 16 && _startsWith(b, ns + len - 16, 'mmu_segmentation')) {
        ps = vs;
        pe = ve;
      }
    }
    _tr!.add3(v1, v2, v3);
    final idx = _tr!.n ~/ 3 - 1;
    if (ps >= 0 && pe > ps) {
      final str = String.fromCharCodes(b, ps, pe);
      final s = paintSimple(str);
      if (s >= 0) {
        _pa!.add(s > 254 ? 254 : s);
      } else {
        _pa!.add(255);
        (_cx ??= {})[idx] = str;
      }
    } else {
      _pa!.add(0);
    }
    if (p1 >= 0 || pid >= -1 && pid != -2) {
      if (_t1 == null) {
        _t1 = _I32();
        _t2 = _I32();
        _t3 = _I32();
        _tp = _I32();
      }
      _t1!.fillTo(idx, -1);
      _t2!.fillTo(idx, -1);
      _t3!.fillTo(idx, -1);
      _tp!.fillTo(idx, -1);
      _t1!.add(p1);
      _t2!.add(p2);
      _t3!.add(p3);
      _tp!.add(pid == -2 ? -1 : pid);
    }
  }

  static String? _attrStr(Uint8List b, int s, int e, String name) {
    var i = s;
    final nb = name.codeUnits;
    while (i < e) {
      while (i < e && (b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D)) {
        i++;
      }
      final ns = i;
      while (i < e && b[i] != 0x3D && b[i] != 0x2F && b[i] != 0x20) {
        i++;
      }
      if (i >= e || b[i] != 0x3D) {
        if (i < e && b[i] == 0x20) continue;
        return null;
      }
      var ne = i;
      i++;
      if (i >= e) return null;
      final qc = b[i];
      i++;
      final vs = i;
      while (i < e && b[i] != qc) {
        i++;
      }
      final ve = i;
      i++;
      // nombre sin prefijo
      var k = ne;
      while (k > ns && b[k - 1] != 0x3A) {
        k--;
      }
      if (ne - k == nb.length) {
        var same = true;
        for (var t = 0; t < nb.length; t++) {
          if (b[k + t] != nb[t]) {
            same = false;
            break;
          }
        }
        if (same) return utf8.decode(Uint8List.sublistView(b, vs, ve), allowMalformed: true);
      }
    }
    return null;
  }

  static String _unesc(String s) {
    if (!s.contains('&')) return s;
    return s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
          final v = int.tryParse(m.group(2)!, radix: m.group(1) == 'x' ? 16 : 10);
          return v == null ? '' : String.fromCharCode(v);
        })
        .replaceAll('&amp;', '&');
  }

  static int? _parseColor(String? s) {
    if (s == null) return null;
    var t = s.trim();
    if (t.startsWith('#')) t = t.substring(1);
    if (t.length == 6) {
      final v = int.tryParse(t, radix: 16);
      return v == null ? null : 0xFF000000 | v;
    }
    if (t.length == 8) {
      final v = int.tryParse(t, radix: 16);
      if (v == null) return null;
      // 3MF: #RRGGBBAA
      return ((v & 0xFF) << 24) | (v >> 8);
    }
    return null;
  }
}

/// Decodifica la pintura de un triángulo subdividido (formato de TriangleSelector de
/// PrusaSlicer / Bambu Studio) y entrega los subtriángulos por extrusor.
///
/// El texto se lee de derecha a izquierda, cuatro bits por carácter hexadecimal. Cada
/// triángulo empieza con un código: los dos bits bajos son cuántos lados se parten; si son
/// 0 es una hoja y los dos bits altos son el estado (3 = el estado sigue en el siguiente
/// código, más 3); si no, los dos altos son el lado especial. Los hijos van en orden inverso.
class PaintDecoder {
  PaintDecoder(this.emit);

  /// Recibe vértices (9 números) y el extrusor.
  final void Function(
    double ax,
    double ay,
    double az,
    double bx,
    double by,
    double bz,
    double cx,
    double cy,
    double cz,
    int state,
  )
  emit;

  String _s = '';
  int _pos = 0; // índice del siguiente carácter (de derecha a izquierda)

  int _nibble() {
    if (_pos < 0) throw const FormatException('pintura truncada');
    final c = _s.codeUnitAt(_pos--);
    return c >= 48 && c <= 57 ? c - 48 : ((c | 32) - 87).clamp(0, 15);
  }

  void decode(String s, List<double> a, List<double> b, List<double> c) {
    _s = s;
    _pos = s.length - 1;
    try {
      _tri(a, b, c, 0);
    } on FormatException {
      // dibujo parcial: lo que no se pudo leer queda sin extrusor
    }
  }

  static List<double> _mid(List<double> p, List<double> q) => [
    (p[0] + q[0]) / 2,
    (p[1] + q[1]) / 2,
    (p[2] + q[2]) / 2,
  ];

  void _leaf(List<double> a, List<double> b, List<double> c, int st) =>
      emit(a[0], a[1], a[2], b[0], b[1], b[2], c[0], c[1], c[2], st);

  void _tri(List<double> a, List<double> b, List<double> c, int depth) {
    final code = _nibble();
    final sides = code & 3;
    if (sides == 0) {
      var st = code >> 2;
      if ((code & 12) == 12) {
        var n = _nibble();
        var extra = 0;
        while (n == 15) {
          extra++;
          n = _nibble();
        }
        st = n + 15 * extra + 3;
      }
      _leaf(a, b, c, st);
      return;
    }
    if (depth > 24) throw const FormatException('demasiada subdivisión');
    final special = code >> 2;
    // vértices girados hasta que el lado especial queda primero
    final tv = [a, b, c];
    final v0 = tv[special % 3], v1 = tv[(special + 1) % 3], v2 = tv[(special + 2) % 3];
    final kids = <List<List<double>>>[];
    switch (sides) {
      case 1:
        final m = _mid(v2, v1);
        kids
          ..add([v0, v1, m])
          ..add([m, v2, v0]);
      case 2:
        final m01 = _mid(v1, v0);
        final m20 = _mid(v0, v2);
        kids
          ..add([v0, m01, m20])
          ..add([m01, v1, m20])
          ..add([v1, v2, m20]);
      default:
        final m01 = _mid(v1, v0);
        final m12 = _mid(v2, v1);
        final m20 = _mid(v0, v2);
        kids
          ..add([v0, m01, m20])
          ..add([m01, v1, m12])
          ..add([m12, v2, m20])
          ..add([m01, m12, m20]);
    }
    for (var k = kids.length - 1; k >= 0; k--) {
      _tri(kids[k][0], kids[k][1], kids[k][2], depth + 1);
    }
  }
}
