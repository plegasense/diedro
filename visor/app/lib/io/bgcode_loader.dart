// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Plegasense
import 'dart:io';
import 'dart:typed_data';

import '../l10n/l10n.dart';
import 'iso_run.dart';
import 'gcode_loader.dart';

/// Descompresión heatshrink (LZSS) usada por el G-code binario de Prusa.
/// Parámetros: ventana de 2^[windowBits] bytes y anticipación de 2^[lookaheadBits].
Uint8List heatshrinkDecode(
  Uint8List input,
  int windowBits,
  int lookaheadBits,
  int expectedSize,
) {
  final out = Uint8List(expectedSize);
  var o = 0;
  var bytePos = 0;
  var bitMask = 0;
  var cur = 0;
  // Lee [n] bits (el más significativo primero); -1 si se acaban los datos.
  int bits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      if (bitMask == 0) {
        if (bytePos >= input.length) return -1;
        cur = input[bytePos++];
        bitMask = 0x80;
      }
      v = (v << 1) | ((cur & bitMask) != 0 ? 1 : 0);
      bitMask >>= 1;
    }
    return v;
  }

  while (o < expectedSize) {
    final tag = bits(1);
    if (tag < 0) break;
    if (tag == 1) {
      final b = bits(8);
      if (b < 0) break;
      out[o++] = b;
    } else {
      final idx = bits(windowBits);
      if (idx < 0) break;
      final cnt = bits(lookaheadBits);
      if (cnt < 0) break;
      final offset = idx + 1;
      final count = cnt + 1;
      for (var k = 0; k < count && o < expectedSize; k++) {
        out[o] = o - offset >= 0 ? out[o - offset] : 0;
        o++;
      }
    }
  }
  return Uint8List.sublistView(out, 0, o);
}

/// Decodificación de MeatPack (con o sin comentarios), según el formato de Prusa.
Uint8List meatpackDecode(Uint8List input) {
  final out = BytesBuilder(copy: false);
  var unpacking = false;
  var noSpaces = false;
  String? charOf(int nib) {
    switch (nib) {
      case 0xA:
        return '.';
      case 0xB:
        return noSpaces ? 'E' : ' ';
      case 0xC:
        return '\n';
      case 0xD:
        return 'G';
      case 0xE:
        return 'X';
      case 0xF:
        return null;
      default:
        return nib.toString();
    }
  }

  var i = 0;
  final n = input.length;
  while (i < n) {
    final b = input[i];
    if (b == 0xFF && i + 2 < n && input[i + 1] == 0xFF) {
      final cmd = input[i + 2];
      i += 3;
      switch (cmd) {
        case 251:
          unpacking = true;
        case 250:
          unpacking = false;
        case 249:
          unpacking = false;
          noSpaces = false;
        case 247:
          noSpaces = true;
        case 246:
          noSpaces = false;
      }
      continue;
    }
    i++;
    if (!unpacking) {
      out.addByte(b);
      continue;
    }
    final lo = b & 0xF, hi = (b >> 4) & 0xF;
    final c1 = charOf(lo), c2 = charOf(hi);
    if (c1 != null && c2 != null) {
      out.addByte(c1.codeUnitAt(0));
      if (c1 != '\n') out.addByte(c2.codeUnitAt(0));
    } else if (c1 == null && c2 != null) {
      if (i < n) out.addByte(input[i++]);
      out.addByte(c2.codeUnitAt(0));
    } else if (c1 != null && c2 == null) {
      out.addByte(c1.codeUnitAt(0));
      if (i < n) out.addByte(input[i++]);
    } else {
      if (i < n) out.addByte(input[i++]);
      if (i < n) out.addByte(input[i++]);
    }
  }
  return out.takeBytes();
}

/// Lee un G-code binario de Prusa (.bgcode) y lo convierte en trayectorias.
GcodeData parseBgcode(String path) {
  final bytes = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  if (bytes.length < 10 ||
      bytes[0] != 0x47 ||
      bytes[1] != 0x43 ||
      bytes[2] != 0x44 ||
      bytes[3] != 0x45) {
    throw Exception(tr('No es un archivo .bgcode válido'));
  }
  final version = bd.getUint32(4, Endian.little);
  if (version != 1)
    throw Exception(tr('Versión de .bgcode no soportada: {v}', {'v': version}));
  final checksum = bd.getUint16(8, Endian.little);
  var pos = 10;
  final gcode = BytesBuilder(copy: false);
  final info = <String>[];
  final meta = <String, String>{};
  Uint8List? thumb;
  var thumbFmt = 0;

  while (pos + 8 <= bytes.length) {
    final type = bd.getUint16(pos, Endian.little);
    final comp = bd.getUint16(pos + 2, Endian.little);
    final usize = bd.getUint32(pos + 4, Endian.little);
    var hdr = 8;
    var csize = usize;
    if (comp != 0) {
      csize = bd.getUint32(pos + 8, Endian.little);
      hdr = 12;
    }
    final paramSize = type == 5 ? 6 : 2;
    final encoding = type == 5 ? 0 : bd.getUint16(pos + hdr, Endian.little);
    final dataStart = pos + hdr + paramSize;
    final dataEnd = dataStart + csize;
    if (dataEnd > bytes.length) break;
    pos = dataEnd + (checksum == 1 ? 4 : 0);
    if (type == 5) {
      if (comp != 0) continue;
      final fmt = bd.getUint16(dataStart - 6, Endian.little);
      final raw = Uint8List.sublistView(bytes, dataStart, dataEnd);
      if (thumb == null || raw.length > thumb.length) {
        thumb = Uint8List.fromList(raw);
        thumbFmt = fmt;
      }
      continue;
    }
    var data = Uint8List.sublistView(bytes, dataStart, dataEnd);
    data = switch (comp) {
      0 => data,
      1 => Uint8List.fromList(ZLibCodec().decode(data)),
      2 => heatshrinkDecode(data, 11, 4, usize),
      3 => heatshrinkDecode(data, 12, 4, usize),
      _ => throw Exception(tr('Compresión .bgcode desconocida: {c}', {'c': comp})),
    };
    if (type == 1) {
      gcode.add(encoding == 0 ? data : meatpackDecode(data));
    } else {
      // Metadatos en formato INI: clave=valor
      for (final line in String.fromCharCodes(data).split('\n')) {
        final l = line.trim();
        if (l.isNotEmpty && l.contains('=')) {
          final eq = l.indexOf('=');
          meta.putIfAbsent(
            l.substring(0, eq).trim().toLowerCase(),
            () => l.substring(eq + 1).trim(),
          );
          if (info.length < 80) info.add(l.replaceFirst('=', ': '));
        }
      }
    }
  }
  final data = gcode.takeBytes();
  if (data.isEmpty) throw Exception(tr('El .bgcode no contiene G-code'));
  return parseGcode(
    data,
    path.split('/').last,
    extraInfo: info,
    extraMeta: meta,
    extraThumb: thumb,
    extraThumbFormat: thumbFmt,
  );
}

Future<GcodeData> loadBgcode(String path) => isoRun(() {
  try {
    return parseBgcode(path);
  } on FormatException {
    throw Exception(
      tr('El archivo .bgcode está dañado (bloque comprimido no válido)'),
    );
  } on RangeError {
    throw Exception(tr('El archivo .bgcode está incompleto o dañado'));
  }
});
