import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../l10n/l10n.dart';
import 'iso_run.dart';
import '../model/lines.dart';
import '../model/mesh.dart';
import '../model/print_summary.dart';
import 'ngc_calc.dart';
import '../model/toolpath.dart';

/// Resultado transportable entre isolates.
class GcodeData {
  GcodeData({
    required this.name,
    required Float32List paths,
    required Float32List travels,
    required Uint8List feature,
    required Uint8List tool,
    required Float32List feed,
    required Float32List flow,
    required Int32List layerFirstSeg,
    required Int32List layerFirstTravel,
    required Float32List layerZ,
    required this.info,
    required this.isFdm,
    required this.stats,
    required this.min,
    required this.max,
    this.toolColors = const [],
  }) : _p = TransferableTypedData.fromList([paths]),
       _t = TransferableTypedData.fromList([travels]),
       _f = TransferableTypedData.fromList([feature]),
       _tool = TransferableTypedData.fromList([tool]),
       _feed = TransferableTypedData.fromList([feed]),
       _flow = TransferableTypedData.fromList([flow]),
       _lp = TransferableTypedData.fromList([layerFirstSeg]),
       _lt = TransferableTypedData.fromList([layerFirstTravel]),
       _lz = TransferableTypedData.fromList([layerZ]);

  final String name;
  final TransferableTypedData _p, _t, _f, _tool, _feed, _flow, _lp, _lt, _lz;

  final List<String> info;
  final bool isFdm;
  final GcodeStats stats;
  final List<double> min, max;
  final List<int> toolColors;

  Toolpath build() {
    final b = Bounds(min, max);
    final t = Toolpath(
      name: name,
      paths: LineSet(vertices: _p.materialize().asFloat32List(), bounds: b),
      travels: LineSet(vertices: _t.materialize().asFloat32List(), bounds: b),
      feature: _f.materialize().asUint8List(),
      tool: _tool.materialize().asUint8List(),
      feed: _feed.materialize().asFloat32List(),
      flow: _flow.materialize().asFloat32List(),
      layerFirstSeg: _lp.materialize().asInt32List(),
      layerFirstTravel: _lt.materialize().asInt32List(),
      layerZ: _lz.materialize().asFloat32List(),
      info: info,
      isFdm: isFdm,
      stats: stats,
      toolColors: toolColors,
    );
    final kinds = t.featureCounts().where((c) => c > 0).length;
    t.recolor(
      !isFdm
          ? ToolpathColorMode.speed
          : toolColors.length > 1
          ? ToolpathColorMode.tool
          : kinds >= 2
          ? ToolpathColorMode.feature
          : ToolpathColorMode.height,
    );
    return t;
  }
}

/// Abre un proyecto de Bambu / Orca laminado (`.gcode.3mf`): el G-code va dentro del ZIP.
Future<GcodeData> loadGcode3mf(String path, {int plate = 0}) => isoRun(() {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  final plates =
      archive.files
          .where(
            (f) =>
                f.isFile && RegExp(r'(^|/)plate_\d+\.gcode$').hasMatch(f.name),
          )
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
  if (plates.isEmpty)
    throw Exception(tr('Este 3MF no contiene G-code (no está laminado)'));
  final chosen = plate > 0
      ? plates.firstWhere(
          (f) => f.name.endsWith('plate_$plate.gcode'),
          orElse: () => plates.first,
        )
      : plates.first;
  final bytes = Uint8List.fromList(chosen.content as List<int>);
  Uint8List? thumb;
  for (final f in archive.files) {
    if (f.isFile &&
        RegExp(plate > 0 ? 'Metadata/plate_$plate\\.png\$' : r'Metadata/plate_\d+\.png$').hasMatch(f.name) &&
        thumb == null) {
      thumb = Uint8List.fromList(f.content as List<int>);
    }
  }
  return parseGcode(bytes, path.split('/').last, extraThumb: thumb);
});

Future<GcodeData> loadGcode(String path) => isoRun(
  () => parseGcode(File(path).readAsBytesSync(), path.split('/').last),
);

/// Acumulador de floats con crecimiento.
class _F32 {
  Float32List a = Float32List(1 << 16);
  int n = 0;
  void add6(double x, double y, double z) {
    if (n + 6 > a.length) {
      final b = Float32List(a.length * 2);
      b.setAll(0, a);
      a = b;
    }
    a[n] = x;
    a[n + 1] = y;
    a[n + 2] = z;
    a[n + 3] = 1;
    a[n + 4] = 1;
    a[n + 5] = 1;
    n += 6;
  }

  Float32List done() => Float32List.sublistView(a, 0, n);
}

class _U8 {
  Uint8List a = Uint8List(1 << 14);
  int n = 0;
  void add(int v) {
    if (n == a.length) {
      final b = Uint8List(a.length * 2);
      b.setAll(0, a);
      a = b;
    }
    a[n++] = v;
  }

  Uint8List done() => Uint8List.sublistView(a, 0, n);
}

class _FL {
  Float32List a = Float32List(1 << 14);
  int n = 0;
  void add(double v) {
    if (n == a.length) {
      final b = Float32List(a.length * 2);
      b.setAll(0, a);
      a = b;
    }
    a[n++] = v;
  }

  Float32List done() => Float32List.sublistView(a, 0, n);
}

int _featureOf(String raw) {
  final s = raw.toLowerCase();
  if (s.contains('support')) return 5;
  if (s.contains('bridge') || s.contains('overhang')) return 6;
  if (s.contains('skirt') ||
      s.contains('brim') ||
      s.contains('prime') ||
      s.contains('wipe') ||
      s.contains('purge')) {
    return 7;
  }
  if (s.contains('outer') || s.contains('external')) return 1;
  if (s.contains('inner') || s.contains('perimeter') || s.contains('wall'))
    return 2;
  if (s.contains('solid') ||
      s.contains('top') ||
      s.contains('bottom') ||
      s.contains('skin'))
    return 4;
  if (s.contains('infill') || s.contains('fill')) return 3;
  return 0;
}

