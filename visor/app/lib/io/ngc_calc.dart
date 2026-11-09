// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:math' as math;
import 'dart:typed_data';

/// Parámetros (`#1`, `#<nombre>`) y expresiones (`[#1 + 2 * sin[30]]`) de RS274/NGC
/// (LinuxCNC) y de las macros de uso común en programas CNC.
class NgcCalc {
  final Map<String, double> params = {};

  static String key(String raw) {
    final t = raw.replaceAll(' ', '').toLowerCase();
    if (t.startsWith('<')) return t;
    final n = double.tryParse(t);
    return n == null ? t : n.round().toString();
  }

  double get(String k) => params[key(k)] ?? 0;
  void set(String k, double v) => params[key(k)] = v;

  /// Lee un valor en [k]: `[expresión]` o `#ref`. Devuelve (valor, siguiente posición).
  (double, int) valueAt(Uint8List b, int k, int end) {
    final s = String.fromCharCodes(b, k, end);
    final p = _P(s, this);
    final v = p.primary();
    return (v, k + p.i);
  }

  /// Evalúa una expresión completa (sin corchetes exteriores).
  double eval(String s) => _P(s, this).expr();

  /// Si la línea empieza por `#ref = expr` (puede haber varias), las ejecuta y devuelve true.
  bool tryAssign(Uint8List b, int start, int end) {
    var k = start;
    var any = false;
    while (k < end) {
      while (k < end && (b[k] == 32 || b[k] == 9)) {
        k++;
      }
      if (k >= end || b[k] != 0x23) break;
      final s = String.fromCharCodes(b, k, end);
      final p = _P(s, this);
      final name = p.refName();
      p.ws();
      if (p.i >= s.length || s[p.i] != '=') return any;
      p.i++;
      final v = p.expr();
      set(name, v);
      k += p.i;
      any = true;
      // comentario entre paréntesis o ; al final
      while (k < end && (b[k] == 32 || b[k] == 9)) {
        k++;
      }
      if (k < end && b[k] == 0x28) {
        while (k < end && b[k] != 0x29) {
          k++;
        }
        k++;
      }
    }
    return any;
  }
}

class _P {
  _P(this.s, this.c);
  final String s;
  final NgcCalc c;
  int i = 0;

