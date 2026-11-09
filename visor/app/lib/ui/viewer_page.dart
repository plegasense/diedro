// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/services.dart' show MethodChannel;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../io/cad_loader.dart' show cadCacheHit;
import '../io/loader.dart';
import '../model/document.dart';
import '../model/mesh.dart' show Bounds;
import '../model/pointcloud.dart';
import '../model/pmi.dart';
import '../model/scene.dart';
import '../model/units.dart';
import '../model/toolpath.dart';
import '../render/camera.dart';
import '../render/edl.dart';
import '../render/gpu_mesh.dart';
import '../render/picking.dart';
import '../model/brep.dart';
import 'cad_tools.dart';
import 'cloud_tools.dart';
import 'drawing_tools.dart';
import 'vector_tools.dart';
import 'stl_tools.dart';
import 'threemf_tools.dart';
import 'mesh_tools.dart';
import 'rig_player.dart';
import '../model/mesh_info.dart';
import '../model/threemf.dart';
import '../io/stl_loader.dart' show stlMetaOf;
import '../model/mesh_check.dart';
import 'gcode_ui.dart';
import '../model/print_summary.dart';
import '../model/stock_sim.dart';
import '../model/drawing_stats.dart';
import 'glass.dart';
import 'home_view.dart';
import 'layers_panel.dart';
import 'recents.dart';
import 'scene_panel.dart';
import '../model/shapes.dart';
import 'theme.dart';
import '../l10n/l10n.dart';
import '../model/unit_system.dart';