GcodeData parseGcode(
  Uint8List b,
  String name, {
  List<String> extraInfo = const [],
  Map<String, String> extraMeta = const {},
  Uint8List? extraThumb,
  int extraThumbFormat = 0,
}) {
  final paths = _F32(), travels = _F32();
  final feature = _U8(), toolArr = _U8();
  final feed = _FL();
  final flowArr = _FL();
  var curFlow = 0.0;
  final layerSeg = <int>[0], layerTravel = <int>[0];
  final layerZ = <double>[0];
  final info = <String>[];
  var toolColors = <int>[];
  final meta = <String, String>{...extraMeta};
  final layerSeconds = <double>[];
  var curLayerSeconds = 0.0;
  final featureSeconds = List<double>.filled(kFeatureNames.length, 0);
  var travelSeconds = 0.0;
  final toolMm = List<double>.filled(32, 0);
  var retractions = 0;
  final nozzleTemps = <int>{}, bedTemps = <int>{};
  var fanMax = 0;
  final colorChanges = <int>[];
  final toolSec = List<double>.filled(32, 0),
      toolCut = List<double>.filled(32, 0);
  Uint8List? thumb;
  var thumbFormat = 0;
  var thumbOn = false;
  var thumbFmtCur = 0;
  final thumbBuf = StringBuffer();
  if (extraThumb != null) {
    thumb = extraThumb;
    thumbFormat = extraThumbFormat;
  }
  final segLine = <int>[];
  final segComp = <int>[];
  var compSide = 0; // 0 sin compensación, 1 izquierda (G41), -1 derecha (G42)
  var lineNo = 0;
  final cncTools = <CncTool>[];
  final toolNames = <int, String>{};
  var rapidMm = 0.0, cutMm = 0.0;
  var rapidPlunges = 0, firstPlungeLine = 0;
  var spMin = double.infinity, spMax = 0.0;
  var coolant = false, sawSpindle = false;
  String? units;
  final envMin = [double.infinity, double.infinity, double.infinity];
  final envMax = [-double.infinity, -double.infinity, -double.infinity];

  var x = 0.0, y = 0.0, z = 0.0, e = 0.0, f = 0.0;
  var absolute = true, extAbsolute = true;
  var unit = 1.0;
  var plane = 17;
  var usesE = false;
  var curFeature = 0, curTool = 0;
  var explicitLayers = false;
  var curLayerZ = double.negativeInfinity;
  var started = false; // ya hubo algún movimiento
  var sawG1 = false;
  final tol = 0.02;
  final mn = [double.infinity, double.infinity, double.infinity];
  final mx = [-double.infinity, -double.infinity, -double.infinity];

  var layerZPending = false;

  // Al aparecer el primer marcador de capa, las «capas» deducidas de la altura (purga previa) se funden en una.
  void collapseLayers() {
    if (layerSeg.length <= 1) return;
    layerSeg
      ..clear()
      ..add(0);
    layerTravel
      ..clear()
      ..add(0);
    final z0 = layerZ.isEmpty ? 0.0 : layerZ.first;
    layerZ
      ..clear()
      ..add(z0);
    curLayerSeconds += layerSeconds.fold(0.0, (a, b) => a + b);
    layerSeconds.clear();
  }

  var firstMarker = false;

  void newLayer(double zz) {
    layerZPending = true;
    // Evita capas vacías consecutivas.
    if (layerSeg.last == feature.n &&
        layerTravel.last == travels.n ~/ 6 ~/ 2 &&
        layerSeg.length > 1) {
      layerZ[layerZ.length - 1] = zz;
      return;
    }
    // Lo anterior al primer marcador (purga, línea de imprimación) forma parte de la capa 1.
    if (explicitLayers && layerSeg.length == 1 && !firstMarker) {
      firstMarker = true;
      layerZ[0] = zz;
      return;
    }
    if (!explicitLayers && feature.n == 0 && layerSeg.length == 1) {
      layerZ[0] = zz;
      return;
    }
    layerSeg.add(feature.n);
    layerTravel.add(travels.n ~/ 12);
    layerZ.add(zz);
    layerSeconds.add(curLayerSeconds);
    curLayerSeconds = 0;
  }

  void addSegment(
    double x0,
    double y0,
    double z0,
    double x1,
    double y1,
    double z1,
    bool extrude,
  ) {
    if (x0 == x1 && y0 == y1 && z0 == z1) return;
    final dx = x1 - x0, dy = y1 - y0, dz = z1 - z0;
    final segLen = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (extrude) {
      cutMm += segLen;
      toolCut[curTool] += segLen;
    } else {
      rapidMm += segLen;
    }
    for (final q in [(x0, y0, z0), (x1, y1, z1)]) {
      if (q.$1 < envMin[0]) envMin[0] = q.$1;
      if (q.$1 > envMax[0]) envMax[0] = q.$1;
      if (q.$2 < envMin[1]) envMin[1] = q.$2;
      if (q.$2 > envMax[1]) envMax[1] = q.$2;
      if (q.$3 < envMin[2]) envMin[2] = q.$3;
      if (q.$3 > envMax[2]) envMax[2] = q.$3;
    }
    if (f > 0) {
      final dt = math.sqrt(dx * dx + dy * dy + dz * dz) * 60 / f;
      curLayerSeconds += dt;
      toolSec[curTool] += dt;
      if (extrude) {
        featureSeconds[curFeature] += dt;
      } else {
        travelSeconds += dt;
      }
    }
    if (extrude) {
      paths.add6(x0, y0, z0);
      paths.add6(x1, y1, z1);
      feature.add(curFeature);
      segLine.add(lineNo);
      segComp.add(compSide);
      toolArr.add(curTool);
      feed.add(f);
      flowArr.add(curFlow);
      for (final p in [(x0, y0, z0), (x1, y1, z1)]) {
        if (p.$1 < mn[0]) mn[0] = p.$1;
        if (p.$1 > mx[0]) mx[0] = p.$1;
        if (p.$2 < mn[1]) mn[1] = p.$2;
        if (p.$2 > mx[1]) mx[1] = p.$2;
        if (p.$3 < mn[2]) mn[2] = p.$3;
        if (p.$3 > mx[2]) mx[2] = p.$3;
      }
    } else {
      travels.add6(x0, y0, z0);
      travels.add6(x1, y1, z1);
    }
  }

  // ---- Estado modal de CNC: ciclos fijos, movimiento modal y parámetros
  var cycle = 0;
  double cycR = 0, cycZ = 0, cycQ = 0, cycInitZ = 0;
  var retInit = true;
  int? lastMotion;
  final calc = NgcCalc();
  var unsupportedFlow = false;
  var cutterComp = false;
  final wcs = <int>{};
  // Desplazamientos de coordenadas de trabajo: G10 L2/L20 (por sistema) y G92 (global).
  final wcsOff = <int, List<double>>{};
  var curWcs = 54;
  final shift = [0.0, 0.0, 0.0];
  var ox = 0.0, oy = 0.0, oz = 0.0;
  void recalcOff() {
    final w = wcsOff[curWcs] ?? const [0.0, 0.0, 0.0];
    ox = w[0] + shift[0];
    oy = w[1] + shift[1];
    oz = w[2] + shift[2];
  }
  final fanucSubs = <int, int>{};
  final nLabels = <int, int>{};
  var nLabelsBuilt = false;
  final fanucStack = <(int, int, int)>[];
  var fanucCallLine = <int>[];

  void runCycle(int g, double? ax, double? ay) {
    final x0 = x, y0 = y, z0 = z;
    final tx = ax == null ? x0 : (absolute ? ax * unit + ox : x0 + ax * unit);
    final ty = ay == null ? y0 : (absolute ? ay * unit + oy : y0 + ay * unit);
    final rr = absolute ? cycR * unit + oz : cycInitZ + cycR * unit;
    final zz = absolute ? cycZ * unit + oz : rr + cycZ * unit;
    started = true;
    sawG1 = true;
    var cz = z0;
    if (cz < rr) {
      addSegment(x0, y0, cz, x0, y0, rr, false);
      cz = rr;
    }
    addSegment(x0, y0, cz, tx, ty, cz, false);
    if (cz > rr) {
      addSegment(tx, ty, cz, tx, ty, rr, false);
    }
    final q = cycQ * unit;
    var cur = rr;
    if ((g == 83 || g == 73) && q > 1e-6) {
      while (cur > zz + 1e-6) {
        final next = math.max(cur - q, zz);
        addSegment(tx, ty, cur, tx, ty, next, true);
        if (next > zz + 1e-6 && g == 83) {
          addSegment(tx, ty, next, tx, ty, rr, false);
          addSegment(tx, ty, rr, tx, ty, next, false);
        }
        cur = next;
      }
    } else {
      addSegment(tx, ty, rr, tx, ty, zz, true);
    }
    final feedOut = g == 84 || g == 85 || g == 89 || g == 74;
    addSegment(tx, ty, zz, tx, ty, rr, feedOut);
    var fin = rr;
    if (retInit && cycInitZ > rr) {
      addSegment(tx, ty, rr, tx, ty, cycInitZ, false);
      fin = cycInitZ;
    }
    x = tx;
    y = ty;
    z = fin;
  }

  // ---- Índice de líneas (una pasada) y estructuras de control O-word (LinuxCNC)
  final len = b.length;
  final starts = <int>[], ends = <int>[];
  {
    var p0 = 0;
    while (p0 < len) {
      var e0 = p0;
      while (e0 < len && b[e0] != 10 && b[e0] != 13) {
        e0++;
      }
      starts.add(p0);
      ends.add(e0);
      p0 = e0 + 1;
      if (e0 < len && b[e0] == 13 && p0 < len && b[p0] == 10) p0++;
    }
  }
  final oInfo = <int, (String, String, int)>{};
  final byLabel = <String, List<int>>{};
  final subs = <String, int>{};
  for (var li0 = 0; li0 < starts.length; li0++) {
    var q = starts[li0];
    final qe = ends[li0];
    while (q < qe && (b[q] == 32 || b[q] == 9)) {
      q++;
    }
    if (q + 1 >= qe || (b[q] != 0x4F && b[q] != 0x6F)) continue;
    if (!((b[q + 1] >= 0x30 && b[q + 1] <= 0x39) || b[q + 1] == 0x3C)) continue;
    var r = q + 1;
    if (b[r] == 0x3C) {
      while (r < qe && b[r] != 0x3E) {
        r++;
      }
      r++;
    } else {
      while (r < qe && b[r] >= 0x30 && b[r] <= 0x39) {
        r++;
      }
    }
    final label = NgcCalc.key(String.fromCharCodes(b, q + 1, math.min(r, qe)));
    while (r < qe && b[r] == 32) {
      r++;
    }
    final ks = r;
    while (r < qe && ((b[r] | 0x20) >= 0x61 && (b[r] | 0x20) <= 0x7A)) {
      r++;
    }
    final kind = String.fromCharCodes(b, ks, r).toLowerCase();
    if (kind.isEmpty) {
      if (b[q + 1] != 0x3C) {
        final num = int.tryParse(
          String.fromCharCodes(b, q + 1, math.min(r, qe)),
        );
        if (num != null) fanucSubs.putIfAbsent(num, () => li0);
      }
      continue;
    }
    oInfo[li0] = (label, kind, r);
    byLabel.putIfAbsent(label, () => []).add(li0);
    if (kind == 'sub') subs[label] = li0;
  }
  final hasO = oInfo.isNotEmpty;
  final callStack = <(int, Map<String, double>)>[];
  final repeatLeft = <String, int>{};
  var arrived = false;

  int? nextKind(String label, int after, Set<String> kinds) {
    for (final j in byLabel[label] ?? const <int>[]) {
      if (j > after && kinds.contains(oInfo[j]!.$2)) return j;
    }
    return null;
  }

  int? prevKind(String label, int before, Set<String> kinds) {
    int? found;
    for (final j in byLabel[label] ?? const <int>[]) {
      if (j >= before) break;
      if (kinds.contains(oInfo[j]!.$2)) found = j;
    }
    return found;
  }

  bool truth(int li, int rest, int end) => calc.valueAt(b, rest, end).$1 != 0;

  int oStep(int li, int end) {
    final (label, kind, rest) = oInfo[li]!;
    final wasArrived = arrived;
    arrived = false;
    switch (kind) {
      case 'sub':
        return (nextKind(label, li, {'endsub'}) ?? li) + 1;
      case 'endsub' || 'return':
        if (callStack.isEmpty) return li + 1;
        final (ret, saved) = callStack.removeLast();
        for (var n = 1; n <= 30; n++) {
          calc.params['$n'] = saved['$n'] ?? 0;
        }
        return ret;
      case 'call':
        final target = subs[label];
        if (target == null || callStack.length > 200) return li + 1;
        final saved = {
          for (var n = 1; n <= 30; n++) '$n': calc.params['$n'] ?? 0,
        };
        var k = rest, n = 1;
        final args = <double>[];
        while (k < end) {
          while (k < end && (b[k] == 32 || b[k] == 9)) {
            k++;
          }
          if (k >= end || b[k] != 0x5B) break;
          final r = calc.valueAt(b, k, end);
          args.add(r.$1);
          k = r.$2;
        }
        for (final a in args) {
          calc.params['${n++}'] = a;
        }
        callStack.add((li + 1, saved));
        return target + 1;
      case 'if':
        if (truth(li, rest, end)) return li + 1;
        final j = nextKind(label, li, {'elseif', 'else', 'endif'});
        arrived = true;
        return (j ?? li) +
            (j == null ? 1 : 0) +
            (oInfo[j ?? li]?.$2 == 'endif' ? 1 : 0);
      case 'elseif':
        if (!wasArrived) {
          final j = nextKind(label, li, {'endif'});
          return (j ?? li) + 1;
        }
        if (truth(li, rest, end)) return li + 1;
        final j = nextKind(label, li, {'elseif', 'else', 'endif'});
        arrived = true;
        return (j ?? li) + (oInfo[j ?? li]?.$2 == 'endif' ? 1 : 0);
      case 'else':
        if (!wasArrived) {
          final j = nextKind(label, li, {'endif'});
          return (j ?? li) + 1;
        }
        return li + 1;
      case 'endif' || 'do':
        return li + 1;
      case 'while':
        final bottom = prevKind(label, li, {'do'}) != null;
        final t = truth(li, rest, end);
        if (bottom) {
          return t ? prevKind(label, li, {'do'})! + 1 : li + 1;
        }
        if (t) return li + 1;
        return (nextKind(label, li, {'endwhile'}) ?? li) + 1;
      case 'endwhile':
        return prevKind(label, li, {'while'}) ?? li + 1;
      case 'repeat':
        final cnt = calc.valueAt(b, rest, end).$1.round();
        if (cnt < 1) return (nextKind(label, li, {'endrepeat'}) ?? li) + 1;
        repeatLeft[label] = cnt - 1;
        return li + 1;
      case 'endrepeat':
        final left = repeatLeft[label] ?? 0;
        if (left > 0) {
          repeatLeft[label] = left - 1;
          return (prevKind(label, li, {'repeat'}) ?? li) + 1;
        }
        return li + 1;
      case 'break':
        return (nextKind(label, li, {'endwhile', 'endrepeat'}) ?? li) + 1;
      case 'continue':
        final w = nextKind(label, li, {'endwhile', 'endrepeat', 'while'});
        return w ?? li + 1;
      default:
        unsupportedFlow = true;
        return li + 1;
    }
  }

  void buildN() {
    nLabelsBuilt = true;
    for (var l2 = 0; l2 < starts.length; l2++) {
      var q2 = starts[l2];
      while (q2 < ends[l2] && b[q2] == 32) {
        q2++;
      }
      if (q2 + 1 < ends[l2] && (b[q2] | 0x20) == 0x6E) {
        var q3 = q2 + 1, v = 0;
        while (q3 < ends[l2] && b[q3] >= 0x30 && b[q3] <= 0x39) {
          v = v * 10 + b[q3] - 0x30;
          q3++;
        }
        if (q3 > q2 + 1) nLabels.putIfAbsent(v, () => l2);
      }
    }
  }

  var li = 0;
  var steps = 0;
  while (li < starts.length) {
    if (++steps >
        (hasO || nLabelsBuilt || fanucSubs.isNotEmpty ? 4000000 : 60000000)) {
      unsupportedFlow = true;
      break;
    }
    final cur = li++;
    final end = ends[cur];
    lineNo = cur + 1;
    var i = starts[cur];
    while (i < end && (b[i] == 32 || b[i] == 9)) {
      i++;
    }
    if (i >= end) continue;
    if (b[i] == 0x2F) continue; // bloque omitido
    if (b[i] == 0x23) {
      calc.tryAssign(b, i, end);
      continue;
    }
    if (hasO && (b[i] == 0x4F || b[i] == 0x6F) && oInfo.containsKey(cur)) {
      li = oStep(cur, end);
      continue;
    }
    if (b[i] == 0x25) continue; // % de inicio/fin de programa
    if (((b[i] | 0x20) >= 0x61 && (b[i] | 0x20) <= 0x7A) &&
        i + 1 < end &&
        ((b[i + 1] | 0x20) >= 0x61 && (b[i + 1] | 0x20) <= 0x7A)) {
      var we = i;
      while (we < end && (b[we] | 0x20) >= 0x61 && (b[we] | 0x20) <= 0x7A) {
        we++;
      }
      final w = String.fromCharCodes(b, i, we).toUpperCase();
      if (w == 'GOTO' || w == 'IF' || w == 'WHILE' || w == 'END') {
        if (!nLabelsBuilt) buildN();
        int digits(int from, [int? lim]) {
          final e = lim ?? end;
          var q = from, v = 0;
          while (q < e && (b[q] == 32 || b[q] == 9)) {
            q++;
          }
          while (q < e && b[q] >= 0x30 && b[q] <= 0x39) {
            v = v * 10 + b[q] - 0x30;
            q++;
          }
          return v;
        }

        if (w == 'GOTO') {
          li = nLabels[digits(we)] ?? li;
        } else if (w == 'IF') {
          var k2 = we;
          while (k2 < end && b[k2] == 32) {
            k2++;
          }
          final r = calc.valueAt(b, k2, end);
          k2 = r.$2;
          while (k2 < end && b[k2] == 32) {
            k2++;
          }
          var ke = k2;
          while (ke < end && (b[ke] | 0x20) >= 0x61 && (b[ke] | 0x20) <= 0x7A) {
            ke++;
          }
          final kw = String.fromCharCodes(b, k2, ke).toUpperCase();
          if (r.$1 != 0) {
            if (kw == 'GOTO') {
              li = nLabels[digits(ke)] ?? li;
            } else if (kw == 'THEN') {
              calc.tryAssign(b, ke, end);
            }
          }
        } else if (w == 'WHILE') {
          var k2 = we;
          while (k2 < end && b[k2] == 32) {
            k2++;
          }
          final r = calc.valueAt(b, k2, end);
          if (r.$1 == 0) {
            // Salta hasta el END con el mismo número.
            var ke = r.$2;
            while (ke < end && b[ke] == 32) {
              ke++;
            }
            while (ke < end &&
                (b[ke] | 0x20) >= 0x61 &&
                (b[ke] | 0x20) <= 0x7A) {
              ke++;
            }
            final n = digits(ke);
            for (var l2 = cur + 1; l2 < starts.length; l2++) {
              var q2 = starts[l2];
              while (q2 < ends[l2] && b[q2] == 32) {
                q2++;
              }
              if (q2 + 2 < ends[l2] &&
                  String.fromCharCodes(b, q2, q2 + 3).toUpperCase() == 'END' &&
                  digits(q2 + 3, ends[l2]) == n) {
                li = l2 + 1;
                break;
              }
            }
          }
        } else {
          // ENDn: vuelve al WHILE con el mismo número.
          final n = digits(we);
          for (var l2 = cur - 1; l2 >= 0; l2--) {
            var q2 = starts[l2];
            while (q2 < ends[l2] && b[q2] == 32) {
              q2++;
            }
            if (q2 + 4 < ends[l2] &&
                String.fromCharCodes(b, q2, q2 + 5).toUpperCase() == 'WHILE') {
              var q3 = q2 + 5;
              while (q3 < ends[l2] && b[q3] != 0x5D) {
                q3++;
              }
              q3++;
              while (q3 < ends[l2] && b[q3] == 32) {
                q3++;
              }
              while (q3 < ends[l2] &&
                  (b[q3] | 0x20) >= 0x61 &&
                  (b[q3] | 0x20) <= 0x7A) {
                q3++;
              }
              var q4 = q3, v = 0;
              while (q4 < ends[l2] && b[q4] >= 0x30 && b[q4] <= 0x39) {
                v = v * 10 + b[q4] - 0x30;
                q4++;
              }
              if (v == n) {
                li = l2;
                break;
              }
            }
          }
        }
        continue;
      }
    }

    if (b[i] == 0x3B /* ; */ ) {
      // Comentario: marcadores de capa, tipo de movimiento e información de cabecera.
      var j = i + 1;
      while (j < end && b[j] == 32) {
        j++;
      }
      final text = String.fromCharCodes(b, j, math.min(end, j + 90));
      if (thumbOn) {
        if (text.startsWith('thumbnail') && text.contains('end')) {
          thumbOn = false;
          try {
            final bytes = base64.decode(thumbBuf.toString());
            if (thumb == null || bytes.length > thumb.length) {
              thumb = bytes;
              thumbFormat = thumbFmtCur;
            }
          } catch (_) {}
        } else if (thumbBuf.length < 4000000) {
          thumbBuf.write(text.trim());
        }
        continue;
      }
      if (text.startsWith('thumbnail') && text.contains('begin')) {
        thumbOn = true;
        thumbBuf.clear();
        thumbFmtCur = text.contains('QOI')
            ? 2
            : text.contains('JPG')
            ? 1
            : 0;
        continue;
      }
      if (text.startsWith('LAYER_CHANGE') || text.startsWith('CHANGE_LAYER')) {
        if (!explicitLayers) collapseLayers();
        explicitLayers = true;
        if (started) {
          newLayer(z);
        } else {
          firstMarker = true;
        }
      } else if (text.startsWith('LAYER:')) {
        if (!explicitLayers) collapseLayers();
        explicitLayers = true;
        if (started) {
          newLayer(z);
        } else {
          firstMarker = true;
        }
      } else if (text.startsWith('filament_colour') ||
          text.startsWith('extruder_colour')) {
        // Colores de filamento: "; filament_colour = #FFFFFF;#000000"
        final line = String.fromCharCodes(b, j, end);
        final found = RegExp(r'#([0-9A-Fa-f]{6})')
            .allMatches(line)
            .map((m) => int.parse(m.group(1)!, radix: 16))
            .toList();
        if (found.isNotEmpty &&
            (toolColors.isEmpty || text.startsWith('filament_colour')))
          toolColors = found;
      } else if ((text.startsWith('Z:') || text.startsWith('Z_HEIGHT:')) &&
          explicitLayers) {
        final zz = double.tryParse(
          text.substring(text.indexOf(':') + 1).trim(),
        );
        if (zz != null) {
          layerZ[layerZ.length - 1] = zz;
          layerZPending = false;
        }
      } else if (text.startsWith('FEATURE:')) {
        curFeature = _featureOf(text.substring(8));
      } else if (text.startsWith('TYPE:')) {
        curFeature = _featureOf(text.substring(5));
      } else if (text.startsWith('feature ')) {
        // Simplify3D: «; feature outer perimeter»
        curFeature = _featureOf(text.substring(8));
      } else if (text.startsWith("'") && sawG1) {
        // KISSlicer: «; 'Perimeter Path', …»
        final q = text.indexOf("'", 1);
        if (q > 1)
          curFeature = _featureOf(text.substring(1, q).replaceAll('Path', ''));
      } else {
        if (!sawG1 &&
            info.length < 60 &&
            (text.contains(':') || text.contains('='))) {
          if (!text.startsWith('HEADER_BLOCK') &&
              !text.startsWith('CONFIG') &&
              text.length > 4) {
            info.add(text);
          }
        }
        if (!sawG1 &&
            !meta.containsKey('generator') &&
            RegExp(
              r'^(BambuStudio|Bambu Studio|OrcaSlicer|Generated with|generated by|G-Code generated by|Simplify3D|KISSlicer|ideaMaker)',
              caseSensitive: false,
            ).hasMatch(text)) {
          meta['generator'] = text
              .replaceFirst(
                RegExp(
                  r'^(g-code )?generated (by|with) ',
                  caseSensitive: false,
                ),
                '',
              )
              .replaceAll(RegExp(r' on \d{4}-.*'), '')
              .replaceAll('(R)', '');
        }
        _captureMeta(b, j, end, meta, sawG1);
      }
      continue;
    }

    // Línea de órdenes: se recorren letra + número.
    int? mCode;
    double? nx, ny, nz, ne, nf, ci, cj, ck, cr, ns, nq, np, nl;
    final gs = <double>[];
    var hasT = false;
    var tNum = 0;
    String? paren;
    var k = i;
    while (k < end) {
      final c = b[k];
      if (c == 0x3B) break; // comentario al final de línea
      if (c == 0x28) {
        // ( comentario )
        final ps = k + 1;
        while (k < end && b[k] != 0x29) {
          k++;
        }
        if (paren == null && k > ps)
          paren = String.fromCharCodes(b, ps, math.min(k, ps + 60));
        k++;
        continue;
      }
      if (c == 0x23) {
        calc.tryAssign(b, k, end);
        break;
      }
      final up = (c >= 0x61 && c <= 0x7A) ? c - 32 : c;
      if (up >= 0x41 && up <= 0x5A) {
        k++;
        while (k < end && b[k] == 32) {
          k++;
        }
        // número
        var neg = false;
        if (k < end && (b[k] == 0x2D || b[k] == 0x2B)) {
          neg = b[k] == 0x2D;
          k++;
        }
        var v = 0.0;
        var any = false;
        if (k < end && (b[k] == 0x5B || b[k] == 0x23)) {
          final r = calc.valueAt(b, k, end);
          v = r.$1;
          k = r.$2;
          any = true;
        } else {
          while (k < end && b[k] >= 0x30 && b[k] <= 0x39) {
            v = v * 10 + (b[k] - 0x30);
            k++;
            any = true;
          }
          if (k < end && b[k] == 0x2E) {
            k++;
            var scale = 0.1;
            while (k < end && b[k] >= 0x30 && b[k] <= 0x39) {
              v += (b[k] - 0x30) * scale;
              scale *= 0.1;
              k++;
              any = true;
            }
          }
        }
        if (!any) continue;
        if (neg) v = -v;
        switch (up) {
          case 0x47:
            gs.add(v);
          case 0x4D:
            mCode ??= v.round();
          case 0x58:
            nx = v;
          case 0x59:
            ny = v;
          case 0x5A:
            nz = v;
          case 0x45:
            ne = v;
          case 0x46:
            nf = v;
          case 0x49:
            ci = v;
          case 0x4A:
            cj = v;
          case 0x4B:
            ck = v;
          case 0x52:
            cr = v;
          case 0x53:
            ns = v;
          case 0x51:
            nq = v;
          case 0x50:
            np = v;
          case 0x4C:
            nl = v;
          case 0x54:
            hasT = true;
            tNum = v.round();
        }
      } else {
        k++;
      }
    }

    int? gCode;
    var g53 = false;
    for (final gv in gs) {
      if (gv != gv.roundToDouble())
        continue; // G91.1, G38.2, G64 P… no cambian el movimiento
      final g = gv.round();
      switch (g) {
        case 90:
          absolute = true;
        case 91:
          absolute = false;
        case 20:
          unit = 25.4;
          units ??= 'in';
        case 21:
          unit = 1.0;
          units ??= 'mm';
        case 17 || 18 || 19:
          plane = g;
        case 98:
          retInit = true;
        case 99:
          retInit = false;
        case 53:
          g53 = true;
        case 80:
          cycle = 0;
        case 40:
          compSide = 0;
        case 41 || 42:
          cutterComp = true;
          compSide = g == 41 ? 1 : -1;
        case 28 || 30:
          g53 = true; // retorno a origen de máquina: no se dibuja
        case >= 54 && <= 59:
          wcs.add(g);
          curWcs = g;
          recalcOff();
        case 10:
          // G10 L2 Pn (desplazamiento fijo) / L20 Pn (haz que la posición actual valga X Y Z)
          final l = nl?.round();
          if (l == 2 || l == 20) {
            final pn = np?.round() ?? 0;
            final target = pn <= 0 ? curWcs : 53 + pn;
            if (target >= 54 && target <= 59) {
              final w = List<double>.of(wcsOff[target] ?? const [0.0, 0.0, 0.0]);
              final cur = [x, y, z];
              final given = [nx, ny, nz];
              for (var a = 0; a < 3; a++) {
                final v = given[a];
                if (v == null) continue;
                w[a] = l == 2 ? v * unit : cur[a] - v * unit - shift[a];
              }
              wcsOff[target] = w;
              wcs.add(target);
              recalcOff();
            }
          }
          g53 = true; // no mueve la herramienta
        case 154:
          wcs.add(100 + (np?.round() ?? 0));
        case 0 || 1 || 2 || 3 || 73 || 74 || 76 || 92:
          gCode ??= g;
        case >= 81 && <= 89:
          gCode ??= g;
        default:
          break; // G4, G54-G59, G154, G43, G40… no mueven la herramienta
      }
    }
    if (hasT && tNum >= 0 && tNum < 32) {
      if (paren != null) toolNames[tNum] = paren;
      if (tNum != curTool || cncTools.isEmpty) {
        cncTools.add(CncTool(tNum, lineNo, toolNames[tNum]));
      }
      curTool = tNum;
    }
    if (mCode == 3 || mCode == 4) {
      sawSpindle = true;
      if (ns != null && ns > 0) {
        spMin = math.min(spMin, ns);
        spMax = math.max(spMax, ns);
      }
    }
    if (mCode == 7 || mCode == 8) coolant = true;
    if (mCode == 600) colorChanges.add(layerSeg.length - 1);
    if (mCode == 98 && np != null) {
      var pv = np.round(), reps = nl?.round() ?? 1;
      if (pv > 9999) {
        reps = pv ~/ 10000;
        pv %= 10000;
      }
      final target = fanucSubs[pv];
      if (target != null && fanucStack.length < 100) {
        fanucStack.add((li, reps - 1, target));
        li = target + 1;
      }
    } else if (mCode == 97 && np != null) {
      if (!nLabelsBuilt) buildN();
      final target = nLabels[np.round()];
      if (target != null && fanucStack.length < 100) {
        fanucStack.add((li, 0, target));
        li = target + 1;
      }
    } else if (mCode == 99 && fanucStack.isNotEmpty) {
      final (ret, left, st0) = fanucStack.removeLast();
      if (left > 0) {
        fanucStack.add((ret, left - 1, st0));
        li = st0 + 1;
      } else {
        li = ret;
      }
    } else if ((mCode == 30 || mCode == 2) && fanucSubs.isNotEmpty) {
      break;
    }
    if (mCode == 82) extAbsolute = true;
    if (mCode == 83) extAbsolute = false;
    if (ns != null) {
      if ((mCode == 104 || mCode == 109) && ns > 150 && ns < 600) {
        nozzleTemps.add(ns.round());
      } else if ((mCode == 140 || mCode == 190) && ns > 20 && ns < 200) {
        bedTemps.add(ns.round());
      } else if (mCode == 106) {
        fanMax = math.max(fanMax, ns.round().clamp(0, 255));
      }
    }
    if (g53) continue;
    if (gCode == null &&
        (nx != null ||
            ny != null ||
            nz != null ||
            (cycle != 0 && ny != null))) {
      if (cycle != 0 && (nx != null || ny != null)) {
        gCode = cycle;
      } else if (lastMotion != null && cycle == 0) {
        gCode = lastMotion;
      }
    }
    if (gCode == null) continue;

    switch (gCode) {
      case 73 || 74 || 76 || 81 || 82 || 83 || 84 || 85 || 86 || 87 || 88 || 89:
        if (cycle == 0) cycInitZ = z;
        cycle = gCode;
        if (cr != null) cycR = cr;
        if (nz != null) cycZ = nz;
        if (nq != null) cycQ = nq;
        if (nf != null) f = nf * unit;
        runCycle(gCode, nx, ny);
      case 90:
        absolute = true;
      case 91:
        absolute = false;
      case 20:
        unit = 25.4;
        units ??= 'in';
      case 21:
        unit = 1.0;
        units ??= 'mm';
      case 17 || 18 || 19:
        plane = gCode;
      case 92:
        // G92 redefine las coordenadas sin mover la herramienta: se acumula un desplazamiento
        final w = wcsOff[curWcs] ?? const [0.0, 0.0, 0.0];
        if (nx != null) shift[0] = x - nx * unit - w[0];
        if (ny != null) shift[1] = y - ny * unit - w[1];
        if (nz != null) shift[2] = z - nz * unit - w[2];
        recalcOff();
        if (ne != null) e = ne;
      case 0 || 1 || 2 || 3:
        lastMotion = gCode;
        cycle = 0;
        if (nf != null) f = nf * unit;
        if (ne != null) usesE = true;
        sawG1 = true;
        final x0 = x, y0 = y, z0 = z;
        final tx = nx == null ? x0 : (absolute ? nx * unit + ox : x0 + nx * unit);
        final ty = ny == null ? y0 : (absolute ? ny * unit + oy : y0 + ny * unit);
        final tz = nz == null ? z0 : (absolute ? nz * unit + oz : z0 + nz * unit);
        var de = 0.0;
        if (ne != null) {
          de = extAbsolute ? ne - e : ne;
          e = extAbsolute ? ne : e + ne;
          if (de > 1e-9) {
            if (tx != x0 || ty != y0 || tz != z0) toolMm[curTool] += de;
          } else if (de < -1e-9) {
            retractions++;
          }
        }
        final extrude = gCode == 0 ? false : (usesE ? de > 1e-9 : true);
        curFlow = 0;
        if (extrude && usesE && f > 0) {
          final cdx = tx - x0, cdy = ty - y0, cdz = tz - z0;
          final cl = math.sqrt(cdx * cdx + cdy * cdy + cdz * cdz);
          if (cl > 1e-6) curFlow = de * 2.405 * (f / 60) / cl;
        }
        started = true;
        if (layerZPending && extrude && explicitLayers) {
          layerZ[layerZ.length - 1] = tz;
          layerZPending = false;
        }
        if (gCode == 0 && tz < z0 - 1e-6 && tz < 0) {
          rapidPlunges++;
          if (firstPlungeLine == 0) firstPlungeLine = lineNo;
        }
        if (!explicitLayers &&
            extrude &&
            usesE &&
            (curLayerZ == double.negativeInfinity || tz > curLayerZ + 0.04)) {
          curLayerZ = tz;
          newLayer(tz);
        }
        if (gCode <= 1) {
          addSegment(x0, y0, z0, tx, ty, tz, extrude);
        } else {
          // Arco: centro por I/J/K (relativos al inicio) o por radio R.
          // Plano XY: ejes (x,y), eje lineal z; XZ: (x,z), lineal y; YZ: (y,z), lineal x.
          late double a0, b0, a1, b1, lin0, lin1;
          double? offA, offB;
          switch (plane) {
            case 18:
              (a0, b0, a1, b1, lin0, lin1) = (x0, z0, tx, tz, y0, ty);
              offA = ci;
              offB = ck;
            case 19:
              (a0, b0, a1, b1, lin0, lin1) = (y0, z0, ty, tz, x0, tx);
              offA = cj;
              offB = ck;
            default:
              (a0, b0, a1, b1, lin0, lin1) = (x0, y0, tx, ty, z0, tz);
              offA = ci;
              offB = cj;
          }
          final cw = gCode == 2;
          double ca, cb;
          if (offA != null || offB != null) {
            ca = a0 + (offA ?? 0) * unit;
            cb = b0 + (offB ?? 0) * unit;
          } else if (cr != null) {
            final r = cr * unit;
            final dx = a1 - a0, dy = b1 - b0;
            final d = math.sqrt(dx * dx + dy * dy);
            final h = math.sqrt(math.max(0, r * r - d * d / 4));
            final sign = (cw == (r > 0)) ? -1.0 : 1.0;
            ca = (a0 + a1) / 2 + sign * h * (-dy) / (d == 0 ? 1 : d);
            cb = (b0 + b1) / 2 + sign * h * dx / (d == 0 ? 1 : d);
          } else {
            addSegment(x0, y0, z0, tx, ty, tz, extrude);
            x = tx;
            y = ty;
            z = tz;
            continue;
          }
          final radius = math.sqrt(math.pow(a0 - ca, 2) + math.pow(b0 - cb, 2));
          var s0 = math.atan2(b0 - cb, a0 - ca),
              s1 = math.atan2(b1 - cb, a1 - ca);
          var sweep = s1 - s0;
          if (cw) {
            if (sweep >= -1e-9) sweep -= 2 * math.pi;
          } else {
            if (sweep <= 1e-9) sweep += 2 * math.pi;
          }
          final n = radius <= 0
              ? 1
              : (sweep.abs() /
                        (2 *
                            math.acos(
                              (1 - tol / math.max(radius, tol * 2)).clamp(
                                -1.0,
                                1.0,
                              ),
                            )))
                    .ceil()
                    .clamp(2, 400);
          var pa = a0, pb = b0, pl = lin0;
          for (var s = 1; s <= n; s++) {
            final t = s / n;
            final ang = s0 + sweep * t;
            final na = s == n ? a1 : ca + radius * math.cos(ang);
            final nb = s == n ? b1 : cb + radius * math.sin(ang);
            final nl = lin0 + (lin1 - lin0) * t;
            switch (plane) {
              case 18:
                addSegment(pa, pl, pb, na, nl, nb, extrude);
              case 19:
                addSegment(pl, pa, pb, nl, na, nb, extrude);
              default:
                addSegment(pa, pb, pl, na, nb, nl, extrude);
            }
            pa = na;
            pb = nb;
            pl = nl;
          }
        }
        x = tx;
        y = ty;
        z = tz;
    }
  }

  if (feature.n == 0)
    throw Exception(
      b.isEmpty
          ? tr('El archivo está vacío')
          : tr('No se han encontrado movimientos de trabajo: ¿es realmente un G-code?'),
    );
  layerSeg.add(feature.n);
  layerTravel.add(travels.n ~/ 12);
  layerSeconds.add(curLayerSeconds);
  // layerZ puede tener un elemento más que las capas reales: se recorta.
  final layerCount = layerSeg.length - 1;
  final lz = Float32List(layerCount);
  for (var q = 0; q < layerCount; q++) {
    lz[q] = q < layerZ.length ? layerZ[q] : 0;
  }
  return GcodeData(
    name: name,
    paths: paths.done(),
    travels: travels.done(),
    feature: feature.done(),
    tool: toolArr.done(),
    feed: feed.done(),
    flow: flowArr.done(),
    layerFirstSeg: Int32List.fromList(layerSeg),
    layerFirstTravel: Int32List.fromList(layerTravel),
    layerZ: lz,
    info: [...extraInfo, ...info],
    isFdm: usesE,
    stats: GcodeStats(
      meta: meta,
      layerSeconds: layerSeconds,
      featureSeconds: featureSeconds,
      travelSeconds: travelSeconds,
      toolMm: toolMm,
      retractions: retractions,
      nozzleTemps: nozzleTemps.toList()..sort(),
      bedTemps: bedTemps.toList()..sort(),
      fanMax: fanMax,
      colorChangeLayers: colorChanges,
      thumbnail: thumb,
      thumbnailFormat: thumbFormat,
      segLine: usesE ? null : Int32List.fromList(segLine),
      segComp: usesE ? null : Int8List.fromList(segComp),
      source: usesE || b.length > 40 * 1024 * 1024 ? null : b,
      cnc: usesE
          ? null
          : CncStats(
              tools: cncTools,
              rapidMm: rapidMm,
              cutMm: cutMm,
              rapidPlunges: rapidPlunges,
              firstPlungeLine: firstPlungeLine,
              spindleMin: spMin.isInfinite ? 0 : spMin,
              spindleMax: spMax,
              envMin: envMin,
              envMax: envMax,
              units: units,
              coolant: coolant,
              lineCount: lineNo,
              noSpindle: !sawSpindle,
              usesFlow: unsupportedFlow,
              cutterComp: cutterComp,
              wcsCount: wcs.length,
              toolSeconds: toolSec,
              toolCutMm: toolCut,
            ),
    ),
    min: mn,
    max: mx,
    toolColors: toolColors,
  );
}

