# Diedro — Licencias de los componentes

Diedro se distribuye bajo **GNU GPL v3.0 o posterior** (ver `LICENSE`). Este documento resume las licencias de lo que incorpora. No es asesoramiento jurídico.

| Componente | Licencia | Notas |
|---|---|---|
| Código de Diedro (`core/`, `android/`, `visor/app/lib`, `i18n/`) | GPL-3.0-or-later | |
| Open CASCADE Technology 7.9.x | LGPL 2.1 + excepción Open CASCADE | Enlazado estáticamente, sin modificar. La LGPL 2.1 (§3) permite aplicar la GPL a la biblioteca; el programa completo se distribuye bajo GPL-3.0. Aviso de uso de OCCT visible en la app (Ajustes → Licencias y privacidad). |
| osifont (variante osifont-lgpl3fe, subconjunto con 7 glifos propios, `core/src/font_osifont.cpp`) | LGPL v3 con excepción de fuente GPL (compatible con la GPL-3.0 de Diedro) | Los PDF generados con la fuente incrustada no quedan cubiertos por la GPL por ello. |
| Noto Sans / Noto Sans CJK (contornos en `core/src/notice_paths.cpp`) | SIL OFL 1.1 | Solo para los avisos en ja/ko/zh/th/hi. |
| Plantilla DXF R2000 (`core/src/dxf_skel.inc`) | MIT (ezdxf, © 2020 Manfred Moitzi) | Derivada de la salida de ezdxf; se conserva el aviso de copyright. |
| LLVM libc++ (NDK) | Apache 2.0 con excepción LLVM | |
| Flutter, Dart y paquetes de pub (`visor/app/pubspec.yaml`) | BSD-3-Clause, MIT, Apache-2.0 y otras permisivas | Textos completos en `LICENSES/THIRD_PARTY_NOTICES-flutter.txt` (el mismo fichero va dentro del APK) y resumen en Ajustes → Licencias y privacidad. |

## Qué NO contiene este repositorio
Piezas CAD de terceros o de clientes, textos de normas con copyright (se citan cláusulas, no se reproducen), claves de firma ni datos personales.

## Textos de licencia incluidos en `LICENSES/`
`LGPL-2.1.txt` y `OCCT-LGPL-exception.txt` (Open CASCADE 7.9.3, compilable sin modificar con `tools/build_occt_android.sh`; el enlazado estático permite reenlazar con otra versión recompilando Diedro), `LGPL-3.0.txt` y `osifont-NOTICE.txt` (fuente), `OFL-1.1-Noto.txt`, `LLVM-libcxx-LICENSE.txt`, `THIRD_PARTY_NOTICES-flutter.txt` (Flutter, Dart y paquetes). El texto de GPL-3.0 está en `LICENSE` y el de ezdxf (MIT) en `NOTICE`.
