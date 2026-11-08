import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../l10n/l10n.dart';

/// Una entrada del directorio central de un ZIP.
class ZipEntry {
  ZipEntry(this.name, this.method, this.csize, this.usize, this.offset);
  final String name;
  final int method; // 0 = almacenado, 8 = deflate
  final int csize, usize;
  final int offset; // de la cabecera local
}

/// Lector mínimo de ZIP (almacenado y deflate) que descomprime con zlib nativo y en
/// trozos: un 3MF de 50 MB trae modelos de más de 200 MB que no conviene tener enteros en memoria.
class ZipLite {
  ZipLite._(this._raf, this.entries);
  final RandomAccessFile _raf;
  final Map<String, ZipEntry> entries;

  static ZipLite open(String path) {
    final raf = File(path).openSync();
    try {
      final len = raf.lengthSync();
      if (len < 22) throw FormatException(tr('El archivo no es un ZIP'));
      final tailLen = len < 70000 ? len : 70000;
      raf.setPositionSync(len - tailLen);
      final tail = raf.readSync(tailLen);
      var e = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 &&
            tail[i + 1] == 0x4b &&
            tail[i + 2] == 5 &&
            tail[i + 3] == 6) {
          e = i;
          break;
        }
      }
      if (e < 0) throw FormatException(tr('El archivo no es un ZIP'));
      final bd = ByteData.sublistView(tail);
      var count = bd.getUint16(e + 10, Endian.little);
      var cdSize = bd.getUint32(e + 12, Endian.little);
      var cdOff = bd.getUint32(e + 16, Endian.little);
      if (cdOff == 0xFFFFFFFF || count == 0xFFFF) {
        // ZIP64: el localizador está justo antes del registro final.
        final l = e - 20;
        if (l >= 0 && bd.getUint32(l, Endian.little) == 0x07064b50) {
          final z64 = bd.getUint64(l + 8, Endian.little);
          raf.setPositionSync(z64);
          final h = ByteData.sublistView(raf.readSync(56));
          count = h.getUint64(32, Endian.little);
          cdSize = h.getUint64(40, Endian.little);
          cdOff = h.getUint64(48, Endian.little);
        }
      }
      raf.setPositionSync(cdOff);
      final cd = raf.readSync(cdSize);
      final c = ByteData.sublistView(cd);
      final map = <String, ZipEntry>{};
      var p = 0;
      for (var i = 0; i < count && p + 46 <= cd.length; i++) {
        if (c.getUint32(p, Endian.little) != 0x02014b50) break;
        final method = c.getUint16(p + 10, Endian.little);
        var csize = c.getUint32(p + 20, Endian.little);
        var usize = c.getUint32(p + 24, Endian.little);
        final nlen = c.getUint16(p + 28, Endian.little);
        final xlen = c.getUint16(p + 30, Endian.little);
        final clen = c.getUint16(p + 32, Endian.little);
        var off = c.getUint32(p + 42, Endian.little);
        final name = utf8.decode(
          cd.sublist(p + 46, p + 46 + nlen),
          allowMalformed: true,
        );
        if (usize == 0xFFFFFFFF || csize == 0xFFFFFFFF || off == 0xFFFFFFFF) {
          var x = p + 46 + nlen;
          final xe = x + xlen;
          while (x + 4 <= xe) {
            final id = c.getUint16(x, Endian.little);
            final sz = c.getUint16(x + 2, Endian.little);
            if (id == 1) {
              var q = x + 4;
              if (usize == 0xFFFFFFFF) {
                usize = c.getUint64(q, Endian.little);
                q += 8;
              }
              if (csize == 0xFFFFFFFF) {
                csize = c.getUint64(q, Endian.little);
                q += 8;
              }
              if (off == 0xFFFFFFFF) off = c.getUint64(q, Endian.little);
            }
            x += 4 + sz;
          }
        }
        if (!name.endsWith('/')) {
          map[name] = ZipEntry(name, method, csize, usize, off);
        }
        p += 46 + nlen + xlen + clen;
      }
      return ZipLite._(raf, map);
    } catch (_) {
      raf.closeSync();
      rethrow;
    }
  }

  void close() => _raf.closeSync();

  bool has(String name) => entries.containsKey(name);

  int _dataStart(ZipEntry e) {
    _raf.setPositionSync(e.offset);
    final h = ByteData.sublistView(_raf.readSync(30));
    if (h.getUint32(0, Endian.little) != 0x04034b50) {
      throw FormatException(tr('ZIP dañado'));
    }
    return e.offset + 30 + h.getUint16(26, Endian.little) + h.getUint16(28, Endian.little);
  }

  /// Entrega el contenido descomprimido en trozos.
  void stream(String name, void Function(Uint8List chunk) onChunk) {
    final e = entries[name];
    if (e == null) throw FormatException(tr('Falta {n}', {'n': name}));
    var pos = _dataStart(e);
    var left = e.csize;
    if (e.method == 0) {
      while (left > 0) {
        _raf.setPositionSync(pos);
        final n = left < 1 << 20 ? left : 1 << 20;
        onChunk(_raf.readSync(n));
        pos += n;
        left -= n;
      }
      return;
    }
    if (e.method != 8) throw FormatException(tr('Compresión ZIP no soportada ({m})', {'m': e.method}));
    final sink = _ChunkSink(onChunk);
    final conv = ZLibDecoder(raw: true).startChunkedConversion(sink);
    while (left > 0) {
      _raf.setPositionSync(pos);
      final n = left < 256 * 1024 ? left : 256 * 1024;
      conv.add(_raf.readSync(n));
      pos += n;
      left -= n;
    }
    conv.close();
  }

  Uint8List read(String name) {
    final b = BytesBuilder(copy: false);
    stream(name, b.add);
    return b.takeBytes();
  }

  String? text(String name) {
    if (!entries.containsKey(name)) return null;
    return utf8.decode(read(name), allowMalformed: true);
  }
}

class _ChunkSink extends ByteConversionSinkBase {
  _ChunkSink(this.f);
  final void Function(Uint8List) f;
  @override
  void add(List<int> chunk) =>
      f(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
  @override
  void close() {}
}
