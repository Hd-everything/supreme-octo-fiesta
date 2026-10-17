import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

class OutputHistoryEntry {
  const OutputHistoryEntry({required this.path, required this.name, required this.operation, required this.createdAt, this.width, this.height, this.durationMs, this.sourcePath});
  final String path, name, operation;
  final DateTime createdAt;
  final int? width, height, durationMs;
  final String? sourcePath;
  Map<String, dynamic> toJson() => {'path': path, 'name': name, 'operation': operation, 'createdAt': createdAt.toIso8601String(), 'width': width, 'height': height, 'durationMs': durationMs, 'sourcePath': sourcePath};
  factory OutputHistoryEntry.fromJson(Map<String, dynamic> json) => OutputHistoryEntry(path: json['path']?.toString() ?? '', name: json['name']?.toString() ?? 'Processed video', operation: json['operation']?.toString() ?? 'processed', createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(), width: (json['width'] as num?)?.toInt(), height: (json['height'] as num?)?.toInt(), durationMs: (json['durationMs'] as num?)?.toInt(), sourcePath: json['sourcePath']?.toString());
}

class OutputHistory {
  static const _key = 'output_history_v1';

  Future<List<OutputHistoryEntry>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final entries = (prefs.getStringList(_key) ?? const <String>[]).map((raw) => OutputHistoryEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>)).where((entry) => File(entry.path).existsSync()).toList();
    await _save(prefs, entries);
    return entries;
  }

  Future<void> add(OutputHistoryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await load();
    entries.removeWhere((item) => item.path == entry.path);
    entries.insert(0, entry);
    await _save(prefs, entries.take(50).toList());
  }

  Future<void> remove(OutputHistoryEntry entry, {bool deleteFile = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await load()..removeWhere((item) => item.path == entry.path);
    await _save(prefs, entries);
    if (deleteFile) {
      try { await File(entry.path).delete(); } catch (_) {}
    }
  }

  Future<void> _save(SharedPreferences prefs, List<OutputHistoryEntry> entries) => prefs.setStringList(_key, entries.map((entry) => jsonEncode(entry.toJson())).toList());
}
