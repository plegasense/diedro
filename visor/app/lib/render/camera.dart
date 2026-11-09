// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../model/mesh.dart';

/// Cámara orbital con eje Z hacia arriba (convención CAD).
class OrbitCamera extends ChangeNotifier {
  vm.Vector3 target = vm.Vector3.zero();
  double distance = 10;
  double yaw = -math.pi / 4; // giro alrededor de Z
  double pitch = math.pi / 6; // elevación
  double fovY = vm.radians(40);
  double sceneRadius = 1;
  double aspect = 1; // ancho / alto de la vista; se actualiza desde la interfaz
  bool ortho = false; // proyección ortogonal (dibujos 2D)
  bool orbitEnabled = true;

  /// Fuerza un repintado (p. ej. tras cambiar colores).
  void touch() => notifyListeners();

  void fit(Bounds b) {
    final c = b.center;
    target = vm.Vector3(c[0], c[1], c[2]);
    sceneRadius = math.max(b.radius, 1e-6);
    // En vertical (móvil) manda el campo de visión horizontal, que es más estrecho.
    final asp = aspect.isFinite && aspect > 0 ? aspect : 0.5;
    final half = math.atan(math.tan(fovY / 2) * math.min(1.0, asp));
    distance = ortho
        ? sceneRadius / math.tan(half) * 1.32
        : sceneRadius / math.sin(half) * 1.22;
    notifyListeners();
  }

  void orbit(double dx, double dy) {
    if (!orbitEnabled) return;
    yaw -= dx * 0.008;
    pitch = (pitch + dy * 0.008).clamp(-math.pi / 2 + 0.01, math.pi / 2 - 0.01);
    notifyListeners();
  }

  void zoom(double factor) {
    distance = (distance / factor).clamp(sceneRadius * 0.02, sceneRadius * 60);
    notifyListeners();
  }

  void pan(double dx, double dy, double viewportHeight) {
    final scale = 2 * distance * math.tan(fovY / 2) / viewportHeight;
    final right = _right();
    final up = _upVec();
    target += right * (-dx * scale) + up * (dy * scale);
    notifyListeners();
  }

  void setView(double newYaw, double newPitch) {
    yaw = newYaw;
    pitch = newPitch;
    notifyListeners();
  }

  vm.Vector3 get eye {
    final cp = math.cos(pitch);
    return target +
        vm.Vector3(math.cos(yaw) * cp, math.sin(yaw) * cp, math.sin(pitch)) *
            distance;
  }

  vm.Vector3 _forward() => (target - eye)..normalize();
  vm.Vector3 _right() => _forward().cross(vm.Vector3(0, 0, 1))..normalize();
  vm.Vector3 _upVec() => _right().cross(_forward())..normalize();

  vm.Matrix4 viewMatrix() =>
      vm.makeViewMatrix(eye, target, vm.Vector3(0, 0, 1));

  /// Desplazamiento horizontal de la imagen (en coordenadas normalizadas) para dejar libre la barra de herramientas.
  double ndcShiftX = 0;

  /// Planos cercano y lejano de la proyección en perspectiva (para la pasada de profundidad).
  (double, double) get nearFar {
    final near = math.max(distance - sceneRadius * 1.5, distance * 0.01);
    return (near, distance + sceneRadius * 3);
  }

  vm.Matrix4 projection(double aspect) {
    final base = _projection(aspect);
    if (ndcShiftX == 0) return base;
    return vm.Matrix4.translationValues(ndcShiftX, 0, 0) * base;
  }

  vm.Matrix4 _projection(double aspect) {
    if (ortho) {
      final hh = distance * math.tan(fovY / 2), hw = hh * aspect;
      // Profundidad en [0, 1] (Vulkan/Metal). La matriz estilo OpenGL ([-1, 1]) dejaba fuera
      // la mitad del volumen: en una tableta con Vulkan los dibujos salían en blanco.
      final n = distance * 0.01, f = distance + sceneRadius * 4;
      return vm.Matrix4(
        1 / hw,
        0,
        0,
        0, //
        0,
        1 / hh,
        0,
        0,
        0,
        0,
        1 / (n - f),
        0,
        0,
        0,
        n / (n - f),
        1,
      );
    }
    final near = math.max(distance - sceneRadius * 1.5, distance * 0.01);
    final far = distance + sceneRadius * 3;
    return _perspectiveZeroToOne(fovY, aspect, near, far);
  }

  /// Dirección de la luz principal: sale de la cámara, algo desplazada.
  vm.Vector3 lightDir() {
    final f = _forward();
    final r = _right();
    final u = _upVec();
    return (-f + r * -0.35 + u * 0.55)..normalize();
  }
}

/// Perspectiva con profundidad en [0, 1] (Metal/Vulkan), vista hacia -Z.
vm.Matrix4 _perspectiveZeroToOne(
  double fovY,
  double aspect,
  double near,
  double far,
) {
  final f = 1 / math.tan(fovY / 2);
  return vm.Matrix4(
    f / aspect,
    0,
    0,
    0,
    0,
    f,
    0,
    0,
    0,
    0,
    far / (near - far),
    -1,
    0,
    0,
    near * far / (near - far),
    0,
  );
}
