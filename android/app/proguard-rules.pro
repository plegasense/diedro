-keep class app.diedro.planos.Native { *; }

# Visor 3D (módulo Flutter): plugins cargados por reflexión
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }
-keep class com.github.dart_lang.** { *; }
-keep class com.mr.flutter.** { *; }
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-dontwarn com.google.android.play.core.**
