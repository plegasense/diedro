import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

import '../l10n/l10n.dart';
import '../src/datum_ffi.dart';
import 'las_loader.dart';
import 'mesh_data_extra.dart';

/// Lee un LAZ: la cabecera y los VLR los lee Dart; los registros los descomprime LASzip.
PointData parseLaz(String path, {int maxPoints = kMaxCloudPoints}) {
  try {
    return _parseLaz(path, maxPoints);
  } on FormatException {
    rethrow;
  } on Error catch (e) {
    throw FormatException(tr('El LAZ está dañado o cortado ({t})', {'t': e.runtimeType}));
  }
}

PointData _parseLaz(String path, int maxPoints) {
  final name = path.split('/').last;
  final f = File(path).openSync();
  final LasHeader h;
  try {
    h = readLasHeader(f);
  } finally {
    f.closeSync();
  }
  if (!h.compressed) return parseLas(path, maxPoints: maxPoints);
  final p = path.toNativeUtf8();
  final handle = datumLazOpen(p);
  malloc.free(p);
  if (handle == nullptr) {
    final e = datumLazError();
    throw FormatException(tr('No se pudo descomprimir el LAZ: {m}', {'m': tr(e == nullptr ? 'error desconocido' : e.toDartString())}));
  }
  Pointer<Uint8>? tmp;
  var tmpSize = 0;
  try {
    final n = datumLazCount(handle);
    if (n > 0) h.pointCount = n;
    final rl = h.recordLength;
    return readLasRecords(h, name, 'LAZ', maxPoints, (buf, want) {
      final need = want * rl;
      if (tmp == null || tmpSize < need) {
        if (tmp != null) malloc.free(tmp!);
        tmp = malloc<Uint8>(need);
        tmpSize = need;
      }
      final got = datumLazRead(handle, tmp!, math.min(want, buf.length ~/ rl));
      if (got > 0) buf.setRange(0, got * rl, tmp!.asTypedList(got * rl));
      return got;
    });
  } finally {
    if (tmp != null) malloc.free(tmp!);
    datumLazFree(handle);
  }
}
