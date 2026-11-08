import 'dart:async';
import 'dart:isolate';

import '../l10n/l10n.dart';

/// Como `Isolate.run`, pero el isolate nuevo hereda el idioma de la interfaz (los campos estáticos no se
/// comparten entre isolates), de modo que los avisos y errores de los lectores salen ya traducidos.
Future<T> isoRun<T>(FutureOr<T> Function() f) {
  final lang = L.lang;
  return Isolate.run(() {
    L.lang = lang;
    return f();
  });
}
