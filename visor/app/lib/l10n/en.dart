// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'en_core.dart';
import 'en_io_cam.dart';
import 'en_io_mesh.dart';
import 'en_io_other.dart';
import 'en_ui_cam.dart';
import 'en_ui_main.dart';
import 'en_ui_tools.dart';

/// Traducciones al inglés: clave = texto en español del código.
/// Cada área añade las suyas en su propio archivo (`en_*.dart`) y se unen aquí.
final Map<String, String> kEn = {
  ...kEnCore,
  ...kEn_ui_main,
  ...kEn_ui_tools,
  ...kEn_ui_cam,
  ...kEn_io_cam,
  ...kEn_io_mesh,
  ...kEn_io_other,
};
