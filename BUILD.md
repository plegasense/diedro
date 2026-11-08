# Compilar Diedro (Android arm64)

Requisitos: Android SDK/NDK r28, JDK 17+, Gradle 9, Flutter (canal con Flutter GPU) y una instalación estática de **OpenCASCADE 7.9.x para android-arm64** (módulos de `OCCT_LIBS` en `core/CMakeLists.txt`).

1. `android/local.properties`: `sdk.dir=<ruta SDK>` y `occt.dir=<carpeta install de OCCT arm64>`.
2. Visor: `cd visor/app && flutter build aar --release --target-platform android-arm64 --no-debug --no-profile` (genera el repositorio Maven local que usa `android/settings.gradle.kts`).
3. APK: `cd android && gradle assembleRelease`. Sin `~/.diedro-keys/keystore.properties` el APK sale sin firmar.

Los textos de interfaz están en `i18n/strings.tsv` (copia en `android/app/src/main/assets/`).
