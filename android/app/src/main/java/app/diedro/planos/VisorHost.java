package app.diedro.planos;

import android.content.Context;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.plugin.common.MethodChannel;

/** Motor Flutter único del visor 3D de Datum (módulo `visor/app`); se crea al primer uso y se reutiliza. */
final class VisorHost {
    static FlutterEngine engine;
    static MethodChannel ch;
    static String loaded;

    static MethodChannel channel(Context c) {
        if (engine == null) {
            engine = new FlutterEngine(c.getApplicationContext());
            engine.getDartExecutor().executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault());
            ch = new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "diedro/visor");
        }
        return ch;
    }
}
