import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Archivos abiertos recientemente (se guardan en el propio dispositivo).
class RecentFile {
  RecentFile(this.path, this.name, this.openedAt);
  final String path;
  final String name;
  final DateTime openedAt;

  String get ext =>
      name.contains('.') ? name.split('.').last.toLowerCase() : '';
}

class RecentsStore {
  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/recientes.json');
  }

  static Future<List<RecentFile>> load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return [];
      final list = jsonDecode(await f.readAsString()) as List;
      return [
        for (final e in list)
          if (File(e['path'] as String).existsSync())
            RecentFile(
              e['path'] as String,
              e['name'] as String,
              DateTime.parse(e['at'] as String),
            ),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> add(String path) async {
    try {
      final all = await load();
      all.removeWhere((r) => r.path == path);
      all.insert(0, RecentFile(path, path.split('/').last, DateTime.now()));
      final f = await _file();
      await f.writeAsString(
        jsonEncode([
          for (final r in all.take(12))
            {'path': r.path, 'name': r.name, 'at': r.openedAt.toIso8601String()},
        ]),
      );
    } catch (_) {}
  }
}
