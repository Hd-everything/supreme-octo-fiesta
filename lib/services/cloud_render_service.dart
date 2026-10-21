import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/edit_project.dart';
import 'supabase_config.dart';

class CloudRenderException implements Exception {
  const CloudRenderException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CloudRenderProgress {
  const CloudRenderProgress({required this.stage, required this.progress, this.message});
  final String stage;
  final double progress;
  final String? message;
}

class CloudRenderService {
  CloudRenderService(this.client, {this.preferences});

  static const bucket = 'vyntra-media';
  static const historyKey = 'vyntra_cloud_render_jobs_v1';
  final SupabaseClient client;
  final SharedPreferences? preferences;

  bool get isSignedIn => client.auth.currentUser != null;

  Future<Map<String, dynamic>> capabilities() => _invoke({'action': 'capabilities'});

  Future<void> signIn(String email, String password) async {
    final result = await client.auth.signInWithPassword(email: email.trim(), password: password);
    if (result.user == null) throw const CloudRenderException('Sign-in did not return a user.');
  }

  Future<void> signUp(String email, String password) async {
    final result = await client.auth.signUp(email: email.trim(), password: password);
    if (result.session == null) {
      throw const CloudRenderException('Check your email to confirm the account, then sign in before cloud export.');
    }
  }

