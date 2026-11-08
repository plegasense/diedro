import 'dart:ui' as ui;

/// Programa de sombreado de borde (Eye-Dome Lighting), cargado una vez desde `fx/edl.frag`.
class EdlFx {
  static ui.FragmentProgram? _program;
  static bool _loading = false;
  static bool failed = false;

  static ui.FragmentProgram? get program => _program;

  static Future<void> load() async {
    if (_program != null || _loading) return;
    _loading = true;
    try {
      _program = await ui.FragmentProgram.fromAsset('fx/edl.frag');
    } catch (_) {
      failed = true;
    } finally {
      _loading = false;
    }
  }
}
