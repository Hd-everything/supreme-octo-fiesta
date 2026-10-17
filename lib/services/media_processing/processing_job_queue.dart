import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

enum ProcessingJobState { queued, preparing, decoding, enhancing, encoding, verifying, paused, complete, cancelled, failed }

class ProcessingJob {
  ProcessingJob({required this.id, required this.inputPath, required this.outputPath, required this.operation, required this.createdAt, this.state = ProcessingJobState.queued, this.progress = 0, this.message = '', this.error});

  final String id;
  final String inputPath;
  final String outputPath;
  final String operation;
  final DateTime createdAt;
  ProcessingJobState state;
  double progress;
  String message;
  String? error;

  bool get terminal => const {ProcessingJobState.complete, ProcessingJobState.cancelled, ProcessingJobState.failed}.contains(state);

  Map<String, dynamic> toJson() => {'id': id, 'inputPath': inputPath, 'outputPath': outputPath, 'operation': operation, 'createdAt': createdAt.toIso8601String(), 'state': state.name, 'progress': progress, 'message': message, 'error': error};

  factory ProcessingJob.fromJson(Map<String, dynamic> json) => ProcessingJob(
        id: json['id']?.toString() ?? '', inputPath: json['inputPath']?.toString() ?? '', outputPath: json['outputPath']?.toString() ?? '', operation: json['operation']?.toString() ?? 'video', createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? DateTime.now(), state: ProcessingJobState.values.firstWhere((v) => v.name == json['state'], orElse: () => ProcessingJobState.failed), progress: (json['progress'] as num?)?.toDouble() ?? 0, message: json['message']?.toString() ?? '', error: json['error']?.toString());
}

/// Persistent queue shared by StatusHD and Movie Player. Native processing
/// remains the executor; this class owns lifecycle, recovery, and honest UI
/// state so an interrupted job is never shown as completed.
class ProcessingJobQueue extends ChangeNotifier {
  ProcessingJobQueue({SharedPreferences? preferences}) : _preferences = preferences;
  static const _key = 'processing_jobs_v1';
  SharedPreferences? _preferences;
  final List<ProcessingJob> _jobs = [];
  Timer? _cleanupTimer;

  List<ProcessingJob> get jobs => List.unmodifiable(_jobs);

  Future<void> load() async {
    _preferences ??= await SharedPreferences.getInstance();
    _jobs
      ..clear()
      ..addAll((_preferences!.getStringList(_key) ?? const <String>[]).map((raw) => ProcessingJob.fromJson(jsonDecode(raw) as Map<String, dynamic>)));
    for (final job in _jobs.where((job) => !job.terminal)) {
      job.state = ProcessingJobState.paused;
      job.message = 'Recovered after the app closed. Resume when ready.';
    }
    await _persist();
    _cleanupTimer ??= Timer.periodic(const Duration(hours: 6), (_) => cleanup());
    notifyListeners();
  }

  Future<void> add(ProcessingJob job) async { _jobs.insert(0, job); await _persist(); notifyListeners(); }
  Future<void> update(String id, {ProcessingJobState? state, double? progress, String? message, String? error}) async {
    final job = _jobs.firstWhere((item) => item.id == id);
    if (state != null) job.state = state;
    if (progress != null) job.progress = progress.clamp(0, 1);
    if (message != null) job.message = message;
    if (error != null) job.error = error;
    await _persist(); notifyListeners();
  }

  Future<void> cancel(String id) => update(id, state: ProcessingJobState.cancelled, message: 'Cancelled');
  Future<void> pause(String id) => update(id, state: ProcessingJobState.paused, message: 'Paused; the source is unchanged.');
  Future<void> remove(String id) async { _jobs.removeWhere((job) => job.id == id); await _persist(); notifyListeners(); }

  Future<void> cleanup() async {
    final cutoff = DateTime.now().subtract(const Duration(days: 3));
    _jobs.removeWhere((job) => job.terminal && job.createdAt.isBefore(cutoff));
    await _persist(); notifyListeners();
  }

  Future<void> _persist() async {
    _preferences ??= await SharedPreferences.getInstance();
    await _preferences!.setStringList(_key, _jobs.map((job) => jsonEncode(job.toJson())).toList());
  }

  @override
  void dispose() { _cleanupTimer?.cancel(); super.dispose(); }
}
