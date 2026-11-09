// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'package:flutter/material.dart';

/// Sistema de diseño de Datum: tinta oscura, grises azulados y un acento naranja.
class DT {
  static const ink = Color(0xFF0A1214);
  static const surface = Color(0xFF101B1F);
  static const surface2 = Color(0xFF16252A);
  static const border = Color(0x1FFFFFFF);
  static const text = Color(0xFFEAF3F4);
  static const muted = Color(0xFF8DA5A9);
  static const orange = Color(0xFFFB923C);
  static const orangeSoft = Color(0xFFFDBA74);
  static const mint = Color(0xFF5EEAD4);
  static const glass = Color(0xEB101B1F);

  static ThemeData theme() {
    const scheme = ColorScheme.dark(
      primary: orange,
      onPrimary: ink,
      secondary: mint,
      onSecondary: ink,
      surface: surface,
      onSurface: text,
      surfaceContainerHighest: surface2,
      outline: border,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: ink,
      canvasColor: surface,
      splashFactory: InkSparkle.splashFactory,
      textTheme: Typography.whiteMountainView.apply(
        bodyColor: text,
        displayColor: text,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(left: Radius.circular(24)),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: orange,
        inactiveTrackColor: const Color(0x33FFFFFF),
        thumbColor: orangeSoft,
        overlayColor: orange.withValues(alpha: 0.18),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0x14FFFFFF),
        selectedColor: orange.withValues(alpha: 0.22),
        side: const BorderSide(color: border),
        shape: const StadiumBorder(),
        labelStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
        ),
        showCheckmark: false,
      ),
      tabBarTheme: const TabBarThemeData(
        indicatorColor: orange,
        labelColor: text,
        unselectedLabelColor: muted,
        dividerColor: border,
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: const Color(0x0DFFFFFF),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(color: muted),
      ),
    );
  }
}