  Future<Map<String, dynamic>> renderProject({
    required EditProject project,
    required String resolution,
    String codec = 'h264',
    int quality = 23,
    required void Function(CloudRenderProgress) onProgress,
  }) async {
    if (!isSignedIn) throw const CloudRenderException('Sign in to Supabase before starting a cloud export.');
    final available = await capabilities();
    if (available['workerReady'] != true) {
      throw const CloudRenderException('Cloud rendering is not available yet: the FFmpeg worker has not been deployed and verified.');
    }
    final resolutions = (available['resolutions'] as List? ?? const []).cast<String>();
    if (!resolutions.contains(resolution)) throw CloudRenderException('The deployed worker does not support $resolution export.');
    final objectPaths = <String, String>{};
    final localPaths = <String>{};
    for (final clip in project.clips) { localPaths.add(clip.path); }
    if (project.musicPath != null && project.musicPath!.isNotEmpty) localPaths.add(project.musicPath!);
    for (final overlay in project.imageOverlays) { localPaths.add(overlay.path); }
    if (localPaths.isEmpty) throw const CloudRenderException('This project has no source media.');

    var uploaded = 0;
    for (final localPath in localPaths) {
      final file = File(localPath);
      if (!await file.exists()) throw CloudRenderException('A source file is missing: ${p.basename(localPath)}');
      final bytes = await file.length();
      final mime = _mimeFor(localPath);
      onProgress(CloudRenderProgress(stage: 'uploading', progress: .05 + .30 * uploaded / localPaths.length, message: 'Preparing media ${uploaded + 1} of ${localPaths.length}'));
      final prepared = await _invoke({
        'action': 'prepare_upload',
        'fileName': p.basename(localPath),
        'contentType': mime,
        'sizeBytes': bytes,
      });
      final objectPath = prepared['path'] as String?;
      final token = prepared['token'] as String?;
      if (objectPath == null || token == null) throw const CloudRenderException('The server did not return a secure upload destination.');
      try {
        await client.storage.from(bucket).uploadToSignedUrl(
          objectPath, token, file,
          fileOptions: FileOptions(contentType: mime, upsert: false),
        );
      } catch (_) {
        throw CloudRenderException('Upload failed for ${p.basename(localPath)}. Check your connection and retry.');
      }
      objectPaths[localPath] = objectPath;
      uploaded++;
      onProgress(CloudRenderProgress(stage: 'uploading', progress: .05 + .30 * uploaded / localPaths.length, message: 'Uploaded $uploaded of ${localPaths.length} media files'));
    }

    final snapshot = Map<String, dynamic>.from(project.toJson());
    snapshot['clips'] = (snapshot['clips'] as List).map((raw) {
      final clip = Map<String, dynamic>.from(raw as Map);
      clip['path'] = objectPaths[clip['path']]!;
      return clip;
    }).toList();
    if (snapshot['musicPath'] is String && (snapshot['musicPath'] as String).isNotEmpty) snapshot['musicPath'] = objectPaths[snapshot['musicPath']];
    snapshot['imageOverlays'] = (snapshot['imageOverlays'] as List).map((raw) {
      final overlay = Map<String, dynamic>.from(raw as Map);
      overlay['path'] = objectPaths[overlay['path']]!;
      return overlay;
    }).toList();

    final idempotencyKey = '${project.id}-${project.updatedAt.microsecondsSinceEpoch}-${resolution}';
    onProgress(const CloudRenderProgress(stage: 'queued', progress: .38, message: 'Submitting render job'));
    final created = await _invoke({
      'action': 'create_job',
      'projectId': project.id,
      'idempotencyKey': idempotencyKey,
      'projectSnapshot': snapshot,
      'resolution': resolution,
      'codec': codec,
      'quality': quality,
    });
    var job = Map<String, dynamic>.from(created['job'] as Map);
    await _rememberJob(job);
    final jobId = job['id'] as String;
    onProgress(const CloudRenderProgress(stage: 'queued', progress: .40, message: 'Waiting for cloud worker'));

    while (true) {
      await Future<void>.delayed(const Duration(seconds: 3));
      final statusResponse = await _invoke({'action': 'status', 'jobId': jobId});
      job = Map<String, dynamic>.from(statusResponse['job'] as Map);
      await _rememberJob(job);
      final status = job['status'] as String? ?? 'failed';
      final realProgress = (job['progress'] as num?)?.toDouble() ?? 0;
      if (status == 'failed') throw CloudRenderException(_friendlyError(job['error_code']?.toString()));
      if (status == 'cancelled') throw const CloudRenderException('Cloud export was cancelled.');
      if (status == 'completed') break;
      onProgress(CloudRenderProgress(
        stage: status,
        progress: .40 + .50 * realProgress / 100,
        message: _stageLabel(status, realProgress),
      ));
    }

    onProgress(const CloudRenderProgress(stage: 'downloading', progress: .92, message: 'Preparing secure download'));
    final signed = await _invoke({'action': 'download_url', 'jobId': jobId});
    final url = signed['signedUrl'] as String?;
    if (url == null) throw const CloudRenderException('The export completed but its download link could not be created.');
    final downloadUri = url.startsWith('http')
        ? Uri.parse(url)
        : Uri.parse('$supabaseUrl/storage/v1${url.startsWith('/') ? url : '/$url'}');
    final outputPath = '${Directory.systemTemp.path}/vyntra_cloud_${jobId}.mp4';
    final httpClient = HttpClient();
    final request = await httpClient.getUrl(downloadUri);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const CloudRenderException('The cloud export is ready, but downloading it failed. Try again from your cloud job history.');
    }
    final total = response.contentLength;
    var received = 0;
    final file = File(outputPath);
    final sink = file.openWrite();
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(CloudRenderProgress(stage: 'downloading', progress: .92 + .07 * received / total, message: 'Downloading ${(received / 1048576).toStringAsFixed(1)} MB'));
      }
      await sink.flush();
    } finally {
      await sink.close();
      httpClient.close(force: true);
    }
    if (!await file.exists() || await file.length() == 0) throw const CloudRenderException('The downloaded export is empty.');
    onProgress(const CloudRenderProgress(stage: 'completed', progress: 1, message: 'Cloud export verified and downloaded'));
    await _rememberJob({...job, 'localOutputPath': outputPath});
    return {'job': job, 'path': outputPath};
  }

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    try {
      final response = await client.functions.invoke('vyntra-render-jobs', body: body);
      if (response.status < 200 || response.status >= 300) {
        final data = response.data;
        final message = data is Map ? (data['message'] ?? data['error'])?.toString() : null;
        throw CloudRenderException(message ?? 'Cloud rendering service returned HTTP ${response.status}.');
      }
      if (response.data is! Map) throw const CloudRenderException('The cloud service returned an invalid response.');
      final data = Map<String, dynamic>.from(response.data as Map);
      if (data.containsKey('error')) throw CloudRenderException(_friendlyError(data['error'].toString()));
      return data;
    } on CloudRenderException {
      rethrow;
    } on FunctionException catch (error) {
      final details = error.details;
      if (details is Map && details['error'] != null) throw CloudRenderException(_friendlyError(details['error'].toString()));
      throw const CloudRenderException('Could not reach the cloud rendering service.');
    } catch (_) {
      throw const CloudRenderException('Could not reach the cloud rendering service. Check your connection and try again.');
    }
  }

  Future<void> _rememberJob(Map<String, dynamic> job) async {
    final prefs = preferences;
    if (prefs == null) return;
    final entries = prefs.getStringList(historyKey) ?? <String>[];
    final id = job['id']?.toString();
    if (id == null) return;
    entries.removeWhere((raw) {
      try { return jsonDecode(raw)['id'] == id; } catch (_) { return false; }
    });
    entries.insert(0, jsonEncode({...job, 'lastSeenAt': DateTime.now().toIso8601String()}));
    await prefs.setStringList(historyKey, entries.take(20).toList());
  }

  static String _mimeFor(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.mp4': return 'video/mp4';
      case '.mov': return 'video/quicktime';
      case '.mkv': return 'video/x-matroska';
      case '.mp3': return 'audio/mpeg';
      case '.m4a': case '.aac': return 'audio/mp4';
      case '.png': return 'image/png';
      case '.jpg': case '.jpeg': return 'image/jpeg';
      case '.webp': return 'image/webp';
      default: throw CloudRenderException('Unsupported media type: ${p.extension(path)}');
    }
  }

  static String _stageLabel(String status, double progress) => switch (status) {
    'processing' => 'Rendering on cloud worker · ${progress.round()}%',
    'finalizing' => 'Verifying output and uploading final video',
    'cancel_requested' => 'Stopping the cloud render',
    'uploading' => 'Uploading source media',
    _ => 'Cloud job status: $status',
  };

  static String _friendlyError(String? code) => switch (code) {
    '8k_not_enabled' || '8k_not_enabled_on_worker' => '8K export is not enabled on the deployed worker.',
    'active_job_limit' => 'You already have two active cloud exports.',
    'invalid_media_path' || 'media_not_owned' => 'A media file could not be verified for this account.',
    'worker_lost' => 'The cloud worker stopped unexpectedly. Please submit the export again.',
    'ffmpeg_failed' => 'FFmpeg could not render this project. Check the source media and edit settings.',
    _ => 'Cloud export failed (${code ?? 'unknown_error'}). Your original project has not been changed.',
  };
}
