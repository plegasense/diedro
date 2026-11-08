# Diedro — Licencias de los componentes

Diedro se distribuye bajo **GNU GPL v3.0 o posterior** (ver `LICENSE`). Este documento resume las licencias de lo que incorpora. No es asesoramiento jurídico.

| Componente | Licencia | Notas |
|---|---|---|
| Código de Diedro (`core/`, `android/`, `visor/app/lib`, `i18n/`) | GPL-3.0-or-later | |
| Open CASCADE Technology 7.9.x | LGPL 2.1 + excepción Open CASCADE | Enlazado estáticamente, sin modificar. La LGPL 2.1 (§3) permite aplicar la GPL a la biblioteca; el programa completo se distribuye bajo GPL-3.0. Aviso de uso de OCCT visible en la app (Ajustes → Licencias y privacidad). |
| osifont (subconjunto, `core/src/font_osifont.cpp`) | GPL v2 con excepción de fuente | Los PDF generados con la fuente incrustada no quedan cubiertos por la GPL por ello. |
| Noto Sans / Noto Sans CJK (contornos en `core/src/notice_paths.cpp`) | SIL OFL 1.1 | Solo para los avisos en ja/ko/zh/th/hi. |
| Plantilla DXF R2000 (`core/src/dxf_skel.inc`) | MIT (ezdxf, © 2020 Manfred Moitzi) | Derivada de la salida de ezdxf; se conserva el aviso de copyright. |
| LLVM libc++ (NDK) | Apache 2.0 con excepción LLVM | |
| Flutter, Dart y paquetes de pub (`visor/app/pubspec.yaml`) | BSD-3-Clause y otras | Textos en la pantalla de licencias de Flutter. |

## Qué NO contiene este repositorio
Piezas CAD de terceros o de clientes, textos de normas con copyright (se citan cláusulas, no se reproducen), claves de firma ni datos personales.
