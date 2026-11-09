// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../model/rig.dart';
import '../model/scene.dart';
import '../render/gpu_mesh.dart';
import 'glass.dart';
import 'theme.dart';
import '../l10n/l10n.dart';

/// Reproduce las animaciones de un glTF: mueve los nodos, deforma las mallas con piel y
/// aplica las formas de morfo, y mantiene sus vértices al día en la GPU.
class RigPlayer extends ChangeNotifier {
  RigPlayer(this.scene, this.rig, {required this.onFrame}) {
    pose = RigPose(rig);
    _index(scene.root);
    for (final a in rig.animations) {
      for (final c in a.channels) {
        if (c.path < 3) _animatedNodes.add(c.node);
      }
    }
    // Pose por defecto: las mallas con piel o morfo no se ven bien sin aplicarla.
    pose.beginFrame();
    _apply();
  }
  final Scene scene;
  final Rig rig;
  final void Function() onFrame;
  late final RigPose pose;

  /// −1 = ninguna (pose por defecto).
  int current = -1;
  double time = 0;
  bool playing = false;
  bool loop = true;
  double speed = 1;

  final _byNode = <int, SceneNode>{};
  final _animatedNodes = <int>{};
  Timer? _timer;
  final _watch = Stopwatch();
  double _last = 0;

  void _index(SceneNode n) {
    final t = n.tag;
    if (t != null && t.length == 2 && t[0] == 4) _byNode[t[1]] = n;
    for (final c in n.children) {
      _index(c);
    }
  }

  RigAnimation? get animation => current >= 0 && current < rig.animations.length ? rig.animations[current] : null;
  double get duration => animation?.duration ?? 0;

  void select(int i) {
    current = i;
    time = 0;
    _frame();
    notifyListeners();
  }