  void ws() {
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) {
      i++;
    }
  }

  bool _word(String w) {
    ws();
    if (s.length - i >= w.length &&
        s.substring(i, i + w.length).toLowerCase() == w) {
      final after = i + w.length;
      if (after >= s.length ||
          !RegExp(r'[a-zA-Z]').hasMatch(s[after]) ||
          w.length == 0) {
        i = after;
        return true;
      }
    }
    return false;
  }

  /// Expresión hasta fin de la parte numérica (para asignaciones sin corchetes).
  double expr1() {
    ws();
    return primaryOrSigned();
  }

  double primaryOrSigned() {
    ws();
    var sign = 1.0;
    if (i < s.length && (s[i] == '-' || s[i] == '+')) {
      if (s[i] == '-') sign = -1;
      i++;
      ws();
    }
    return sign * primary();
  }

  double expr() => _cmp();

  double _cmp() {
    var a = _add();
    while (true) {
      ws();
      if (_word('eq')) {
        a = a == _add() ? 1 : 0;
      } else if (_word('ne')) {
        a = a != _add() ? 1 : 0;
      } else if (_word('ge')) {
        a = a >= _add() ? 1 : 0;
      } else if (_word('gt')) {
        a = a > _add() ? 1 : 0;
      } else if (_word('le')) {
        a = a <= _add() ? 1 : 0;
      } else if (_word('lt')) {
        a = a < _add() ? 1 : 0;
      } else {
        return a;
      }
    }
  }

  double _add() {
    var a = _mul();
    while (true) {
      ws();
      if (i < s.length && s[i] == '+') {
        i++;
        a += _mul();
      } else if (i < s.length && s[i] == '-') {
        i++;
        a -= _mul();
      } else if (_word('or')) {
        final b = _mul();
        a = (a != 0 || b != 0) ? 1 : 0;
      } else if (_word('xor')) {
        final b = _mul();
        a = ((a != 0) != (b != 0)) ? 1 : 0;
      } else {
        return a;
      }
    }
  }

  double _mul() {
    var a = _unary();
    while (true) {
      ws();
      if (i < s.length &&
          s[i] == '*' &&
          !(i + 1 < s.length && s[i + 1] == '*')) {
        i++;
        a *= _unary();
      } else if (i < s.length && s[i] == '/') {
        i++;
        final d = _unary();
        a = d == 0 ? 0 : a / d;
      } else if (_word('mod')) {
        final d = _unary();
        a = d == 0 ? 0 : a - d * (a / d).floorToDouble();
      } else if (_word('and')) {
        final b = _unary();
        a = (a != 0 && b != 0) ? 1 : 0;
      } else {
        return a;
      }
    }
  }

  double _unary() {
    ws();
    if (i < s.length && s[i] == '-') {
      i++;
      return -_unary();
    }
    if (i < s.length && s[i] == '+') {
      i++;
      return _unary();
    }
    var a = primary();
    ws();
    if (i + 1 < s.length && s[i] == '*' && s[i + 1] == '*') {
      i += 2;
      a = math.pow(a, _unary()).toDouble();
    }
    return a;
  }

  /// Nombre normalizado de un parámetro en [i] (`#12`, `#<x>`, `#[expr]`).
  String refName() {
    i++; // '#'
    if (i < s.length && s[i] == '<') {
      final e = s.indexOf('>', i);
      final n = s.substring(i, e < 0 ? s.length : e + 1);
      i = e < 0 ? s.length : e + 1;
      return NgcCalc.key(n);
    }
    if (i < s.length && s[i] == '[') {
      final v = primary();
      return v.round().toString();
    }
    if (i < s.length && s[i] == '#') {
      final v = c.get(refName());
      return v.round().toString();
    }
    final st = i;
    while (i < s.length && s.codeUnitAt(i) >= 0x30 && s.codeUnitAt(i) <= 0x39) {
      i++;
    }
    return s.substring(st, i);
  }

  double primary() {
    ws();
    if (i >= s.length) return 0;
    final ch = s[i];
    if (ch == '[') {
      i++;
      final v = expr();
      ws();
      if (i < s.length && s[i] == ']') i++;
      return v;
    }
    if (ch == '#') return c.get(refName());
    if (ch == '-' || ch == '+') return primaryOrSigned();
    final m = RegExp(r'\d*\.?\d+(?:[eE][-+]?\d+)?|\d+\.').matchAsPrefix(s, i);
    if (m != null) {
      i = m.end;
      return double.parse(
        m.group(0)!.endsWith('.') ? '${m.group(0)}0' : m.group(0)!,
      );
    }
    final f = RegExp(r'[a-zA-Z]+').matchAsPrefix(s, i);
    if (f != null) {
      final name = f.group(0)!.toLowerCase();
      i = f.end;
      if (name == 'atan') {
        final a = primary();
        ws();
        if (i < s.length && s[i] == '/') i++;
        final d = primary();
        return math.atan2(a, d) * 180 / math.pi;
      }
      if (name == 'exists') {
        primary();
        return 0;
      }
      final a = primary();
      const r = math.pi / 180;
      return switch (name) {
        'abs' => a.abs(),
        'acos' => math.acos(a.clamp(-1.0, 1.0)) / r,
        'asin' => math.asin(a.clamp(-1.0, 1.0)) / r,
        'cos' => math.cos(a * r),
        'sin' => math.sin(a * r),
        'tan' => math.tan(a * r),
        'exp' => math.exp(a),
        'ln' => a > 0 ? math.log(a) : 0,
        'sqrt' => a >= 0 ? math.sqrt(a) : 0,
        'fix' => a.floorToDouble(),
        'fup' => a.ceilToDouble(),
        'round' => a.roundToDouble(),
        _ => a,
      };
    }
    i++;
    return 0;
  }
}
