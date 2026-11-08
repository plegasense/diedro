# Compilar Diedro (Android arm64)

Requisitos: Android SDK/NDK r28, JDK 17+, Gradle 9, Flutter 3.47 (canal stable, con Flutter GPU) y CMake 3.22.1. Diedro usa **OpenCASCADE 7.9.3 (etiqueta `V7_9_3`) sin modificar**, estático para android-arm64.

0. OCCT: `tools/build_occt_android.sh <carpeta de trabajo>` (clona la etiqueta V7_9_3 y la compila con los parámetros exactos de Diedro; tarda un buen rato).
1. `android/local.properties`: `sdk.dir=<ruta SDK>` y `occt.dir=<carpeta install de OCCT arm64>`.
2. Visor: `cd visor/app && flutter build aar --release --target-platform android-arm64 --no-debug --no-profile` (genera el repositorio Maven local que usa `android/settings.gradle.kts`).
3. APK: `cd android && gradle assembleRelease`. Sin `~/.diedro-keys/keystore.properties` el APK sale sin firmar.

Los textos de interfaz están en `i18n/strings.tsv` (copia en `android/app/src/main/assets/`).