const _kAutoOpen = String.fromEnvironment('DATUM_OPEN');
// Solo para pruebas automáticas.
const _kShot = String.fromEnvironment('DATUM_SHOT');
const _kAutoSelect = String.fromEnvironment('DATUM_SELECT');
const _kAutoCad = String.fromEnvironment('DATUM_CAD');
const _kAutoPanel = bool.fromEnvironment('DATUM_PANEL');
const _kAutoSlider = String.fromEnvironment('DATUM_SLIDER');
const _kAutoColor = String.fromEnvironment('DATUM_COLOR');
const _kAutoStock = bool.fromEnvironment('DATUM_STOCK');
const _kAutoHide = String.fromEnvironment(
  'DATUM_HIDE',
); // "5,7": categorías de G-code a ocultar
const _kAutoMeasure = String.fromEnvironment(
  'DATUM_MEASURE',
); // "fx1,fy1,fx2,fy2" (fracciones de pantalla)
const _kHomeShot = bool.fromEnvironment('DATUM_HOME_SHOT');

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key});
  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  /// Diedro (host nativo) pide abrir un STEP: canal «diedro/visor», método «open» con la ruta.
  static const _host = MethodChannel('diedro/visor');
  final OrbitCamera cam = OrbitCamera();
  final GlobalKey _boundary = GlobalKey();
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();
  DatumRenderer? _renderer;
  Document? _doc;
  final Set<SceneNode> _selected = {};
  String? _error;
  List<Widget> _chips = const [];
  final Set<int> _hidden = {};
  bool _loading = false;
  String _loadingName = '';
  String? _loadingNote;
  bool _introPlayed = false;
  String? _shownName;
  ViewMode _mode = ViewMode.shaded;
  Size _viewport = Size.zero;

  // Trayectorias
  int _layerLo = 0, _layerHi = 1 << 30;
  double _layerFrac = 1.0;
  bool _playing = false;
  Timer? _playTimer;
  bool _showTravels = false;
  double _cncProg = 1.0;
  bool _showStock = false;
  StockSim? _sim;
  Scene? _stockScene;
  DatumRenderer? _renderer2;
  int _lastStockBuild = 0;

  /// Fija el avance del programa CNC y, si se ve el material, talla la pieza hasta ahí.
  void _setCncProg(double v) {
    _cncProg = v;
    if (_showStock) _refreshStock();
  }

  void _refreshStock() {
    final d = _doc;
    if (d is! ToolpathDocument) return;
    final t = d.toolpath;
    final sim = _sim ??= StockSim(t);
    sim.advanceTo((_cncProg * t.paths.segmentCount).round());
    // Durante la reproducción la malla se rehace como mucho unas 15 veces por segundo.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_playing && _stockScene != null && now - _lastStockBuild < 66) return;
    _lastStockBuild = now;
    _stockScene = sim.buildScene();
  }

  void _toggleStock() {
    final d = _doc;
    if (d is! ToolpathDocument) return;
    setState(() {
      _showStock = !_showStock;
      if (_showStock) {
        _renderer2 ??= _renderer?.clone();
        _refreshStock();
      } else {
        _stockScene = null;
      }
    });
  }

  /// Fracción de segmentos visibles hasta la capa superior (y su avance parcial).
  double get _progress {
    final d = _doc;
    if (d is! ToolpathDocument) return 1.0;
    final t = d.toolpath;
    if (!t.isFdm) return _cncProg;
    final total = t.paths.segmentCount;
    if (total == 0 || t.layerCount == 0) return 1.0;
    final hi = _layerHi.clamp(0, t.layerCount - 1);
    final a = t.layerFirstSeg[hi], b = t.layerFirstSeg[hi + 1];
    return (a + (b - a) * _layerFrac) / total;
  }

  void _setRange(int lo, int hi) {
    final d = _doc;
    if (d is! ToolpathDocument) return;
    _stopPlay();
    final n = d.toolpath.layerCount;
    setState(() {
      _layerLo = lo.clamp(0, n - 1);
      _layerHi = hi.clamp(_layerLo, n - 1);
      _layerFrac = 1;
    });
  }

  void _stopPlay() {
    _playTimer?.cancel();
    _playTimer = null;
    _interactingNow = false;
    if (_playing) setState(() => _playing = false);
  }

  void _togglePlay() {
    final d = _doc;
    if (d is! ToolpathDocument) return;
    if (_playing) return _stopPlay();
    final t = d.toolpath;
    if (!t.isFdm) {
      if (_cncProg >= 1) _setCncProg(0);
      _playTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
        final nx = _cncProg + 0.033 / 30;
        if (nx >= 1) {
          setState(() => _setCncProg(1));
          _stopPlay();
        } else {
          setState(() => _setCncProg(nx));
        }
      });
      _interactingNow = true;
      setState(() => _playing = true);
      return;
    }
    final n = t.layerCount;
    if (n == 0) return;
    if (_layerHi.clamp(0, n - 1) >= n - 1 && _layerFrac >= 1) {
      _layerHi = _layerLo;
      _layerFrac = 0;
    }
    // La impresión completa se reproduce en unos 30 s.
    final perTick = math.max(t.paths.segmentCount / 30 * 0.033, 40.0);
    _playTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      final hi = _layerHi.clamp(0, n - 1);
      var seg =
          t.layerFirstSeg[hi] +
          (t.layerFirstSeg[hi + 1] - t.layerFirstSeg[hi]) * _layerFrac +
          perTick;
      final total = t.paths.segmentCount;
      if (seg >= total) {
        setState(() {
          _layerHi = n - 1;
          _layerFrac = 1;
        });
        _stopPlay();
        return;
      }
      final l = t.layerOfSegment(seg.floor());
      final span = t.layerFirstSeg[l + 1] - t.layerFirstSeg[l];
      setState(() {
        _layerHi = l;
        _layerFrac = span == 0 ? 1 : (seg - t.layerFirstSeg[l]) / span;
      });
    });
    _interactingNow = true;
    setState(() => _playing = true);
  }

  // Medición 2D
  bool _measuring = false;
  bool _needsFit = false;
  CadController? _cad;
  DrawingController? _draw;
  CloudController? _cloud;
  StlController? _stl;
  ThreeMfController? _tmf;
  MeshFileController? _mesh;
  final List<vm.Vector2> _measure = [];
  List<Shape>? _shapes;
  Shape? _shape;
  int _repaint = 0;
  final ValueNotifier<int> _overlayTick = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    cam.addListener(() => _overlayTick.value++);
    Units.notifier.addListener(_onUnitsChanged);
    L.choice.addListener(_onUnitsChanged);
    _host.setMethodCallHandler((c) async {
      if (c.method == 'config') {
        // Idioma y unidades vienen de Diedro (no hay ajustes propios del visor).
        final a = c.arguments as List;
        L.apply(a[0] as String);
        for (final u in UnitSystem.values) {
          if (u.name == a[1]) Units.system = u;
        }
      }
      if (c.method == 'open') {
        final a = c.arguments;
        // Diedro envía [ruta, nombre real de la pieza]: la ruta es una copia temporal («in.step»).
        if (a is List) setState(() => _shownName = a[1] as String);
        await _open(a is List ? a[0] as String : a as String);
      }
      if (c.method == 'select') _selectParts(Set<int>.from(c.arguments as List));
      if (c.method == 'holeAt') _holeAt((c.arguments as List).map((e) => (e as num).toDouble()).toList());
    });
    DatumRenderer.instance()
        .then((r) {
          if (!mounted) return;
          setState(() => _renderer = r);
          if (_kAutoOpen.isNotEmpty) _open(_kAutoOpen);
          if (_kHomeShot) _maybeShot(delay: 3600);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = '$e');
        });
  }

  String? _openedPath;
  int? _openedPlate;

  /// Al cambiar de sistema de unidades se vuelve a abrir el archivo para rehacer los resúmenes (chips).
  void _onUnitsChanged() {
    if (!mounted) return;
    final p = _openedPath;
    if (_doc != null && p != null && !_loading) {
      _open(p, gcodePlate: _openedPlate);
    } else {
      setState(() {});
    }
  }

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles();
    final path = files.isEmpty ? null : files.first.path;
    if (path != null) await _open(path);
  }

  void _onDrawChanged() {
    if (mounted) {
      setState(() => _repaint++);
      _overlayTick.value++;
    }
  }

  void _onCloudChanged() {
    if (mounted) {
      setState(() => _repaint++);
      _overlayTick.value++;
      cam.touch();
    }
  }

  void _disposeCad() {
    _cloud?.removeListener(_onCloudChanged);
    _cloud?.dispose();
    _cloud = null;
    _mesh?.removeListener(_onTmfChanged);
    _mesh?.dispose();
    _mesh = null;
    _tmf?.removeListener(_onTmfChanged);
    _tmf?.dispose();
    _tmf = null;
    _stl?.removeListener(_onStlChanged);
    _stl?.dispose();
    _stl = null;
    _draw?.removeListener(_onDrawChanged);
    _playTimer?.cancel();
    _draw?.dispose();
    _draw = null;
    _cad?.removeListener(_onCadChanged);
    _cad?.dispose();
    final d = _doc;
    if (d is ModelDocument) d.scene.dispose();
    _cad = null;
  }

  void _onStlChanged() {
    _stl?.refreshOverlays();
    if (mounted) setState(() => _repaint++);
    cam.touch();
  }

  void _onTmfChanged() {
    if (mounted) setState(() => _repaint++);
    cam.touch();
  }

  void _onCadChanged() {
    if (mounted) setState(() => _repaint++);
  }

  void _closeDoc() {
    _disposeCad();
    setState(() {
      _doc = null;
      _error = null;
      _selected.clear();
      _measure.clear();
      _shapes = null;
      _shape = null;
      _measuring = false;
      _hidden.clear();
      _chips = const [];
      _openedPath = null;
    });
  }

  Future<void> _open(String path, {int? gcodePlate}) async {
    String? note;
    try {
      final mb = File(path).lengthSync() / 1e6;
      // Medido: STEP de 15 MB tarda 5 s en un Mac y 31 s en una tableta Android de gama media.
      final perMb = Platform.isAndroid ? 2.1 : 0.35;
      final isCad = RegExp(
        r'\.(step|stp|iges|igs|stpz)$',
        caseSensitive: false,
      ).hasMatch(path);
      final cached = isCad && cadCacheHit(path);
      final secs = (mb * (isCad ? perMb * (cached ? 0.27 : 1) : perMb * 0.05))
          .round();
      if (secs >= 8) {
        note =
            tr('Archivo grande ({mb} MB)\nPuede tardar unos {s} segundos{extra}', {
              'mb': mb.toStringAsFixed(0),
              's': secs,
              'extra': cached
                  ? tr('\n(ya se abrió antes: más rápido)')
                  : tr('\nLa próxima vez abrirá mucho antes'),
            });
      }
    } catch (_) {}
    setState(() {
      _loading = true;
      _loadingName = path.split('/').last;
      _loadingNote = note;
      _error = null;
    });
    try {
      final loadWatch = Stopwatch()..start();
      final doc = await loadDocument(path, gcodePlate: gcodePlate);
      _openedPath = path;
      _openedPlate = gcodePlate;
      if (_kAutoCad.isNotEmpty) {
        // ignore: avoid_print
        print('LOAD ${loadWatch.elapsedMilliseconds} ms');
      }
      // La primera vez aún no hay vista dibujada: se usa el tamaño de la pantalla.
      final screen = MediaQuery.of(context).size;
      cam.aspect = _viewport.height > 0
          ? _viewport.width / _viewport.height
          : (screen.height > 0 ? screen.width / screen.height : 0.5);
      // Si la ventana aún no tiene tamaño (Android al arrancar), se reencuadra al conocerlo.
      _needsFit = _viewport.height <= 0 && screen.height <= 0;
      _selected.clear();
      _measure.clear();
      _shapes = null;
      _shape = null;
      _measuring = false;
      _hidden.clear();
      final chips = <Widget>[];
      DrawingController? pendingDraw;
      CloudController? pendingCloud;
      switch (doc) {
        case ModelDocument d:
          cam
            ..ortho = false
            ..orbitEnabled = true;
          cam.setView(-0.785, 0.615);
          cam.fit(d.scene.bounds());
          final s = d.scene.bounds().size;
          if (_isAssembly(d)) {
            chips
              ..add(
                InfoChip(
                  Icons.view_in_ar_outlined,
                  tr('{n} piezas', {'n': d.scene.parts.length}),
                ),
              )
              ..add(
                InfoChip(
                  Icons.layers_outlined,
                  tr('{n} instancias', {'n': d.scene.instances(onlyVisible: false).length}),
                ),
              );
          }
          if (d.scene.cad != null) {
            final u = Units.forFile(LengthUnit.fromFile(d.scene.cad!.unit));
            final nPmi = d.scene.cad!.pmi
                .where((p) => p.kind != PmiKind.datum)
                .length;
            if (nPmi > 0) {
              chips.add(
                InfoChip(Icons.rule_rounded, tr('{n} cotas y tolerancias', {'n': nPmi})),
              );
            }
            chips.add(InfoChip(Icons.straighten, u.dims(s)));
          } else {
            chips
              ..add(
                InfoChip(
                  Icons.change_history,
                  _fmtCount(d.scene.triangleCount, tr('triángulos')),
                ),
              )
              ..add(
                InfoChip(
                  Icons.straighten,
                  '${_fmtSize(s[0])} × ${_fmtSize(s[1])} × ${_fmtSize(s[2])}',
                ),
              );
          }
        case DrawingDocument d:
          cam
            ..ortho = true
            ..orbitEnabled = false;
          cam.setView(-math.pi / 2, math.pi / 2 - 0.0005);
          cam.fit(d.lines.bounds);
          final s = d.lines.bounds.size;
          pendingDraw = DrawingController(d);
          final dc = pendingDraw!;
          chips.add(
            InfoChip(
              Icons.straighten,
              '${dc.len(s[0], digits: 1).replaceAll(' ${dc.displayUnit.symbol}', '')} × ${dc.len(s[1], digits: 1)}',
            ),
          );
          if (!dc.unitDeclared) {
            chips.add(
              InfoChip(
                Icons.help_outline_rounded,
                tr('unidad sin indicar'),
                color: DT.orangeSoft,
              ),
            );
          }
          final isPlot = d.info?.format.startsWith('HPGL') ?? false;
          if (isPlot) {
            chips.add(
              InfoChip(
                Icons.timeline,
                tr('dibujo {l}', {'l': Units.len(d.info!.drawMm)}),
              ),
            );
          }
          if (!isPlot && d.lines.segmentCount < 400000) {
            try {
              chips.add(InfoChip(Icons.content_cut_rounded, dc.summary));
              final ok = dc.readyToCut;
              chips.add(
                InfoChip(
                  ok
                      ? Icons.check_circle_outline_rounded
                      : Icons.warning_amber_rounded,
                  ok
                      ? tr('Listo para cortar')
                      : (dc.problems.length == 1
                            ? tr('1 aviso')
                            : tr('{n} avisos', {'n': dc.problems.length})),
                  color: ok ? DT.mint : DT.orangeSoft,
                ),
              );
            } catch (_) {}
          }
          final vi = d.info;
          if (vi != null) {
            chips.add(InfoChip(Icons.description_outlined, vectorBadge(vi)));
            if (vi.format.startsWith('HPGL') && vi.pens.isNotEmpty) {
              chips.add(
                InfoChip(
                  Icons.edit_outlined,
                  vi.pens.length == 1
                      ? tr('1 pluma')
                      : tr('{n} plumas', {'n': vi.pens.length}),
                ),
              );
            }
            if (vi.warnings.isNotEmpty) {
              chips.add(
                InfoChip(
                  Icons.info_outline_rounded,
                  vi.warnings.length == 1
                      ? tr('1 nota')
                      : tr('{n} notas', {'n': vi.warnings.length}),
                  color: DT.orangeSoft,
                ),
              );
            }
          }
        case ToolpathDocument d:
          cam
            ..ortho = false
            ..orbitEnabled = true;
          cam.setView(-0.785, 0.615);
          cam.fit(d.toolpath.fitBounds);
          _stopPlay();
          _layerLo = 0;
          _layerHi = 1 << 30;
          _layerFrac = 1.0;
          _cncProg = 1.0;
          _showStock = false;
          _sim = null;
          _stockScene = null;
          _showTravels = false;
          final t = d.toolpath;
          final sum = t.summary;
          final cnc = t.stats.cnc;
          if (cnc != null) {
            final e = [
              for (var q = 0; q < 3; q++) cnc.envMax[q] - cnc.envMin[q],
            ];
            chips.add(
              InfoChip(
                Icons.straighten,
                Units.dimsPlain(e, d: 0),
              ),
            );
            if (sum.seconds != null) {
              chips.add(
                InfoChip(Icons.schedule, '≈ ${formatDuration(sum.seconds!)}'),
              );
            }
            final nt = {for (final c in cnc.tools) c.number}.length;
            if (nt > 0) {
              chips.add(
                InfoChip(
                  Icons.build_outlined,
                  nt == 1 ? tr('1 herramienta') : tr('{n} herramientas', {'n': nt}),
                ),
              );
            }
            if (cnc.rapidPlunges > 0 || cnc.noSpindle || cnc.usesFlow) {
              chips.add(
                InfoChip(
                  Icons.warning_amber_rounded,
                  tr('Avisos'),
                  color: DT.orangeSoft,
                ),
              );
            }
          } else {
            chips.add(InfoChip(Icons.layers_outlined, tr('{n} capas', {'n': t.layerCount})));
            if (sum.seconds != null) {
              chips.add(
                InfoChip(
                  Icons.schedule,
                  (sum.secondsFromSlicer ? '' : '≈ ') +
                      formatDuration(sum.seconds!),
                ),
              );
            }
            if (sum.filaments.isNotEmpty) {
              chips.add(
                InfoChip(
                  Icons.scale_outlined,
                  Units.grams(sum.totalGrams, d: sum.totalGrams < 10 ? 1 : 0),
                ),
              );
            }
          }
        case PointCloudDocument d:
          cam
            ..ortho = false
            ..orbitEnabled = true;
          cam.setView(-0.785, 0.615);
          cam.fit(d.cloud.bounds);
          pendingCloud = CloudController(d.cloud);
          final ci = d.cloud.info;
          final cu = Units.cloudLabel(ci);
          final ck = Units.cloudFactor(ci);
          final ce = ci.minAbs != null && ci.maxAbs != null
              ? [for (var k = 0; k < 3; k++) ci.maxAbs![k] - ci.minAbs![k]]
              : d.cloud.bounds.size;
          chips
            ..add(
              InfoChip(
                Icons.grain,
                ci.sampled
                    ? tr('{a} de {b}', {
                        'a': _fmtCount(d.cloud.totalLoaded, tr('puntos')),
                        'b': _fmtCount(ci.totalPoints, tr('puntos')),
                      })
                    : _fmtCount(d.cloud.count, tr('puntos')),
              ),
            )
            ..add(
              InfoChip(
                Icons.straighten,
                '${_fmtSize(ce[0] * ck)} × ${_fmtSize(ce[1] * ck)} × ${_fmtSize(ce[2] * ck)}$cu',
              ),
            )
            ..add(InfoChip(Icons.description_outlined, ci.format));
          if (ci.crs != null) {
            chips.add(InfoChip(Icons.public, ci.crs!.length > 28 ? '${ci.crs!.substring(0, 27)}…' : ci.crs!));
          }
          if (ci.warnings.isNotEmpty) {
            chips.add(
              InfoChip(
                Icons.info_outline_rounded,
                ci.warnings.length == 1
                    ? tr('1 nota')
                    : tr('{n} notas', {'n': ci.warnings.length}),
                color: DT.orangeSoft,
              ),
            );
          }
      }
      _disposeCad();
      _draw = pendingDraw?..addListener(_onDrawChanged);
      _cloud = pendingCloud?..addListener(_onCloudChanged);
      if (doc is ModelDocument && doc.scene.cad != null) {
        _cad = CadController(doc.scene)..addListener(_onCadChanged);
      } else if (doc is ModelDocument &&
          doc.scene.parts.length == 1 &&
          path.toLowerCase().endsWith('.stl')) {
        final mesh = doc.scene.parts.first.mesh;
        _stl = StlController(mesh, stlMetaOf[mesh], doc.name)
          ..addListener(_onStlChanged)
          ..run();
      }
      if (doc is ModelDocument && _stl == null && _cad == null) {
        final pr = threeMfOf[doc.scene];
        if (pr != null) {
          _tmf = ThreeMfController(doc.scene, pr, path)
            ..addListener(_onTmfChanged);
          cam.fit(_tmf!.viewBounds());
        }
      }
      if (doc is ModelDocument && _stl == null && _cad == null && _tmf == null) {
        final mi = meshInfoOf[doc.scene];
        if (mi != null) {
          _mesh = MeshFileController(doc.scene, mi, path)
            ..addListener(_onTmfChanged);
          cam.fit(doc.scene.bounds());
        }
      }
      setState(() {
        _doc = doc;
        _chips = chips;
      });
      RecentsStore.add(path);
      if (_kAutoSelect.isNotEmpty && doc is ModelDocument)
        _autoSelect(doc.scene);
      if (_kAutoSlider.isNotEmpty && doc is ToolpathDocument) {
        // «alto» o «bajo,alto» como fracción de capas
        final v = _kAutoSlider.split(',').map(double.parse).toList();
        final n = doc.toolpath.layerCount;
        setState(() {
          if (v.length == 2) _layerLo = (v[0] * (n - 1)).round();
          _layerHi = (v.last * (n - 1)).round();
        });
      }
      if (doc is ToolpathDocument && !doc.toolpath.isFdm) {
        final sim = _sim ??= StockSim(doc.toolpath);
        // El material se ve por defecto si el programa realmente talla (no es grabado plano).
        if (_kAutoStock ||
            sim.depth > 0.2 && doc.toolpath.paths.segmentCount < 150000) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_showStock) _toggleStock();
          });
        }
      }
      if (_kAutoColor.isNotEmpty && doc is ToolpathDocument) {
        _setColorMode(
          ToolpathColorMode.values.firstWhere((m) => m.name == _kAutoColor),
        );
      }
      if (_kAutoHide.isNotEmpty && doc is ToolpathDocument) {
        _setHidden({for (final s in _kAutoHide.split(',')) int.parse(s)});
      }
      if (_kAutoMeasure.isNotEmpty && doc is DrawingDocument) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final f = _kAutoMeasure.split(',').map(double.parse).toList();
          setState(() => _measuring = true);
          _tapMeasure(
            Offset(f[0] * _viewport.width, f[1] * _viewport.height),
            doc,
          );
          _tapMeasure(
            Offset(f[2] * _viewport.width, f[3] * _viewport.height),
            doc,
          );
        });
      }
      if (_kAutoCad.isNotEmpty && _cloud != null) {
        // Pruebas de nubes: v (vista) · i (archivo) · mode:n · size:n · cls:n (oculta clase) · clip:a,b · m:x,y,x,y (medir)
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final c = _cloud!;
          for (final cmd in _kAutoCad.split(';')) {
            await Future<void>.delayed(const Duration(milliseconds: 600));
            if (!mounted) return;
            if (cmd == 'v') {
              showCloudViewSheet(context, c);
            } else if (cmd == 'i') {
              showCloudInfoSheet(context, c.cloud);
            } else if (cmd == 'perf' || cmd == 'perfstill') {
              final times = <ui.FrameTiming>[];
              void cb(List<ui.FrameTiming> t) => times.addAll(t);
              WidgetsBinding.instance.addTimingsCallback(cb);
              _interactingNow = cmd == 'perf';
              for (var k = 0; k < 120; k++) {
                cam.orbit(4, 0);
                await WidgetsBinding.instance.endOfFrame;
              }
              _interactingNow = false;
              WidgetsBinding.instance.removeTimingsCallback(cb);
              if (times.isNotEmpty) {
                double avg(Duration Function(ui.FrameTiming) f) =>
                    times.map((t) => f(t).inMicroseconds).reduce((a, b) => a + b) / times.length / 1000;
                // ignore: avoid_print
                print(
                  'PERF fotogramas=${times.length} construcción=${avg((t) => t.buildDuration).toStringAsFixed(1)} ms '
                  'raster=${avg((t) => t.rasterDuration).toStringAsFixed(1)} ms total=${avg((t) => t.totalSpan).toStringAsFixed(1)} ms',
                );
              }
            } else if (cmd.startsWith('mode:')) {
              final modes = c.cloud.availableModes;
              c.cloud.recolor(modes[int.parse(cmd.substring(5)) % modes.length]);
              c.changed();
            } else if (cmd.startsWith('size:')) {
              c.cloud.pointSize = double.parse(cmd.substring(5));
              c.changed();
            } else if (cmd.startsWith('cls:')) {
              c.cloud.toggleClass(int.parse(cmd.substring(4)));
              c.changed();
            } else if (cmd.startsWith('clip:')) {
              final f = cmd.substring(5).split(',').map(double.parse).toList();
              final b = c.cloud.bounds;
              final span = b.max[2] - b.min[2];
              c.cloud.setClip(b.min[2] + span * f[0], b.min[2] + span * f[1]);
              c.changed();
            } else if (cmd.startsWith('m:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              c.toggleMeasure();
              c.tap(cam, Offset(f[0] * _viewport.width, f[1] * _viewport.height), _viewport);
              c.tap(cam, Offset(f[2] * _viewport.width, f[3] * _viewport.height), _viewport);
            }
          }
        });
      }
      if (_kAutoCad.isNotEmpty && _draw != null) {
        // Pruebas de dibujo: c (datos de corte) · r (revisión) · f (relleno) · p:n (ver aviso n)
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final d = _draw!;
          for (final cmd in _kAutoCad.split(';')) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            if (!mounted) return;
            if (cmd == 'c') {
              showCutSheet(context, d);
            } else if (cmd == 'r') {
              showReviewSheet(context, d, onShow: d.show);
            } else if (cmd == 'v') {
              showVectorSheet(context, d.doc);
            } else if (cmd == 'f') {
              d.toggleFill();
            } else if (cmd.startsWith('p:')) {
              d.show(d.problems[int.parse(cmd.substring(2))]);
            } else if (cmd == 'twist') {
              // Simula dos dedos que giran 30° y se separan: comprueba la tubería real de gestos.
              final view =
                  WidgetsBinding.instance.platformDispatcher.implicitView!;
              final id = view.viewId;
              final c = Offset(_viewport.width / 2, _viewport.height / 2);
              final yaw0 = cam.yaw, dist0 = cam.distance;
              Offset at(double ang, double r, int k) =>
                  c +
                  Offset(
                        math.cos(ang + k * math.pi),
                        math.sin(ang + k * math.pi),
                      ) *
                      r;
              final b = GestureBinding.instance;
              b.handlePointerEvent(
                PointerDownEvent(
                  viewId: id,
                  pointer: 11,
                  position: at(0, 80, 0),
                ),
              );
              b.handlePointerEvent(
                PointerDownEvent(
                  viewId: id,
                  pointer: 12,
                  position: at(0, 80, 1),
                ),
              );
              for (var k = 1; k <= 20; k++) {
                final ang = k / 20 * (math.pi / 6), r = 80 + k * 6.0;
                final a = at(ang, r, 0), z = at(ang, r, 1);
                b.handlePointerEvent(
                  PointerMoveEvent(
                    viewId: id,
                    pointer: 11,
                    position: a,
                    delta: const Offset(1, 1),
                  ),
                );
                b.handlePointerEvent(
                  PointerMoveEvent(
                    viewId: id,
                    pointer: 12,
                    position: z,
                    delta: const Offset(-1, -1),
                  ),
                );
                await WidgetsBinding.instance.endOfFrame;
              }
              b.handlePointerEvent(
                PointerUpEvent(
                  viewId: id,
                  pointer: 11,
                  position: at(math.pi / 6, 200, 0),
                ),
              );
              b.handlePointerEvent(
                PointerUpEvent(
                  viewId: id,
                  pointer: 12,
                  position: at(math.pi / 6, 200, 1),
                ),
              );
              await WidgetsBinding.instance.endOfFrame;
              // ignore: avoid_print
              print(
                'TWIST giro ${((cam.yaw - yaw0) * 180 / math.pi).toStringAsFixed(1)}° · zoom ×${(dist0 / cam.distance).toStringAsFixed(2)}',
              );
            } else if (cmd == 'perf') {
              final times = <ui.FrameTiming>[];
              void cb(List<ui.FrameTiming> t) => times.addAll(t);
              WidgetsBinding.instance.addTimingsCallback(cb);
              _interactingNow = true;
              for (var k = 0; k < 120; k++) {
                cam.pan(k.isEven ? 6 : -6, 0, _viewport.height);
                await WidgetsBinding.instance.endOfFrame;
              }
              _interactingNow = false;
              WidgetsBinding.instance.removeTimingsCallback(cb);
              if (times.isNotEmpty) {
                double avg(Duration Function(ui.FrameTiming) f) =>
                    times
                        .map((t) => f(t).inMicroseconds)
                        .reduce((a, b) => a + b) /
                    times.length /
                    1000;
                // ignore: avoid_print
                print(
                  'PERF fotogramas=${times.length} construcción=${avg((t) => t.buildDuration).toStringAsFixed(1)} ms raster=${avg((t) => t.rasterDuration).toStringAsFixed(1)} ms',
                );
              }
            }
          }
        });
      }
      if (_kAutoCad.isNotEmpty && _stl != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final c = _stl!;
          for (final cmd in _kAutoCad.split(';')) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            if (cmd == 'review') {
              while (c.report == null && c.checking) {
                await Future<void>.delayed(const Duration(milliseconds: 200));
              }
              if (mounted) showMeshReviewSheet(context, c, onHole: _focusHole);
            } else if (cmd == 'print') {
              while (c.report == null && c.checking) {
                await Future<void>.delayed(const Duration(milliseconds: 200));
              }
              if (mounted) showPrintSheet(context, c);
            } else if (cmd == 'thick') {
              await c.toggleThickness();
            } else if (cmd == 'overhang') {
              c.toggleOverhang();
            } else if (cmd == 'bed') {
              c.showBed = true;
              c.refresh();
            } else if (cmd == 'defects') {
              while (c.report == null && c.checking) {
                await Future<void>.delayed(const Duration(milliseconds: 200));
              }
              c.showDefects = true;
              c.showNonManifold = true;
              c.showInconsistent = true;
              c.refresh();
            } else if (cmd == 'perf') {
              while (c.report == null && c.checking) {
                await Future<void>.delayed(const Duration(milliseconds: 200));
              }
              // ignore: avoid_print
              print(
                'REVIEW ${c.report?.milliseconds} ms · ${c.report?.triangles} triángulos',
              );
              final times = <ui.FrameTiming>[];
              void cb(List<ui.FrameTiming> t) => times.addAll(t);
              WidgetsBinding.instance.addTimingsCallback(cb);
              _interactingNow = true;
              for (var k = 0; k < 120; k++) {
                cam.orbit(4, 0);
                await WidgetsBinding.instance.endOfFrame;
              }
              _interactingNow = false;
              WidgetsBinding.instance.removeTimingsCallback(cb);
              if (times.isNotEmpty) {
                double avg(Duration Function(ui.FrameTiming) f) =>
                    times
                        .map((t) => f(t).inMicroseconds)
                        .reduce((a, b) => a + b) /
                    times.length /
                    1000;
                // ignore: avoid_print
                print(
                  'PERF fotogramas=${times.length} construcción=${avg((t) => t.buildDuration).toStringAsFixed(1)} ms '
                  'raster=${avg((t) => t.rasterDuration).toStringAsFixed(1)} ms total=${avg((t) => t.totalSpan).toStringAsFixed(1)} ms',
                );
              }
            } else if (cmd.startsWith('v:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              cam.setView(f[0], f[1]);
            } else if (cmd.startsWith('s:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              c.setSection(f[0].round(), t: f[1]);
            } else if (cmd.startsWith('m:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              c.measuring = true;
              final m = (_doc as ModelDocument).scene;
              for (var k = 0; k + 1 < f.length; k += 2) {
                final hit = pickHit(
                  m,
                  cam,
                  f[k] * _viewport.width,
                  f[k + 1] * _viewport.height,
                  _viewport.width,
                  _viewport.height,
                );
                if (hit != null) c.addPoint(hit.world);
              }
            }
          }
        });
      }
      if (_kAutoCad.isNotEmpty && _mesh != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final c = _mesh!;
          for (final cmd in _kAutoCad.split(';')) {
            await Future<void>.delayed(const Duration(milliseconds: 700));
            if (!mounted) return;
            if (cmd == 'info') {
              showMeshInfoSheet(context, c, onAddFiles: () async {});
            } else if (cmd == 'parts') {
              showMeshPartsSheet(context, c, onFocus: (b) => cam.fit(b));
            } else if (cmd == 'review') {
              await c.review();
            } else if (cmd.startsWith('s:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              c.setSection(f[0].round(), t: f[1]);
            } else if (cmd.startsWith('view:')) {
              applyFileView(cam, c, c.info.views[int.parse(cmd.substring(5)) % c.info.views.length]);
            } else if (cmd == 'views') {
              showMeshViewsSheet(context, c, cam);
            } else if (cmd.startsWith('variant:')) {
              c.selectVariant(int.parse(cmd.substring(8)));
            } else if (cmd == 'fit') {
              cam.fit(c.scene.bounds());
            } else if (cmd == 'plain') {
              c.toggleTextures();
            } else if (cmd.startsWith('anim:')) {
              final f = cmd.substring(5).split(',');
              final p = c.player;
              if (p != null) {
                p.select(int.parse(f[0]));
                p.seek(double.parse(f[1]));
              }
            } else if (cmd == 'play') {
              c.player?.play();
            } else if (cmd.startsWith('up:')) {
              c.setUp(cmd.substring(3));
              cam.fit(c.scene.bounds());
            } else if (cmd.startsWith('v:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              cam.setView(f[0], f[1]);
            } else if (cmd.startsWith('m:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              c.measuring = true;
              final m = (_doc as ModelDocument).scene;
              for (var k = 0; k + 1 < f.length; k += 2) {
                final hit = pickHit(m, cam, f[k] * _viewport.width, f[k + 1] * _viewport.height, _viewport.width, _viewport.height);
                if (hit != null) c.addPoint(hit.world);
              }
            } else if (cmd == 'perf') {
              if (c.scene.triangleCount > 400000) {
                for (var w = 0; w < 150 && c.lodScene == null; w++) {
                  await Future<void>.delayed(const Duration(milliseconds: 200));
                }
              }
              // ignore: avoid_print
              print('LOD ${c.lodScene != null ? 'listo' : 'no'}');
              final times = <ui.FrameTiming>[];
              void cb(List<ui.FrameTiming> t) => times.addAll(t);
              WidgetsBinding.instance.addTimingsCallback(cb);
              _interactingNow = true;
              for (var k = 0; k < 120; k++) {
                cam.orbit(4, 0);
                await WidgetsBinding.instance.endOfFrame;
              }
              _interactingNow = false;
              WidgetsBinding.instance.removeTimingsCallback(cb);
              if (times.isNotEmpty) {
                final tot =
                    times.map((t) => t.totalSpan.inMicroseconds).reduce((a, b) => a + b) /
                    times.length /
                    1000;
                // ignore: avoid_print
                print('PERF fotogramas=${times.length} total=${tot.toStringAsFixed(1)} ms');
              }
            }
          }
        });
      }
      if (_kAutoCad.isNotEmpty && _tmf != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final c = _tmf!;
          for (final cmd in _kAutoCad.split(';')) {
            await Future<void>.delayed(const Duration(milliseconds: 700));
            if (!mounted) return;
            if (cmd.startsWith('plate:')) {
              c.selectPlate(int.parse(cmd.substring(6)));
              cam.fit(c.viewBounds());
            } else if (cmd == 'parts') {
              showTmfPartsSheet(context, c, onFocus: (b) => cam.fit(b));
            } else if (cmd == 'filaments') {
              showTmfFilamentsSheet(
                context,
                c,
                onToolpath: (n) => _open(c.path, gcodePlate: n),
              );
            } else if (cmd.startsWith('s:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              c.setSection(f[0].round(), t: f[1]);
            } else if (cmd == 'project') {
              showTmfProjectSheet(context, c);
            } else if (cmd.startsWith('m:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              c.measuring = true;
              final m = (_doc as ModelDocument).scene;
              for (var k = 0; k + 1 < f.length; k += 2) {
                final hit = pickHit(m, cam, f[k] * _viewport.width, f[k + 1] * _viewport.height, _viewport.width, _viewport.height);
                if (hit != null) c.addPoint(hit.world);
              }
            } else if (cmd == 'aux') {
              c.toggleAux();
            } else if (cmd.startsWith('toolpath:')) {
              _open(c.path, gcodePlate: int.parse(cmd.substring(9)));
              return;
            } else if (cmd.startsWith('tap:')) {
              final f = cmd.substring(4).split(',').map(double.parse).toList();
              final hit = pickHit(
                (_doc as ModelDocument).scene,
                cam,
                f[0] * _viewport.width,
                f[1] * _viewport.height,
                _viewport.width,
                _viewport.height,
              );
              if (hit != null) setState(() => _selected..clear()..add(hit.instance.node));
            } else if (cmd.startsWith('hide:')) {
              c.toggleSlot(int.parse(cmd.substring(5)));
            } else if (cmd.startsWith('iso:')) {
              c.isolate(int.parse(cmd.substring(4)));
              cam.fit(c.viewBounds());
            } else if (cmd.startsWith('v:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              cam.setView(f[0], f[1]);
            } else if (cmd == 'perf') {
              for (var w = 0; w < 100 && c.lodScene == null; w++) {
                await Future<void>.delayed(const Duration(milliseconds: 200));
              }
              // ignore: avoid_print
              print('LOD ${c.lodScene != null ? 'listo' : 'no'}');
              final times = <ui.FrameTiming>[];
              void cb(List<ui.FrameTiming> t) => times.addAll(t);
              WidgetsBinding.instance.addTimingsCallback(cb);
              _interactingNow = true;
              for (var k = 0; k < 120; k++) {
                cam.orbit(4, 0);
                await WidgetsBinding.instance.endOfFrame;
              }
              _interactingNow = false;
              WidgetsBinding.instance.removeTimingsCallback(cb);
              if (times.isNotEmpty) {
                final tot =
                    times
                        .map((t) => t.totalSpan.inMicroseconds)
                        .reduce((a, b) => a + b) /
                    times.length /
                    1000;
                // ignore: avoid_print
                print('PERF fotogramas=${times.length} total=${tot.toStringAsFixed(1)} ms');
              }
            }
          }
        });
      }
      if (_kAutoCad == 'stockplay' && doc is ToolpathDocument) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 2500));
          final times = <ui.FrameTiming>[];
          void cb(List<ui.FrameTiming> t) => times.addAll(t);
          WidgetsBinding.instance.addTimingsCallback(cb);
          final sw = Stopwatch()..start();
          var worst = 0;
          for (var k = 1; k <= 90; k++) {
            final one = Stopwatch()..start();
            setState(() => _setCncProg(k / 90));
            worst = math.max(worst, one.elapsedMilliseconds);
            await WidgetsBinding.instance.endOfFrame;
          }
          WidgetsBinding.instance.removeTimingsCallback(cb);
          // ignore: avoid_print
          print(
            'STOCKPLAY 90 pasos en ${sw.elapsedMilliseconds} ms · simulación+malla máx ${worst} ms · '
            'fotogramas ${times.length} · raster ${(times.map((t) => t.rasterDuration.inMicroseconds).reduce((a, b) => a + b) / times.length / 1000).toStringAsFixed(1)} ms',
          );
        });
      }
      if (_kAutoCad == 'perf' && doc is ToolpathDocument) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          final times = <ui.FrameTiming>[];
          void cb(List<ui.FrameTiming> t) => times.addAll(t);
          WidgetsBinding.instance.addTimingsCallback(cb);
          _interactingNow = true;
          for (var k = 0; k < 120; k++) {
            cam.orbit(4, 0);
            await WidgetsBinding.instance.endOfFrame;
          }
          _interactingNow = false;
          WidgetsBinding.instance.removeTimingsCallback(cb);
          if (times.isNotEmpty) {
            double avg(Duration Function(ui.FrameTiming) f) =>
                times.map((t) => f(t).inMicroseconds).reduce((a, b) => a + b) /
                times.length /
                1000;
            // ignore: avoid_print
            print(
              'PERF fotogramas=${times.length} construcción=${avg((t) => t.buildDuration).toStringAsFixed(1)} ms '
              'raster=${avg((t) => t.rasterDuration).toStringAsFixed(1)} ms '
              'total=${avg((t) => t.totalSpan).toStringAsFixed(1)} ms',
            );
          }
        });
      }
      if (_kAutoCad.isNotEmpty && _cad != null) {
        // Pruebas: m:x,y (medir) · s:eje,t[,1] (sección) · e:valor (explosión) · o (ortográfica) · a (atenuar)
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final c = _cad!;
          for (final cmd in _kAutoCad.split(';')) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            if (cmd.startsWith('m:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              c.measuring = true;
              c.tapMeasure(
                cam,
                Offset(f[0] * _viewport.width, f[1] * _viewport.height),
                _viewport,
              );
            } else if (cmd.startsWith('s:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              c.setSection(
                f[0].round(),
                t: f[1],
                flip: f.length > 2 && f[2] > 0,
              );
            } else if (cmd.startsWith('e:')) {
              c.setExplode(double.parse(cmd.substring(2)));
            } else if (cmd == 'o') {
              cam.ortho = !cam.ortho;
              _focusSelection();
            } else if (cmd == 'a') {
              c.toggleGhost();
            } else if (cmd == 'p') {
              // Rendimiento: gira la cámara durante 120 fotogramas y mide.
              c.options.interacting = true;
              _interactingNow = true;
              final times = <ui.FrameTiming>[];
              void cb(List<ui.FrameTiming> t) => times.addAll(t);
              WidgetsBinding.instance.addTimingsCallback(cb);
              for (var k = 0; k < 120; k++) {
                cam.orbit(4, 0);
                await WidgetsBinding.instance.endOfFrame;
              }
              WidgetsBinding.instance.removeTimingsCallback(cb);
              c.options.interacting = false;
              _interactingNow = false;
              if (times.isNotEmpty) {
                double avg(Duration Function(ui.FrameTiming) f) =>
                    times
                        .map((t) => f(t).inMicroseconds)
                        .reduce((a, b) => a + b) /
                    times.length /
                    1000;
                // ignore: avoid_print
                print(
                  'PERF fotogramas=${times.length} construcción=${avg((t) => t.buildDuration).toStringAsFixed(1)} ms '
                  'raster=${avg((t) => t.rasterDuration).toStringAsFixed(1)} ms '
                  'total=${avg((t) => t.totalSpan).toStringAsFixed(1)} ms',
                );
              }
            } else if (cmd.startsWith('x:')) {
              // Pruebas: x:n elige la anotación n; x:all las dibuja todas.
              if (cmd == 'x:all') {
                c.toggleAllPmi();
              } else {
                c.selectPmi(c.pmi[int.parse(cmd.substring(2))]);
              }
            } else if (cmd == 'i') {
              if (mounted) showInfoSheet(context, c, _selected);
            } else if (cmd == 'h') {
              if (mounted) {
                showHolesSheet(
                  context,
                  c,
                  onPick: (e) {
                    c.measuring = true;
                    c.picks
                      ..clear()
                      ..add(e);
                    c.changed();
                  },
                );
              }
            } else if (cmd.startsWith('v:')) {
              final f = cmd.substring(2).split(',').map(double.parse).toList();
              _standardView(f[0], f[1]);
            }
          }
        });
      }
      if (_kAutoPanel) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _scaffold.currentState?.openEndDrawer(),
        );
      }
      if (_kShot.isNotEmpty && !_kHomeShot) _maybeShot();
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _fmtCount(int n, [String unit = '']) {
    final u = unit.isEmpty ? '' : ' $unit';
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(2)} M$u';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)} k$u';
    return '$n$u';
  }

  static String _fmtSize(double v) =>
      v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  void _autoSelect(Scene scene) {
    final q = _kAutoSelect.toLowerCase();
    void walk(SceneNode n) {
      if (n.name.toLowerCase().contains(q)) _selected.add(n);
      n.children.forEach(walk);
    }

    walk(scene.root);
    setState(() {});
  }

  Future<void> _maybeShot({int delay = 2500}) async {
    await Future<void>.delayed(Duration(milliseconds: delay));
    final b =
        _boundary.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (b == null) return;
    final img = await b.toImage(pixelRatio: 1);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data != null) File(_kShot).writeAsBytesSync(data.buffer.asUint8List());
    exit(0);
  }

  void _setColorMode(ToolpathColorMode m) {
    final d = _doc;
    if (d is! ToolpathDocument) return;
    d.toolpath.recolor(m);
    setState(() => _repaint++);
    cam.touch();
  }

  void _setHidden(Set<int> hidden) {
    final d = _doc;
    if (d is! ToolpathDocument) return;
    setState(() {
      _hidden
        ..clear()
        ..addAll(hidden);
      d.toolpath.applyFilter(_hidden);
      _repaint++;
    });
    cam.fit(d.toolpath.fitBounds);
  }

  // ---- Gestos: 1 dedo gira (o desplaza en 2D), 2 dedos desplazan y hacen zoom.
  Offset _lastFocal = Offset.zero;
  double _lastScale = 1;
  void _onScaleEnd(ScaleEndDetails d) {
    if (_doc is DrawingDocument) {
      // Si queda casi recto (a menos de 6°), se endereza al múltiplo de 90° más cercano.
      const q = math.pi / 2;
      final k = (cam.yaw / q).round();
      if ((cam.yaw - k * q).abs() < 0.105) cam.setView(k * q, cam.pitch);
    }
    if (_interactingNow) {
      _interactingNow = false;
      cam.touch();
    }
    final c = _cad;
    if (c != null && c.options.interacting) {
      c.options.interacting = false;
      cam.touch();
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _interactingNow = true;
    _cad?.options.interacting = true;
    _lastRot = 0;
    _lastFocal = d.focalPoint;
    _lastScale = 1;
  }

  double _lastRot = 0;

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final delta = d.focalPoint - _lastFocal;
    _lastFocal = d.focalPoint;
    if (d.pointerCount >= 2 && _doc is DrawingDocument) {
      // Giro con dos dedos: el dibujo gira como el papel bajo los dedos.
      final dr = d.rotation - _lastRot;
      _lastRot = d.rotation;
      if (dr != 0) cam.setView(cam.yaw + dr, cam.pitch);
    }
    if (d.pointerCount >= 2 || !cam.orbitEnabled) {
      cam.pan(delta.dx, delta.dy, _viewport.height);
      final f = d.scale / _lastScale;
      _lastScale = d.scale;
      if (f != 1 && d.pointerCount >= 2) cam.zoom(f);
    } else {
      cam.orbit(delta.dx, delta.dy);
    }
  }

  void _onTap(TapUpDetails d) {
    final doc = _doc;
    if (doc == null || _viewport.isEmpty) return;
    switch (doc) {
      case ModelDocument m:
        if (_stl?.measuring == true) {
          final hit = pickHit(
            m.scene,
            cam,
            d.localPosition.dx,
            d.localPosition.dy,
            _viewport.width,
            _viewport.height,
          );
          if (hit != null) _stl!.addPoint(hit.world);
          return;
        }
        if (_mesh?.measuring == true) {
          final hit = pickHit(
            m.scene,
            cam,
            d.localPosition.dx,
            d.localPosition.dy,
            _viewport.width,
            _viewport.height,
          );
          if (hit != null) _mesh!.addPoint(hit.world);
          return;
        }
        if (_tmf?.measuring == true) {
          final hit = pickHit(
            m.scene,
            cam,
            d.localPosition.dx,
            d.localPosition.dy,
            _viewport.width,
            _viewport.height,
          );
          if (hit != null) _tmf!.addPoint(hit.world);
          return;
        }
        if (_cad?.measuring == true) {
          _cad!.tapMeasure(cam, d.localPosition, _viewport);
          return;
        }
        final hit = pickNode(
          m.scene,
          cam,
          d.localPosition.dx,
          d.localPosition.dy,
          _viewport.width,
          _viewport.height,
          explode: _cad?.options.explode ?? 0,
        );
        setState(() {
          _selected.clear();
          if (hit != null) _selected.add(hit);
        });
      case DrawingDocument m:
        if (_measuring) _tapMeasure(d.localPosition, m);
      case ToolpathDocument m:
        if (!m.toolpath.isFdm) _pickSegment(m.toolpath, d.localPosition);
      case PointCloudDocument():
        if (_cloud?.measuring == true) _cloud!.tap(cam, d.localPosition, _viewport);
    }
  }

  /// CNC: tocar el recorrido lleva la simulación a ese punto y muestra su línea de código.
  void _pickSegment(Toolpath t, Offset p) {
    final v = t.paths.vertices;
    final n = t.paths.segmentCount;
    if (n == 0) return;
    final w = _viewport.width, h = _viewport.height;
    final m = cam.projection(w / h) * cam.viewMatrix();
    final step = math.max(1, n ~/ 120000);
    var best = -1;
    var bestD = 28.0; // px
    Offset? proj(int o) {
      final c = m * vm.Vector4(v[o], v[o + 1], v[o + 2], 1);
      if (c.w <= 1e-6) return null;
      return Offset(
        (c.x / c.w * 0.5 + 0.5) * w,
        (1 - (c.y / c.w * 0.5 + 0.5)) * h,
      );
    }

    for (var i = 0; i < n; i += step) {
      final a = proj(i * 12), b = proj(i * 12 + 6);
      if (a == null || b == null) continue;
      final ab = b - a;
      final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
      final u = l2 == 0
          ? 0.0
          : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / l2).clamp(0.0, 1.0);
      final d = (p - (a + ab * u)).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best < 0) return;
    _stopPlay();
    setState(() => _setCncProg((best + 1) / n));
  }

  /// Punto del plano Z=0 bajo un píxel.
  vm.Vector2 _unproject(Offset p) {
    final inv =
        (cam.projection(_viewport.width / _viewport.height) * cam.viewMatrix())
          ..invert();
    final nx = 2 * p.dx / _viewport.width - 1,
        ny = 1 - 2 * p.dy / _viewport.height;
    final a = vm.Vector4(nx, ny, 0, 1)..applyMatrix4(inv);
    final b = vm.Vector4(nx, ny, 1, 1)..applyMatrix4(inv);
    final o = vm.Vector3(a.x / a.w, a.y / a.w, a.z / a.w);
    final e = vm.Vector3(b.x / b.w, b.y / b.w, b.z / b.w);
    final dz = e.z - o.z;
    final t = dz.abs() < 1e-12 ? 0.0 : -o.z / dz;
    return vm.Vector2(o.x + (e.x - o.x) * t, o.y + (e.y - o.y) * t);
  }

  void _tapMeasure(Offset screen, DrawingDocument doc) {
    final p = _unproject(screen);
    final shapes = _draw?.shapes ?? (_shapes ??= buildShapes(doc.lines));
    final pxToWorld =
        2 * cam.distance * math.tan(cam.fovY / 2) / _viewport.height;
    bool shown(Shape sh) =>
        doc.lines.groups.isEmpty ? true : doc.lines.groups[sh.group].visible;

    // 1) Punto notable cercano: extremos, esquinas, puntos medios, centros.
    final rs = 9 * pxToWorld;
    double best = rs * rs;
    vm.Vector2? snap;
    for (final sh in shapes) {
      if (!shown(sh) ||
          p.x < sh.minX - rs ||
          p.x > sh.maxX + rs ||
          p.y < sh.minY - rs ||
          p.y > sh.maxY + rs) {
        continue;
      }
      for (final (x, y) in sh.snapPoints()) {
        final d2 = (x - p.x) * (x - p.x) + (y - p.y) * (y - p.y);
        if (d2 < best) {
          best = d2;
          snap = vm.Vector2(x, y);
        }
      }
    }
    if (snap != null) {
      setState(() {
        _shape = null;
        if (_measure.length >= 2) _measure.clear();
        _measure.add(snap!);
      });
      _overlayTick.value++;
      return;
    }

    // 2) Figura bajo el dedo: por su contorno o, si no, la más pequeña que lo contiene.
    final rt = 18 * pxToWorld;
    Shape? hit;
    var hitD = rt;
    for (final sh in shapes) {
      if (!shown(sh) ||
          p.x < sh.minX - rt ||
          p.x > sh.maxX + rt ||
          p.y < sh.minY - rt ||
          p.y > sh.maxY + rt) {
        continue;
      }
      final d = sh.distanceTo(p.x, p.y);
      if (d < hitD) {
        hitD = d;
        hit = sh;
      }
    }
    if (hit == null) {
      var bestArea = double.infinity;
      for (final sh in shapes) {
        if (!shown(sh) || !sh.contains(p.x, p.y)) continue;
        final a = sh.area;
        if (a < bestArea) {
          bestArea = a;
          hit = sh;
        }
      }
    }
    setState(() {
      _measure.clear();
      _shape = hit;
    });
    _overlayTick.value++;
  }

  void _focusSelection() {
    final doc = _doc;
    if (doc is ModelDocument) {
      final scene = doc.scene;
      final list = _selected.isEmpty
          ? scene.instances(onlyVisible: false)
          : scene.instancesOf(_selected);
      if (list.isEmpty) return;
      cam.fit(Scene.boundsOfInstances(list));
    } else if (doc is DrawingDocument) {
      cam.fit(doc.lines.bounds);
    } else if (doc is ToolpathDocument) {
      cam.fit(doc.toolpath.fitBounds);
    } else if (doc is PointCloudDocument) {
      cam.fit(doc.cloud.bounds);
    }
  }

  void _standardView(double yaw, double pitch) {
    cam.setView(yaw, pitch);
    _focusSelection();
  }

  // ------------------------------------------------------------------ interfaz

  List<int> _sentSel = const [];

  // Diedro: selecciona en 3D las instancias de las piezas indicadas (por índice de pieza del STEP).
  void _selectParts(Set<int> ids) {
    final d = _doc;
    if (d is! ModelDocument) return;
    final sel = <SceneNode>{};
    void walk(SceneNode n) {
      if (n.part != null && ids.contains(n.part!.id)) sel.add(n);
      n.children.forEach(walk);
    }
    walk(d.scene.root);
    _sentSel = ids.toList()..sort();
    setState(() => _selected..clear()..addAll(sel));
  }

  // Diedro: avisa al anfitrión de la selección actual (piezas) para resaltar su globo en el plano.
  void _syncHost() {
    final ids = (_selected.map((n) => n.part?.id).whereType<int>().toSet().toList())..sort();
    if (ids.length == _sentSel.length && ids.asMap().entries.every((e) => _sentSel[e.key] == e.value)) return;
    _sentSel = ids;
    _host.invokeMethod('selected', ids).catchError((_) {});
  }

  // Diedro: eje (punto + dirección, en el mundo) del agujero señalado en el visor, para marcarlo en el plano.
  String _sentHole = '';
  void _syncHole() {
    final c = _cad;
    final List<double> v = [];
    if (c != null && c.picks.isNotEmpty) {
      final p = c.picks.last;
      if (p.isEdge && p.edge != null && p.edge!.kind == CurveKind.circle) {   // borde circular: su centro y eje definen la recta del agujero
        final s = p.instance.world.transformed3(p.edge!.center.clone());
        final a = p.instance.world.rotated3(p.edge!.axis.clone());
        v.addAll([s.x, s.y, s.z, a.x, a.y, a.z]);
      } else if (!p.isEdge && p.face != null && p.face!.kind == SurfaceKind.cylinder && p.face!.concave) {
        final h = c.holeContaining(p.part, p.index);
        if (h != null) {
          final s = p.instance.world.transformed3(h.start.clone());
          final a = p.instance.world.rotated3(h.axis.clone());
          v.addAll([s.x, s.y, s.z, a.x, a.y, a.z]);
        }
      }
    }
    final key = v.map((e) => e.toStringAsFixed(3)).join(',');
    if (key == _sentHole) return;
    _sentHole = key;
    _host.invokeMethod('hole', v).catchError((_) {});
  }

  // Diedro: plano de sección activo del visor (eje 0..2 y posición en el mundo) para trazarlo en el plano 2D.
  String _sentSec = '';
  void _syncSection() {
    final c = _cad;
    final List<double> v = [];
    if (c != null && c.sectionAxis >= 0) {
      final b = c.scene.bounds();
      final a = c.sectionAxis;
      v.addAll([a.toDouble(), b.min[a] + (b.max[a] - b.min[a]) * c.sectionT]);
    }
    final key = v.map((e) => e.toStringAsFixed(3)).join(',');
    if (key == _sentSec) return;
    _sentSec = key;
    _host.invokeMethod('section', v).catchError((_) {});
  }

  // Diedro: el plano pide señalar el agujero cuyo eje pasa por p con dirección a.
  void _holeAt(List<double> q) {
    final c = _cad;
    if (c == null || q.length < 6) return;
    final p = vm.Vector3(q[0], q[1], q[2]), a = vm.Vector3(q[3], q[4], q[5])..normalize();
    for (final inst in c.scene.instances(onlyVisible: false)) {
      for (final h in c.holesOf(inst.part)) {
        final s = inst.world.transformed3(h.start.clone());
        final ha = inst.world.rotated3(h.axis.clone())..normalize();
        if (ha.cross(a).length > 1e-3) continue;
        final d = s - p;
        if ((d - a * d.dot(a)).length > 0.05 * math.max(1.0, h.radius)) continue;
        final f = h.faces.first;
        c.measuring = true;
        c.picks
          ..clear()
          ..add(PickedEntity(instance: inst, isEdge: false, index: f, face: c.scene.cad!.faceInfo(inst.part.id, f), point: s));
        c.result = null;
        c.changed();
        setState(() {});
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) { _syncHost(); _syncHole(); _syncSection(); });
    final doc = _doc;
    final showHome = doc == null && !_kHomeShotSkip;
    return Scaffold(
      key: _scaffold,
      endDrawer: switch (doc) {
        ModelDocument d when _isAssembly(d) => Drawer(
          width: 370,
          child: ScenePanel(
            scene: d.scene,
            selected: _selected,
            onChanged: () => setState(() {}),
            onFocus: _focusSelection,
            unit: _cad?.unit ?? Units.defaultUnit,
            onCopyBom: _cad == null ? null : () => copyBom(context, _cad!),
          ),
        ),
        DrawingDocument d => Drawer(
          width: 330,
          child: LayersPanel(
            lines: d.lines,
            onChanged: () => setState(() => _repaint++),
          ),
        ),
        ToolpathDocument d => Drawer(
          width: 370,
          child: d.toolpath.stats.cnc != null
              ? CncInfoPanel(
                  toolpath: d.toolpath,
                  sim: _sim ??= StockSim(d.toolpath),
                  onDiameter: (tool, dia) => setState(() {
                    _sim!.setDiameter(tool, dia);
                    if (_showStock) _refreshStock();
                  }),
                )
              : GcodeInfoPanel(
                  toolpath: d.toolpath,
                  hidden: _hidden,
                  onHidden: _setHidden,
                  onLayer: (l) {
                    _setRange(l, l);
                    Navigator.of(context).maybePop();
                  },
                ),
        ),
        ModelDocument() || PointCloudDocument() || null => null,
      },
      body: RepaintBoundary(
        key: _boundary,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (doc != null) _viewport3d(doc),
            if (showHome)
              const Center(child: CircularProgressIndicator(color: DT.orange)),
            if (doc != null) _header(doc),
            if (doc != null)
              Positioned(
                right: 12,
                top: 0,
                bottom: doc is ToolpathDocument
                    ? 250
                    : (_tmf != null ? (_tmf!.multiPlate ? 140 : 70) : 0),
                child: Center(child: _toolbar(doc)),
              ),
            if (_draw != null)
              ListenableBuilder(
                listenable: _draw!,
                builder: (_, _) => _problemBar(_draw!),
              ),
            if (_cloud != null)
              ListenableBuilder(
                listenable: _cloud!,
                builder: (_, _) => _cloudBar(_cloud!),
              ),
            if (_mesh?.player != null && _mesh!.player!.rig.animations.isNotEmpty)
              Positioned(
                left: 12,
                right: 12,
                bottom: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: AnimationBar(_mesh!.player!),
                  ),
                ),
              ),
            if (_tmf != null && _tmf!.multiPlate)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: ListenableBuilder(
                      listenable: _tmf!,
                      builder: (_, _) => TmfPlateStrip(
                        _tmf!,
                        onSelected: (_) => cam.fit(_tmf!.viewBounds()),
                      ),
                    ),
                  ),
                ),
              ),
            if (doc is ToolpathDocument)
              Positioned(
                left: 12,
                right: 12,
                bottom: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: !doc.toolpath.isFdm
                        ? CncCard(
                            toolpath: doc.toolpath,
                            progress: _cncProg,
                            playing: _playing,
                            onProgress: (v) {
                              _stopPlay();
                              setState(() => _setCncProg(v));
                            },
                            onPlay: _togglePlay,
                            onMode: _setColorMode,
                            stock: _showStock,
                            onStock: _toggleStock,
                          )
                        : GcodeCard(
                            toolpath: doc.toolpath,
                            lo: _layerLo.clamp(0, doc.toolpath.layerCount - 1),
                            hi: _layerHi.clamp(0, doc.toolpath.layerCount - 1),
                            frac: _layerFrac,
                            playing: _playing,
                            hidden: _hidden,
                            onRange: _setRange,
                            onPlay: _togglePlay,
                            onMode: _setColorMode,
                            onHidden: _setHidden,
                          ),
                  ),
                ),
              ),
            if (_cad != null)
              Positioned(
                left: 16,
                bottom: (_cad!.measuring || _cad!.selectedPmi != null)
                    ? 190
                    : 28,
                child: SafeArea(
                  child: ViewCube(
                    cam: cam,
                    onView: (yaw, pitch) => _standardView(yaw, pitch),
                  ),
                ),
              ),
            if (_cad?.selectedPmi != null && _cad?.measuring != true)
              Positioned(
                left: 12,
                right: 12,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: CadPmiCard(_cad!),
                  ),
                ),
              ),
            if (_cad?.measuring == true)
              Positioned(
                left: 12,
                right: 12,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: CadMeasureCard(_cad!),
                  ),
                ),
              ),
            if (_error != null) _errorCard(),
            if (_loading)
              ColoredBox(
                color: const Color(0xCC050B0D),
                child: Center(
                  child: _LoadingCard(note: _loadingNote, name: _loadingName),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool get _kHomeShotSkip => false;

  Widget _viewport3d(Document doc) {
    return LayoutBuilder(
      builder: (context, c) {
        _viewport = Size(c.maxWidth, c.maxHeight);
        // La barra de herramientas ocupa unos 72 px a la derecha: el modelo se centra en el resto.
        cam.ndcShiftX =
            ((_doc is ModelDocument || _doc is DrawingDocument) &&
                c.maxWidth > 0)
            ? -(36 / c.maxWidth) * 2
            : 0;
        cam.aspect = c.maxWidth / c.maxHeight;
        if (_needsFit && c.maxHeight > 0 && c.maxWidth > 0) {
          _needsFit = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _focusSelection();
          });
        }
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent)
              cam.zoom(e.scrollDelta.dy > 0 ? 0.9 : 1.1);
          },
          child: GestureDetector(
            onScaleStart: _onScaleStart,
            onScaleEnd: _onScaleEnd,
            onScaleUpdate: _onScaleUpdate,
            onTapUp: _onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: _ViewPainter(
                    _renderer,
                    doc,
                    cam,
                    _mode,
                    _selected,
                    _progress,
                    _showTravels,
                    _repaint,
                    _cad?.options ?? _stl?.options ?? _tmf?.options ?? _mesh?.options,
                    _layerLo,
                    _stockScene,
                    _renderer2,
                    _stl?.thicknessView == true && _stl?.thicknessScene != null
                        ? _stl?.thicknessScene
                        : (_stl?.overhangView == true
                              ? _stl?.overhangScene
                              : (_stl?.fileColor == true ? _stl?.colorScene : null)),
                    _stl?.lodScene ?? _tmf?.lodScene ?? _mesh?.lodScene,
                  ),
                  size: Size.infinite,
                ),
                if (_cad != null)
                  CustomPaint(
                    painter: CadOverlayPainter(cam, _cad!, _overlayTick),
                    size: Size.infinite,
                  ),
                if (_cloud != null)
                  CustomPaint(
                    painter: CloudOverlayPainter(cam, _cloud!, _overlayTick),
                    size: Size.infinite,
                  ),
                if (doc is DrawingDocument)
                  CustomPaint(
                    painter: _DrawingOverlay(
                      cam,
                      doc,
                      _measure,
                      _shape,
                      _draw,
                      _overlayTick,
                    ),
                    size: Size.infinite,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(Document doc) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Align(
          alignment: Alignment.topLeft,
          child: Glass(
            radius: 24,
            padding: const EdgeInsets.fromLTRB(6, 6, 14, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width - 150,
                      ),
                      child: Text(
                        _shownName ?? doc.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
                if (MediaQuery.of(context).size.height >= 420)
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width - 70,
                    ),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _stl != null
                          ? _stlChips(_stl!)
                          : (_tmf != null
                                ? tmfChips(_tmf!)
                                : (_mesh != null
                                      ? meshChips(_mesh!, _mesh!.scene.bounds())
                                      : _chips)),
                    ),
                  ),
                ),
                if (_selected.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 8),
                    child: Text(
                      tr('Seleccionado: {x}', {
                        'x': _selected.length == 1 && _tmf?.describe(_selected.first) != null
                            ? _tmf!.describe(_selected.first)!
                            : _selected.map((n) => n.name).join(', '),
                      }),
                      style: const TextStyle(
                        color: DT.orangeSoft,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                if (_stl?.measureText != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 8),
                    child: Text(
                      _stl!.measureText!,
                      style: const TextStyle(
                        color: DT.mint,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (_stl?.measuring == true && _stl!.points.length < 2)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 8),
                    child: Text(
                      _stl!.points.isEmpty
                          ? tr('Toca un punto de la pieza')
                          : tr('Toca el segundo punto'),
                      style: const TextStyle(color: DT.mint, fontSize: 13),
                    ),
                  ),
                if (_mesh?.measureText != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 8),
                    child: Text(
                      _mesh!.measureText!,
                      style: const TextStyle(
                        color: DT.mint,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (_mesh?.measuring == true && _mesh!.points.length < 2)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 8),
                    child: Text(
                      _mesh!.points.isEmpty
                          ? tr('Toca un punto de la pieza')
                          : tr('Toca el segundo punto'),
                      style: const TextStyle(color: DT.mint, fontSize: 13),
                    ),
                  ),
                if (_tmf?.measureText != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 8),
                    child: Text(
                      _tmf!.measureText!,
                      style: const TextStyle(
                        color: DT.mint,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (_tmf?.measuring == true && _tmf!.points.length < 2)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 8),
                    child: Text(
                      _tmf!.points.isEmpty
                          ? tr('Toca un punto de la pieza')
                          : tr('Toca el segundo punto'),
                      style: const TextStyle(color: DT.mint, fontSize: 13),
                    ),
                  ),
                if (_measure.length == 2)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 8),
                    child: _measureLabel(),
                  ),
                if (_measure.length == 1)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 8),
                    child: Text(
                      tr('Punto  ·  X {x}  ·  Y {y}  ·  toca otro para medir la distancia', {
                        'x': _measure[0].x.toStringAsFixed(2),
                        'y': _measure[0].y.toStringAsFixed(2),
                      }),
                      style: const TextStyle(
                        color: DT.mint,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (_shape != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 8),
                    child: _shapeLabel(_shape!),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Encuadra un agujero de la malla y lo marca.
  void _focusHole(MeshHole h) {
    _stl?.showHole(h);
    final r = math.max(h.size / 2, 1e-6) * 1.8;
    cam.fit(
      Bounds(
        [h.center[0] - r, h.center[1] - r, h.center[2] - r],
        [h.center[0] + r, h.center[1] + r, h.center[2] + r],
      ),
    );
  }

  /// Cabecera del STL: estado de la malla, medidas con unidad y masa estimada.
  List<Widget> _stlChips(StlController c) {
    final r = c.report;
    final s = c.sizeMm;
    final chips = <Widget>[];
    if (r == null) {
      chips.add(
        InfoChip(
          Icons.hourglass_top_rounded,
          c.checking ? tr('Revisando la malla…') : tr('Sin revisar'),
        ),
      );
    } else {
      final bad = r.problemCount;
      chips.add(
        InfoChip(
          bad == 0
              ? Icons.check_circle_outline_rounded
              : Icons.warning_amber_rounded,
          bad == 0
              ? tr('Estanca')
              : (bad == 1 ? tr('1 problema') : tr('{n} problemas', {'n': bad})),
          color: bad == 0 ? DT.mint : DT.orangeSoft,
        ),
      );
    }
    chips.add(InfoChip(Icons.straighten, Units.dims(s)));
    if (c.unitHint != null) {
      chips.add(
        InfoChip(
          Icons.help_outline_rounded,
          tr('Unidad dudosa'),
          color: DT.orangeSoft,
        ),
      );
    }
    if (c.colorScene != null) {
      chips.add(InfoChip(Icons.palette_outlined, tr('con color')));
    }
    if (r != null) {
      chips.add(
        InfoChip(
          Icons.scale_outlined,
          '${Units.volume(c.volumeCm3 * 1000)} · ${Units.mass(c.solidGrams)} ${kPrintMaterials[c.material].$1}',
        ),
      );
    } else {
      chips.add(
        InfoChip(
          Icons.change_history,
          _fmtCount(c.mesh.triangleCount, tr('triángulos')),
        ),
      );
    }
    return chips;
  }

  /// Marca un aviso de la revisión y encuadra la vista sobre él.
  void _showProblem(DrawingController dc, DrawingProblem p) {
    dc.show(p);
    if (p.poly.isNotEmpty) {
      var mnx = double.infinity, mny = double.infinity;
      var mxx = -double.infinity, mxy = -double.infinity;
      for (var i = 0; i + 1 < p.poly.length; i += 2) {
        mnx = math.min(mnx, p.poly[i]);
        mxx = math.max(mxx, p.poly[i]);
        mny = math.min(mny, p.poly[i + 1]);
        mxy = math.max(mxy, p.poly[i + 1]);
      }
      cam.fit(Bounds([mnx, mny, 0], [mxx, mxy, 0]));
    }
  }

  /// Barra para recorrer los avisos de la revisión uno a uno.
  /// Barra inferior de la nube: ayuda al medir y resultado entre dos puntos.
  Widget _cloudBar(CloudController cc) {
    if (!cc.measuring) return const SizedBox.shrink();
    final r = cc.result;
    return Positioned(
      left: 12,
      right: 12,
      bottom: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Glass(
                radius: 22,
                padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: r.isEmpty
                          ? Text(
                              cc.picks.isEmpty
                                  ? tr('Toca un punto de la nube')
                                  : tr('Toca el segundo punto'),
                              style: const TextStyle(color: DT.muted),
                            )
                          : Wrap(
                              spacing: 18,
                              runSpacing: 4,
                              children: [
                                for (final e in r)
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(e.$1, style: const TextStyle(color: DT.muted, fontSize: 11.5)),
                                      Text(e.$2, style: const TextStyle(fontWeight: FontWeight.w700)),
                                    ],
                                  ),
                              ],
                            ),
                    ),
                    if (cc.picks.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 20),
                        tooltip: tr('Borrar medida'),
                        onPressed: cc.clearPicks,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _problemBar(DrawingController dc) {
    final list = dc.problems;
    final cur = dc.highlight;
    final idx = cur == null ? -1 : list.indexOf(cur);
    if (cur == null || idx < 0) return const SizedBox.shrink();
    void go(int d) => _showProblem(dc, list[(idx + d) % list.length]);
    return Positioned(
      left: 12,
      right: 12,
      bottom: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Glass(
                radius: 22,
                padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr('Aviso {i} de {n}', {'i': idx + 1, 'n': list.length}),
                            style: const TextStyle(
                              color: DT.orangeSoft,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            dc.problemText(cur),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13.5),
                          ),
                        ],
                      ),
                    ),
                    if (list.length > 1) ...[
                      IconButton(
                        tooltip: tr('Aviso anterior'),
                        icon: const Icon(Icons.chevron_left_rounded),
                        onPressed: () => go(-1 + list.length),
                      ),
                      IconButton(
                        tooltip: tr('Aviso siguiente'),
                        icon: const Icon(Icons.chevron_right_rounded),
                        onPressed: () => go(1),
                      ),
                    ],
                    IconButton(
                      tooltip: tr('Cerrar'),
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => dc.show(null),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _shapeLabel(Shape sh) {
    String f(double v) => _draw?.len(v) ?? v.toStringAsFixed(2);
    String ar(double v) => _draw?.area(v) ?? v.toStringAsFixed(1);
    final w = sh.maxX - sh.minX, h = sh.maxY - sh.minY;
    final text = switch (sh.kind) {
      ShapeKind.circle =>
        tr('Círculo  ·  Ø {d}  ·  R {r}  ·  centro ({x}, {y})', {
          'd': f(sh.radius * 2),
          'r': f(sh.radius),
          'x': sh.cx.toStringAsFixed(2),
          'y': sh.cy.toStringAsFixed(2),
        }),
      ShapeKind.arc =>
        tr('Arco  ·  R {r}  ·  {a}°  ·  longitud {l}', {
          'r': f(sh.radius),
          'a': (sh.sweep * 180 / math.pi).toStringAsFixed(1),
          'l': f(sh.length),
        }),
      ShapeKind.line =>
        tr('Línea  ·  longitud {l}  ·  ΔX {dx}  ·  ΔY {dy}  ·  {a}°', {
          'l': f(sh.length),
          'dx': f(w),
          'dy': f(h),
          'a': (math.atan2(sh.pts[3] - sh.pts[1], sh.pts[2] - sh.pts[0]) * 180 / math.pi).toStringAsFixed(1),
        }),
      ShapeKind.rectangle =>
        tr('Rectángulo  ·  {w} × {h}  ·  área {a}', {'w': f(w), 'h': f(h), 'a': ar(sh.area)}),
      ShapeKind.polygon =>
        tr('Contorno cerrado  ·  {w} × {h}  ·  perímetro {p}  ·  área {a}', {
          'w': f(w),
          'h': f(h),
          'p': f(sh.length),
          'a': ar(sh.area),
        }),
      ShapeKind.polyline =>
        tr('Polilínea  ·  longitud {l}  ·  {n} tramos', {'l': f(sh.length), 'n': sh.pointCount - 1}),
    };
    return Text(
      text,
      style: const TextStyle(
        color: DT.orangeSoft,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _measureLabel() {
    String f(double v) => _draw?.len(v) ?? v.toStringAsFixed(2);
    final a = _measure[0], b = _measure[1];
    final dx = (b.x - a.x).abs(), dy = (b.y - a.y).abs();
    final dist = math.sqrt(dx * dx + dy * dy);
    final ang = math.atan2(b.y - a.y, b.x - a.x) * 180 / math.pi;
    return Text(
      tr('Distancia {d}  ·  ΔX {dx}  ·  ΔY {dy}  ·  {a}°', {
        'd': f(dist),
        'dx': f(dx),
        'dy': f(dy),
        'a': ang.toStringAsFixed(1),
      }),
      style: const TextStyle(
        color: DT.mint,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  Widget _errorCard() {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Glass(
            radius: 22,
            color: const Color(0xE61A1410),
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.info_outline_rounded,
                    color: DT.orangeSoft,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _error!,
                    style: const TextStyle(fontSize: 14, height: 1.35),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _error = null),
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Solo los conjuntos (más de una pieza o instancia) tienen árbol y buscador.
  bool _isAssembly(ModelDocument d) =>
      d.scene.instances(onlyVisible: false).length > 1;

  Widget _toolbar(Document doc) {
    final items = <Widget>[];
    switch (doc) {
      case ModelDocument d when _cad != null:
        final c = _cad!;
        final asm = _isAssembly(d);
        items
          ..add(
            ToolButton(
              icon: Icons.center_focus_strong_outlined,
              tooltip: tr('Centrar'),
              onTap: _focusSelection,
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.view_in_ar_outlined,
              tooltip: tr('Vistas'),
              onTap: () => showViewsSheet(
                context,
                ortho: cam.ortho,
                onView: (yaw, pitch) => _standardView(yaw, pitch),
                onToggleOrtho: () {
                  cam.ortho = !cam.ortho;
                  _focusSelection();
                },
              ),
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.border_outer_rounded,
              tooltip: tr('Aristas'),
              active: c.options.edges,
              onTap: c.toggleEdges,
            ),
          )
          ..add(const _ToolDivider())
          ..add(
            ToolButton(
              icon: Icons.straighten_rounded,
              tooltip: tr('Medir'),
              active: c.measuring,
              onTap: c.toggleMeasure,
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.radio_button_unchecked_rounded,
              tooltip: tr('Agujeros'),
              onTap: () => showHolesSheet(
                context,
                c,
                onPick: (e) {
                  c.measuring = true;
                  c.picks
                    ..clear()
                    ..add(e);
                  c.result = null;
                  c.changed();
                },
              ),
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.content_cut_rounded,
              tooltip: tr('Sección'),
              active: c.sectionAxis >= 0,
              onTap: () => showSectionSheet(context, c),
            ),
          );
        if (c.pmi.isNotEmpty) {
          items.add(
            ToolButton(
              icon: Icons.rule_rounded,
              tooltip: tr('Cotas y tolerancias'),
              active: c.showAllPmi || c.selectedPmi != null,
              onTap: () => showPmiSheet(context, c),
            ),
          );
        }
        if (asm) {
          items
            ..add(
              ToolButton(
                icon: Icons.open_in_full_rounded,
                tooltip: tr('Explosionar'),
                active: c.options.explode > 0,
                onTap: () => showExplodeSheet(context, c),
              ),
            )
            ..add(
              ToolButton(
                icon: Icons.blur_on_rounded,
                tooltip: tr('Atenuar el resto'),
                active: c.options.ghostOthers,
                onTap: c.toggleGhost,
              ),
            );
        }
        items
          ..add(const _ToolDivider())
          ..add(
            ToolButton(
              icon: Icons.info_outline_rounded,
              tooltip: tr('Información'),
              onTap: () => showInfoSheet(context, c, _selected),
            ),
          );
        if (asm) {
          items.add(
            ToolButton(
              icon: Icons.account_tree_outlined,
              tooltip: tr('Árbol de piezas'),
              onTap: () => _scaffold.currentState?.openEndDrawer(),
            ),
          );
        }
      case ModelDocument d:
        if (_isAssembly(d)) {
          items.add(
            ToolButton(
              icon: Icons.account_tree_outlined,
              tooltip: tr('Árbol de piezas'),
              onTap: () => _scaffold.currentState?.openEndDrawer(),
            ),
          );
        }
        final mf = _mesh;
        if (mf != null) {
          items
            ..add(const _ToolDivider())
            ..add(
              ToolButton(
                icon: Icons.info_outline_rounded,
                tooltip: tr('Qué trae el archivo'),
                active: mf.info.missing.isNotEmpty,
                onTap: () => showMeshInfoSheet(
                  context,
                  mf,
                  onAddFiles: () async {
                    if (await pickMissingFiles(mf.path)) await _open(mf.path);
                  },
                ),
              ),
            )
            ..add(
              ToolButton(
                icon: Icons.view_list_rounded,
                tooltip: tr('Piezas y eje vertical'),
                active: mf.hidden.isNotEmpty,
                onTap: () => showMeshPartsSheet(
                  context,
                  mf,
                  onFocus: (b) => cam.fit(b),
                ),
              ),
            );
          if (mf.info.variants.isNotEmpty) {
            items.add(
              ToolButton(
                icon: Icons.style_outlined,
                tooltip: tr('Variantes de material'),
                active: mf.variant >= 0,
                onTap: () => showMeshVariantsSheet(context, mf),
              ),
            );
          }
          if (mf.info.views.isNotEmpty) {
            items.add(
              ToolButton(
                icon: Icons.videocam_outlined,
                tooltip: tr('Vistas del archivo'),
                onTap: () => showMeshViewsSheet(context, mf, cam),
              ),
            );
          }
          if (mf.hasAppearance) {
            items.add(
              ToolButton(
                icon: mf.textures
                    ? Icons.image_outlined
                    : Icons.hide_image_outlined,
                tooltip: mf.textures
                    ? tr('Ver solo la forma')
                    : tr('Ver texturas y colores'),
                active: !mf.textures,
                onTap: mf.toggleTextures,
              ),
            );
          }
          items
            ..add(
              ToolButton(
                icon: Icons.straighten_rounded,
                tooltip: tr('Medir entre dos puntos'),
                active: mf.measuring,
                onTap: mf.toggleMeasure,
              ),
            )
            ..add(
              ToolButton(
                icon: Icons.content_cut_rounded,
                tooltip: tr('Sección'),
                active: mf.sectionAxis >= 0,
                onTap: () => showMeshFileSectionSheet(context, mf),
              ),
            )
            ..add(
              ToolButton(
                icon: Icons.swap_vert_rounded,
                tooltip: tr('Cambiar el eje vertical ({x})', {'x': mf.up.toUpperCase()}),
                onTap: () {
                  mf.cycleUp();
                  cam.fit(mf.scene.bounds());
                },
              ),
            );
        }
        final tmf = _tmf;
        if (tmf != null) {
          items
            ..add(const _ToolDivider())
            ..add(
              ToolButton(
                icon: Icons.view_in_ar_outlined,
                tooltip: tr('Piezas del proyecto'),
                active: tmf.isolated != null || tmf.hiddenObjects.isNotEmpty,
                onTap: () => showTmfPartsSheet(
                  context,
                  tmf,
                  onFocus: (b) => cam.fit(b),
                ),
              ),
            )
            ..add(
              ToolButton(
                icon: Icons.palette_outlined,
                tooltip: tr('Filamentos y laminado'),
                active: tmf.hiddenSlots.isNotEmpty,
                onTap: () => showTmfFilamentsSheet(
                  context,
                  tmf,
                  onToolpath: (n) => _open(tmf.path, gcodePlate: n),
                ),
              ),
            )
            ..add(
              ToolButton(
                icon: Icons.info_outline_rounded,
                tooltip: tr('Proyecto y ajustes'),
                onTap: () => showTmfProjectSheet(context, tmf),
              ),
            );
          items
            ..add(
              ToolButton(
                icon: Icons.straighten_rounded,
                tooltip: tr('Medir entre dos puntos'),
                active: tmf.measuring,
                onTap: tmf.toggleMeasure,
              ),
            )
            ..add(
              ToolButton(
                icon: Icons.content_cut_rounded,
                tooltip: tr('Sección'),
                active: tmf.sectionAxis >= 0,
                onTap: () => showTmfSectionSheet(context, tmf),
              ),
            );
          if (tmf.bedKnown && tmf.project.plates.isNotEmpty) {
            items.add(
              ToolButton(
                icon: Icons.crop_square_rounded,
                tooltip: tr('Cama y volumen de impresión'),
                active: tmf.showBed,
                onTap: tmf.toggleBed,
              ),
            );
          }
        }
        items
          ..add(
            ToolButton(
              icon: Icons.center_focus_strong_outlined,
              tooltip: tr('Centrar'),
              onTap: _focusSelection,
            ),
          )
          ..add(const _ToolDivider())
          ..add(
            ToolButton(
              icon: Icons.view_in_ar_outlined,
              tooltip: tr('Isométrica'),
              onTap: () => _standardView(-0.785, 0.615),
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.crop_square_rounded,
              tooltip: tr('Frontal'),
              onTap: () => _standardView(-1.5708, 0),
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.vertical_align_top_rounded,
              tooltip: tr('Planta'),
              onTap: () => _standardView(-1.5708, 1.5),
            ),
          )
          ..add(const _ToolDivider())
          ..add(
            ToolButton(
              icon: Icons.grid_4x4_rounded,
              tooltip: tr('Alambre'),
              active: _mode == ViewMode.wireframe,
              onTap: () => setState(
                () => _mode = _mode == ViewMode.shaded
                    ? ViewMode.wireframe
                    : ViewMode.shaded,
              ),
            ),
          );
        final stl = _stl;
        if (stl != null) {
          final r = stl.report;
          items
            ..add(const _ToolDivider())
            ..add(
              ToolButton(
                icon: r != null && r.problemCount > 0
                    ? Icons.report_problem_outlined
                    : Icons.fact_check_outlined,
                tooltip: tr('Revisión de la malla'),
                active: stl.showDefects,
                onTap: () =>
                    showMeshReviewSheet(context, stl, onHole: _focusHole),
              ),
            )
            ..add(
              ToolButton(
                icon: Icons.print_outlined,
                tooltip: tr('Impresión: peso, cama y voladizos'),
                active: stl.showBed || stl.overhangView,
                onTap: () => showPrintSheet(context, stl),
              ),
            )
            ..addAll([
              if (stl.colorScene != null)
                ToolButton(
                  icon: Icons.palette_outlined,
                  tooltip: tr('Color del archivo'),
                  active: stl.fileColor,
                  onTap: stl.toggleFileColor,
                ),
            ])
            ..add(
              ToolButton(
                icon: Icons.filter_hdr_rounded,
                tooltip: tr('Voladizos'),
                active: stl.overhangView,
                onTap: stl.toggleOverhang,
              ),
            )
            ..add(
              ToolButton(
                icon: Icons.content_cut_rounded,
                tooltip: tr('Sección'),
                active: stl.sectionAxis >= 0,
                onTap: () => showMeshSectionSheet(context, stl),
              ),
            )
            ..add(
              ToolButton(
                icon: Icons.straighten_rounded,
                tooltip: tr('Medir entre dos puntos'),
                active: stl.measuring,
                onTap: stl.toggleMeasure,
              ),
            );
        }
      case DrawingDocument():
        final dc = _draw;
        items
          ..add(
            ToolButton(
              icon: Icons.layers_outlined,
              tooltip: tr('Capas'),
              onTap: () => _scaffold.currentState?.openEndDrawer(),
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.center_focus_strong_outlined,
              tooltip: tr('Ajustar'),
              onTap: _focusSelection,
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.rotate_90_degrees_ccw_rounded,
              tooltip: tr('Girar el plano'),
              onTap: () {
                cam.setView(cam.yaw + math.pi / 2, cam.pitch);
                _focusSelection();
              },
            ),
          );
        if (dc != null) {
          items
            ..add(const _ToolDivider())
            ..add(
              ToolButton(
                icon: Icons.content_cut_rounded,
                tooltip: tr('Datos de corte'),
                onTap: () => showCutSheet(context, dc),
              ),
            )
            ..add(
              (_doc as DrawingDocument).info != null
                  ? ToolButton(
                      icon: Icons.description_outlined,
                      tooltip: tr('Sobre el archivo'),
                      onTap: () =>
                          showVectorSheet(context, _doc as DrawingDocument),
                    )
                  : const SizedBox.shrink(),
            )
            ..add(
              ToolButton(
                icon: Icons.fact_check_outlined,
                tooltip: tr('Revisión del archivo'),
                active: dc.highlight != null,
                onTap: () => showReviewSheet(
                  context,
                  dc,
                  onShow: (p) => _showProblem(dc, p),
                ),
              ),
            )
            ..add(
              ToolButton(
                icon: Icons.format_color_fill_rounded,
                tooltip: tr('Rellenar contornos'),
                active: dc.fill,
                onTap: dc.toggleFill,
              ),
            );
        }
        items
          ..add(const _ToolDivider())
          ..add(
            ToolButton(
              icon: Icons.straighten_rounded,
              tooltip: tr('Medir'),
              active: _measuring,
              onTap: () {
                setState(() {
                  _measuring = !_measuring;
                  _measure.clear();
                  _shape = null;
                });
                _overlayTick.value++;
              },
            ),
          );
      case ToolpathDocument():
        items
          ..add(
            ToolButton(
              icon: Icons.tune_rounded,
              tooltip: tr('Información y filtros'),
              onTap: () => _scaffold.currentState?.openEndDrawer(),
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.center_focus_strong_outlined,
              tooltip: tr('Centrar'),
              onTap: _focusSelection,
            ),
          )
          ..add(const _ToolDivider())
          ..add(
            ToolButton(
              icon: Icons.view_in_ar_outlined,
              tooltip: tr('Isométrica'),
              onTap: () => _standardView(-0.785, 0.615),
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.vertical_align_top_rounded,
              tooltip: tr('Planta'),
              onTap: () => _standardView(-1.5708, 1.5),
            ),
          )
          ..add(const _ToolDivider())
          ..add(
            ToolButton(
              icon: Icons.alt_route_rounded,
              tooltip: tr('Movimientos rápidos'),
              active: _showTravels,
              onTap: () => setState(() => _showTravels = !_showTravels),
            ),
          );
      case PointCloudDocument d:
        items
          ..add(
            ToolButton(
              icon: Icons.center_focus_strong_outlined,
              tooltip: tr('Centrar'),
              onTap: _focusSelection,
            ),
          )
          ..add(const _ToolDivider())
          ..add(
            ToolButton(
              icon: Icons.view_in_ar_outlined,
              tooltip: tr('Isométrica'),
              onTap: () => _standardView(-0.785, 0.615),
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.vertical_align_top_rounded,
              tooltip: tr('Planta'),
              onTap: () => _standardView(-1.5708, 1.5),
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.crop_square_rounded,
              tooltip: tr('Frontal'),
              onTap: () => _standardView(-1.5708, 0),
            ),
          )
          ..add(const _ToolDivider())
          ..add(
            ToolButton(
              icon: Icons.palette_outlined,
              tooltip: tr('Vista: color, tamaño y filtros'),
              active: d.cloud.mode != CloudColorMode.original || d.cloud.filtered,
              onTap: () => showCloudViewSheet(context, _cloud!),
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.straighten_rounded,
              tooltip: tr('Medir entre dos puntos'),
              active: _cloud?.measuring == true,
              onTap: () => _cloud?.toggleMeasure(),
            ),
          )
          ..add(
            ToolButton(
              icon: Icons.description_outlined,
              tooltip: tr('Sobre el archivo'),
              onTap: () => showCloudInfoSheet(context, d.cloud),
            ),
          );
    }
    return Glass(
      radius: 24,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: items)),
    );
  }
}

class _ToolDivider extends StatelessWidget {
  const _ToolDivider();
  @override
  Widget build(BuildContext context) => Container(
    width: 26,
    height: 1,
    margin: const EdgeInsets.symmetric(vertical: 4),
    color: DT.border,
  );
}

/// Mientras el usuario gira o hace zoom se dibuja con menos pasadas en trayectorias enormes.
bool _interactingNow = false;

class _ViewPainter extends CustomPainter {
  _ViewPainter(
    this.renderer,
    this.doc,
    this.cam,
    this.mode,
    this.selected,
    this.progress,
    this.travels,
    this.version,
    this.options,
    this.layerLo,
    this.stockScene,
    this.renderer2,
    this.altScene,
    this.lodScene,
  ) : super(repaint: cam);
  final Scene? altScene;
  final Scene? lodScene;
  final Scene? stockScene;
  final DatumRenderer? renderer2;
  final RenderOptions? options;
  final int layerLo;
  final DatumRenderer? renderer;
  final Document? doc;
  final OrbitCamera cam;
  final ViewMode mode;
  final Set<SceneNode> selected;
  final double progress;
  final bool travels;
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    final r = renderer;
    final d = doc;
    if (r == null || d == null) return;
    final dpr = ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
    // Al girar o hacer zoom se dibuja a menor resolución: en tabletas de gama media el coste
    // del multimuestreo a 2560×1600 pasa de 80 ms a menos de 30 ms.
    final q = _interactingNow ? 0.6 : 1.0;
    final w = (size.width * dpr * q).round().clamp(1, 4096);
    final h = (size.height * dpr * q).round().clamp(1, 4096);
    final ui.Image img;
    ui.Image? under;
    ui.Image? edlDepth;
    var edlStrength = 1.0;
    switch (d) {
      case ModelDocument m:
        img = r.render(
          altScene ??
              (_interactingNow && lodScene != null ? lodScene! : m.scene),
          cam,
          w,
          h,
          mode,
          selected,
          options: options,
        );
      case DrawingDocument m:
        img = r.renderLines(
          [
            for (final g in m.lines.groups)
              if (g.visible)
                LineDraw(
                  m.lines,
                  g.firstVertex,
                  g.vertexCount,
                  // En dibujos muy densos una pasada basta: el grosor ya no se aprecia.
                  passes: m.lines.segmentCount > 40000 ? 1 : 3,
                ),
          ],
          cam,
          w,
          h,
        );
      case ToolpathDocument m:
        final t = m.toolpath;
        final totalSeg = t.paths.segmentCount;
        final seg = (progress * totalSeg).round().clamp(0, totalSeg);
        final r2 = renderer2;
        if (!t.isFdm && stockScene != null && r2 != null) {
          under = r2.render(stockScene!, cam, w, h, ViewMode.shaded, const {});
        }
        final layer = seg == 0 || t.layerCount == 0
            ? 0
            : t.layerOfSegment(math.max(0, seg - 1));
        // En trayectorias enormes (más de 300 mil movimientos) dos pasadas bastan.
        final heavy = t.paths.segmentCount > 300000;
        final pass = heavy ? (_interactingNow ? 1 : 2) : 4;
        final lo = t.layerCount == 0 ? 0 : layerLo.clamp(0, t.layerCount - 1);
        if (heavy && _interactingNow && t.layerCount > 0) {
          final lod = t.lod;
          final lf = t.lodLayerFirst!;
          final hi = layer.clamp(lo, t.layerCount - 1);
          img = r.renderLines(
            [LineDraw(lod, lf[lo] * 2, (lf[hi + 1] - lf[lo]) * 2, passes: 1)],
            cam,
            w,
            h,
          );
          break;
        }
        final firstSeg = math.min(t.layerFirstSeg[lo], seg);
        final layerStart = t.layerFirstSeg[layer].clamp(firstSeg, seg);
        final firstTravel = t.layerFirstTravel[lo] * 2;
        final draws = <LineDraw>[
          if (!t.isFdm)
            LineDraw(t.guides, 0, t.guides.vertexCount, tint: 0.8, passes: 2),
          if (travels)
            LineDraw(
              t.travels,
              firstTravel,
              math.max(
                0,
                math.min(
                      t.travels.vertexCount,
                      t.layerFirstTravel[math.min(layer + 1, t.layerCount)] * 2,
                    ) -
                    firstTravel,
              ),
              tint: 0.3,
            ),
          LineDraw(
            t.paths,
            firstSeg * 2,
            (layerStart - firstSeg) * 2,
            tint: 0.7,
            passes: pass,
          ),
          LineDraw(
            t.paths,
            layerStart * 2,
            (seg - layerStart) * 2,
            passes: pass,
            tint: under != null ? 0.4 : 1.0,
          ),
        ];
        img = r.renderLines(draws, cam, w, h, transparent: under != null);
      case PointCloudDocument m:
        final big = _interactingNow && m.cloud.points.vertexCount > PointCloud.lodPoints;
        final useEdl = m.cloud.edl && !_interactingNow && EdlFx.program != null && !cam.ortho;
        // con el sombreado de borde se dibuja una muestra de 1,5 M de puntos: son dos pasadas
        final shown = useEdl && m.cloud.points.vertexCount > PointCloud.edlPoints * 1.1 ? m.cloud.edlSet : m.cloud.points;
        final sizeMul = identical(shown, m.cloud.points) ? 1.0 : 1.25;
        final draws = [
          big
              ? LineDraw(m.cloud.lod, 0, m.cloud.lod.vertexCount, points: true, pointSize: m.cloud.effectiveSize * 1.5)
              : LineDraw(shown, 0, shown.vertexCount, points: true, pointSize: m.cloud.effectiveSize * sizeMul),
        ];
        final colorImg = r.renderLines(draws, cam, w, h);
        if (useEdl) {
          // dos pasadas: color y profundidad; el sombreado de borde las combina
          edlDepth = r.renderLines(draws, cam, w, h, depthPass: true);
          edlStrength = m.cloud.edlStrength;
          img = colorImg;
        } else {
          img = colorImg;
        }
    }
    if (under != null) {
      canvas.drawImageRect(
        under,
        Rect.fromLTWH(0, 0, under.width.toDouble(), under.height.toDouble()),
        Offset.zero & size,
        Paint(),
      );
    }
    final depth = edlDepth;
    final prog = EdlFx.program;
    if (depth != null && prog != null) {
      final nf = cam.nearFar;
      final sh = prog.fragmentShader()
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, img.width.toDouble())
        ..setFloat(3, img.height.toDouble())
        ..setFloat(4, edlStrength)
        ..setFloat(5, nf.$1)
        ..setFloat(6, nf.$2)
        ..setFloat(7, 1.6)
        ..setImageSampler(0, img)
        ..setImageSampler(1, depth);
      canvas.drawRect(Offset.zero & size, Paint()..shader = sh);
      return;
    }
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Offset.zero & size,
      Paint(),
    );
  }

  @override
  bool shouldRepaint(covariant _ViewPainter old) => true;
}

/// Textos del dibujo y marcas de medición, proyectados sobre la imagen.
class _DrawingOverlay extends CustomPainter {
  _DrawingOverlay(
    this.cam,
    this.doc,
    this.measure,
    this.shape,
    this.ctrl,
    Listenable repaint,
  ) : super(repaint: repaint);
  final Shape? shape;
  final DrawingController? ctrl;
  final OrbitCamera cam;
  final DrawingDocument doc;
  final List<vm.Vector2> measure;

  Offset _project(double x, double y, Size size) {
    final m = cam.projection(size.width / size.height) * cam.viewMatrix();
    final v = vm.Vector4(x, y, 0, 1)..applyMatrix4(m);
    return Offset(
      (v.x / v.w * 0.5 + 0.5) * size.width,
      (1 - (v.y / v.w * 0.5 + 0.5)) * size.height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pxPerUnit = size.height / (2 * cam.distance * math.tan(cam.fovY / 2));
    for (final t in doc.texts) {
      final px = t.height * pxPerUnit;
      if (px < 7 || px > 400) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(color: const Color(0xFFB7CACD), fontSize: px),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width * 2);
      final o = _project(t.x, t.y, size);
      canvas.save();
      canvas.translate(o.dx, o.dy);
      canvas.rotate(-t.rotation * math.pi / 180);
      tp.paint(canvas, Offset(0, -tp.height));
      canvas.restore();
    }
    final dc = ctrl;
    if (dc != null && dc.fill && dc.analysed) {
      final fillPath = Path()..fillType = PathFillType.evenOdd;
      final groups = doc.lines.groups;
      var drawn = 0;
      for (final c in dc.analysis.contours) {
        if (!c.closed || c.poly.length < 6) continue;
        if (groups.isNotEmpty && !dc.included.contains(groups[c.group].name))
          continue;
        if (++drawn > 2500) break;
        for (var i = 0; i + 1 < c.poly.length; i += 2) {
          final o = _project(c.poly[i], c.poly[i + 1], size);
          i == 0 ? fillPath.moveTo(o.dx, o.dy) : fillPath.lineTo(o.dx, o.dy);
        }
        fillPath.close();
      }
      canvas.drawPath(fillPath, Paint()..color = const Color(0x2E5EEAD4));
    }
    final hp = dc?.highlight;
    if (hp != null && hp.poly.isNotEmpty) {
      final paint = Paint()
        ..color = DT.orange
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      if (hp.asSegments) {
        for (var i = 0; i + 3 < hp.poly.length; i += 4) {
          canvas.drawLine(
            _project(hp.poly[i], hp.poly[i + 1], size),
            _project(hp.poly[i + 2], hp.poly[i + 3], size),
            paint,
          );
        }
      } else {
        final path = Path();
        for (var i = 0; i + 1 < hp.poly.length; i += 2) {
          final o = _project(hp.poly[i], hp.poly[i + 1], size);
          i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
        }
        canvas.drawPath(path, paint);
        // Extremos del contorno abierto: dónde falta cerrar.
        final ring = Paint()
          ..color = DT.orange
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(_project(hp.poly[0], hp.poly[1], size), 12, ring);
        canvas.drawCircle(
          _project(
            hp.poly[hp.poly.length - 2],
            hp.poly[hp.poly.length - 1],
            size,
          ),
          12,
          ring,
        );
      }
    }
    final sh = shape;
    if (sh != null) {
      final path = Path();
      for (var i = 0; i < sh.pointCount; i++) {
        final o = _project(sh.pts[i * 2], sh.pts[i * 2 + 1], size);
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = DT.orange
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..style = PaintingStyle.stroke,
      );
      if (sh.kind == ShapeKind.circle || sh.kind == ShapeKind.arc) {
        final c = _project(sh.cx, sh.cy, size);
        final cp = Paint()
          ..color = DT.orange
          ..strokeWidth = 2;
        canvas.drawLine(c.translate(-7, 0), c.translate(7, 0), cp);
        canvas.drawLine(c.translate(0, -7), c.translate(0, 7), cp);
      }
    }
    if (measure.isNotEmpty) {
      final paint = Paint()
        ..color = DT.mint
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final pts = [for (final p in measure) _project(p.x, p.y, size)];
      for (final p in pts) {
        canvas.drawCircle(p, 6, paint);
      }
      if (pts.length == 2) canvas.drawLine(pts[0], pts[1], paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DrawingOverlay old) => true;
}

/// Tarjeta de carga: nombre del archivo, tiempo transcurrido y aviso si es grande.
class _LoadingCard extends StatefulWidget {
  const _LoadingCard({required this.note, required this.name});
  final String? note;
  final String name;
  @override
  State<_LoadingCard> createState() => _LoadingCardState();
}

class _LoadingCardState extends State<_LoadingCard> {
  final _sw = Stopwatch()..start();
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _sw.elapsed.inSeconds;
    return Glass(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(
                color: DT.orange,
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (s >= 2)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  tr('Abriendo… {s} s', {'s': s}),
                  style: const TextStyle(color: DT.muted, fontSize: 13),
                ),
              ),
            if (widget.note != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  widget.note!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: DT.muted,
                    height: 1.4,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