  void play() {
    if (animation == null && rig.animations.isNotEmpty) current = 0;
    if (animation == null) return;
    if (!loop && time >= duration) time = 0;
    playing = true;
    _watch
      ..reset()
      ..start();
    _last = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = _watch.elapsedMicroseconds / 1e6;
      final dt = now - _last;
      _last = now;
      time += dt * speed;
      final d = duration;
      if (d > 0 && time > d) {
        if (loop) {
          time = time % d;
        } else {
          time = d;
          pause();
        }
      }
      _frame();
      notifyListeners();
    });
    notifyListeners();
  }

  void pause() {
    playing = false;
    _timer?.cancel();
    _timer = null;
    _watch.stop();
    notifyListeners();
  }

  void seek(double t) {
    time = t.clamp(0, duration);
    _frame();
    notifyListeners();
  }

  void toggleLoop() {
    loop = !loop;
    notifyListeners();
  }

  void setSpeed(double s) {
    speed = s;
    notifyListeners();
  }

  void _frame() {
    final a = animation;
    if (a != null) {
      pose.sample(a, time);
    } else {
      pose.reset();
    }
    pose.beginFrame();
    _apply();
    onFrame();
  }

  final _tmp = Float64List(16);

  void _apply() {
    // nodos con transformación animada
    for (final n in _animatedNodes) {
      final sn = _byNode[n];
      if (sn == null) continue;
      pose.local(n, _tmp);
      sn.transform.storage.setAll(0, _tmp);
    }
    // mallas con piel o formas de morfo
    final jm = <int, Float64List>{};
    for (final p in rig.prims) {
      if (p.mesh >= scene.parts.length) continue;
      final part = scene.parts[p.mesh];
      final v = part.mesh.vertices;
      final base = p.basePos, bn = p.baseNor;
      if (base == null || bn == null) continue;
      final n = base.length ~/ 3;
      // morfo
      Float32List pos = base;
      final md = p.morphDeltas;
      if (md != null && md.isNotEmpty) {
        final w = pose.weights[p.node] ?? p.baseWeights;
        var any = false;
        for (var i = 0; i < w.length && i < md.length; i++) {
          if (w[i] != 0) any = true;
        }
        if (any) {
          pos = Float32List.fromList(base);
          for (var i = 0; i < w.length && i < md.length; i++) {
            final wi = w[i];
            if (wi == 0) continue;
            final d = md[i];
            for (var k = 0; k < pos.length && k < d.length; k++) {
              pos[k] += d[k] * wi;
            }
          }
        }
      }
      if (p.skin >= 0 && p.skin < rig.skins.length && p.joints != null && p.weights != null) {
        final sk = rig.skins[p.skin];
        var mats = jm[p.skin];
        if (mats == null) {
          mats = Float64List(sk.joints.length * 16);
          final m = Float64List(16);
          for (var j = 0; j < sk.joints.length; j++) {
            final jw = pose.world(sk.joints[j]);
            mulInto(m, jw, 0, sk.ibm, j * 16);
            mats.setAll(j * 16, m);
          }
          jm[p.skin] = mats;
        }
        final jn = p.joints!, wt = p.weights!;
        for (var i = 0; i < n; i++) {
          final x = pos[i * 3], y = pos[i * 3 + 1], z = pos[i * 3 + 2];
          final nx = bn[i * 3], ny = bn[i * 3 + 1], nz = bn[i * 3 + 2];
          var ox = 0.0, oy = 0.0, oz = 0.0, onx = 0.0, ony = 0.0, onz = 0.0;
          for (var k = 0; k < 4; k++) {
            final w = wt[i * 4 + k];
            if (w == 0) continue;
            final o = jn[i * 4 + k] * 16;
            if (o + 15 >= mats.length) continue;
            ox += w * (mats[o] * x + mats[o + 4] * y + mats[o + 8] * z + mats[o + 12]);
            oy += w * (mats[o + 1] * x + mats[o + 5] * y + mats[o + 9] * z + mats[o + 13]);
            oz += w * (mats[o + 2] * x + mats[o + 6] * y + mats[o + 10] * z + mats[o + 14]);
            onx += w * (mats[o] * nx + mats[o + 4] * ny + mats[o + 8] * nz);
            ony += w * (mats[o + 1] * nx + mats[o + 5] * ny + mats[o + 9] * nz);
            onz += w * (mats[o + 2] * nx + mats[o + 6] * ny + mats[o + 10] * nz);
          }
          final l = math.sqrt(onx * onx + ony * ony + onz * onz);
          v[i * 6] = ox;
          v[i * 6 + 1] = oy;
          v[i * 6 + 2] = oz;
          if (l > 0) {
            v[i * 6 + 3] = onx / l;
            v[i * 6 + 4] = ony / l;
            v[i * 6 + 5] = onz / l;
          }
        }
      } else {
        for (var i = 0; i < n; i++) {
          v[i * 6] = pos[i * 3];
          v[i * 6 + 1] = pos[i * 3 + 1];
          v[i * 6 + 2] = pos[i * 3 + 2];
        }
      }
      final g = part.gpu;
      if (g is GpuMesh) g.update();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Barra de reproducción: animación, reproducir/pausar, línea de tiempo y velocidad.
class AnimationBar extends StatelessWidget {
  const AnimationBar(this.p, {super.key});
  final RigPlayer p;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final anims = p.rig.animations;
        final d = p.duration;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Glass(
              radius: 22,
              padding: const EdgeInsets.fromLTRB(8, 6, 14, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: p.playing ? p.pause : p.play,
                        icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30),
                      ),
                      Expanded(
                        child: Slider(
                          value: d <= 0 ? 0 : p.time.clamp(0, d).toDouble(),
                          max: d <= 0 ? 1 : d,
                          onChanged: d <= 0 ? null : p.seek,
                        ),
                      ),
                      Text(
                        '${p.time.toStringAsFixed(2)} / ${d.toStringAsFixed(2)} s',
                        style: const TextStyle(fontSize: 12, color: DT.muted, fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            isDense: true,
                            isExpanded: true,
                            value: p.current < 0 ? 0 : p.current,
                            dropdownColor: DT.surface2,
                            items: [
                              for (var i = 0; i < anims.length; i++)
                                DropdownMenuItem(value: i, child: Text(anims[i].name, overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (v) {
                              if (v != null) p.select(v);
                            },
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: p.loop ? tr('En bucle') : tr('Una vez'),
                        onPressed: p.toggleLoop,
                        icon: Icon(Icons.repeat_rounded, size: 20, color: p.loop ? DT.orange : DT.muted),
                      ),
                      for (final s in const [0.5, 1.0, 2.0])
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: ChoiceChip(
                            label: Text('${s == s.roundToDouble() ? s.toInt() : s}×'),
                            selected: p.speed == s,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => p.setSpeed(s),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