const _ignoredMeta = {
  'type',
  'width',
  'height',
  'layer',
  'layer_count',
  'feature',
  'z',
  'time_elapsed',
  'mesh',
  'layer_change',
};

/// Guarda `clave = valor` / `clave: valor` de un comentario (el primero que aparece gana).
void _captureMeta(
  Uint8List b,
  int start,
  int end,
  Map<String, String> meta,
  bool inBody,
) {
  if (meta.length > 3000 || end - start < 5 || end - start > 400) return;
  var eq = -1;
  for (var q = start; q < end && q - start < 64; q++) {
    final c = b[q];
    if (c == 0x3D || c == 0x3A) {
      eq = q;
      break;
    }
  }
  var sep = eq;
  if (sep < 0) {
    // Simplify3D: «;   layerHeight,0.3»
    for (var q = start; q < end && q - start < 40; q++) {
      final c = b[q];
      if (c == 0x2C) {
        sep = q;
        break;
      }
      if (c == 0x20) break;
    }
  }
  if (sep < 0) return;
  eq = sep;
  var ke = eq;
  while (ke > start && b[ke - 1] == 32) {
    ke--;
  }
  if (ke <= start) return;
  final key = String.fromCharCodes(b, start, ke).toLowerCase();
  if (_ignoredMeta.contains(key)) return;
  if (inBody && key == 'time') return;
  var vs = eq + 1;
  while (vs < end && b[vs] == 32) {
    vs++;
  }
  var ve = end;
  while (ve > vs && (b[ve - 1] == 32 || b[ve - 1] == 13)) {
    ve--;
  }
  if (ve - vs > 200 || ve <= vs) return;
  final value = String.fromCharCodes(b, vs, ve);
  // Bambu: «model printing time: 18h 21m; total estimated time: 18h 27m».
  final semi = value.indexOf('; ');
  if (semi > 0 && key.contains('time')) {
    meta.putIfAbsent(key, () => value.substring(0, semi));
    final rest = value.substring(semi + 2);
    final c = rest.indexOf(':');
    if (c > 0) {
      meta.putIfAbsent(
        rest.substring(0, c).trim().toLowerCase(),
        () => rest.substring(c + 1).trim(),
      );
    }
    return;
  }
  meta.putIfAbsent(key, () => value);
}
