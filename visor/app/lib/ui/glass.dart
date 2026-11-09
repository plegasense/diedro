// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:ui';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Superficie translúcida para barras y tarjetas flotantes.
///
/// Sin desenfoque de fondo: en tabletas Android medianas (Mali-G57, 2560×1600) el
/// `BackdropFilter` sobre una vista 3D que cambia cada fotograma costaba unos 35 ms.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 22,
    this.padding = EdgeInsets.zero,
    this.color,
  });
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? DT.glass,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: DT.border),
      ),
      child: child,
    );
  }
}

/// Botón de icono para las barras flotantes.
class ToolButton extends StatelessWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 26,
        child: Container(
          width: 46,
          height: 46,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: active
                ? DT.orange.withValues(alpha: 0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            icon,
            size: 22,
            color: active ? DT.orangeSoft : DT.text.withValues(alpha: 0.86),
          ),
        ),
      ),
    );
  }
}

/// Pequeña etiqueta de información (icono + texto).
class InfoChip extends StatelessWidget {
  const InfoChip(this.icon, this.label, {super.key, this.color});
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? DT.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: c,
              fontWeight: FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
