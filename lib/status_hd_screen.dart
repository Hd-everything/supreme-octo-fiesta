import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'media_manager_screen.dart';
import 'models/edit_project.dart';
import 'services/ads/rewarded_ad_service.dart';
import 'services/media_processing/video_processing_service.dart';

/// Lightweight, on-device status-video preparation kept separate from the editor.
class StatusHdScreen extends StatefulWidget {
  const StatusHdScreen({super.key, required this.preferences});
  final SharedPreferences preferences;

  @override
  State<StatusHdScreen> createState() => _StatusHdScreenState();
}

class _StatusHdScreenState extends State<StatusHdScreen> {
  final _ads = RewardedAdService();
  final _processing = VideoProcessingService();
  DeviceMedia? _source;
  OutputResolution _resolution = OutputResolution.p1080;
  bool _processingVideo = false;
  double _progress = 0;
  String _status = 'Choose a video to prepare for status.';
  String? _outputPath;
  int? _outputBytes;
  VideoPlayerController? _preview;

  @override
  void initState() {
    super.initState();
    unawaited(_ads.preload());
  }

  @override
  void dispose() {
    _preview?.dispose();
    unawaited(_processing.closeNeuralRuntime());
    super.dispose();
  }

  String get _resolutionLabel => switch (_resolution) {
    OutputResolution.p720 => '720p',
    OutputResolution.p1080 => '1080p',
    OutputResolution.p1440 => '1440p',
    OutputResolution.original => 'Original',
  };

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _pick() async {
    final picked = await Navigator.of(context).push<List<DeviceMedia>>(
      MaterialPageRoute(builder: (_) => const MediaManagerScreen(videosOnly: true, multiSelect: false)),
    );
    if (!mounted || picked == null || picked.isEmpty) return;
    final item = picked.first;
    if (!File(item.path).existsSync() || item.duration <= 0) {
      setState(() => _status = 'That video is unavailable. Choose another file.');
      return;
    }
    await _preview?.dispose();
    if (!mounted) return;
    setState(() {
      _preview = null;
      _source = item;
      _outputPath = null;
      _outputBytes = null;
      _status = 'Ready to process ${item.name}. Your original will remain unchanged.';
    });
  }

  Future<void> _export() async {
    final source = _source;
    if (source == null || _processingVideo) return;
    setState(() {
      _processingVideo = true;
      _progress = 0;
      _status = 'Preparing rewarded ad…';
      _outputPath = null;
      _outputBytes = null;
    });
    try {
      final earned = await _ads.showFor1080p();
      if (!earned) {
        if (mounted) setState(() => _status = 'The rewarded ad was not completed or is unavailable. Try again later.');
        return;
      }
      if (!mounted) return;
      setState(() => _status = 'Inspecting source video…');
      final metadata = await _processing.inspect(source.path);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final outputPath = '${Directory.systemTemp.path}/vyntra_status_$stamp.mp4';
      final result = await _processing.process(ProcessingRequest.enhance(
        inputPath: source.path,
        outputPath: outputPath,
        metadata: metadata,
        enhancement: EnhancementConfiguration(
          resolution: _resolution,
          strength: EnhancementStrength.gentle,
          brightness: 0.02,
          contrast: 0.05,
          saturation: 4,
          sharpness: 0.12,
          noiseReduction: 0,
          watermark: false,
        ),
      ));
      final outputFile = File(result.path);
      final size = await outputFile.length();
      final controller = VideoPlayerController.file(outputFile);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await _preview?.dispose();
      setState(() {
        _preview = controller;
        _outputPath = result.path;
        _outputBytes = size;
        _progress = 1;
        _status = 'Processing complete. Review the real output before saving or sharing.';
      });
    } catch (error) {
      if (mounted) setState(() => _status = error.toString().replaceFirst('ProcessingValidationException: ', ''));
    } finally {
      if (mounted) setState(() => _processingVideo = false);
    }
  }

  Future<void> _shareOutput() async {
    final path = _outputPath;
    if (path == null || !await File(path).exists()) {
      if (mounted) setState(() => _status = 'The processed file is no longer available. Export it again.');
      return;
    }
    await Share.shareXFiles(
      [XFile(path, mimeType: 'video/mp4', name: 'vyntra_status_${_resolutionLabel.toLowerCase()}.mp4')],
      text: 'Status video prepared with Vyntra',
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Status HD')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [accent.withValues(alpha: .18), const Color(0xFF171D25)]),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: accent.withValues(alpha: .24)),
              ),
              child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.movie_filter_rounded, size: 32),
                SizedBox(height: 12),
                Text('Ready for your status', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900)),
                SizedBox(height: 8),
                Text('Prepare one video at a time. Processing runs on this device, avoids cloud uploads, and keeps your original file untouched.'),
              ]),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _processingVideo ? null : _pick,
              icon: const Icon(Icons.video_library_outlined),
              label: Text(_source?.name ?? 'Choose a video'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), alignment: Alignment.centerLeft),
            ),
            if (_source != null) ...[
              const SizedBox(height: 8),
              Text('Source duration: ${(_source!.duration / 1000).toStringAsFixed(1)} s',
                style: const TextStyle(color: Colors.white60, fontSize: 12)),
            ],
            const SizedBox(height: 20),
            Text('Output resolution', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final option in <(OutputResolution, String)>[
                (OutputResolution.p720, '720p'),
                (OutputResolution.p1080, '1080p'),
                (OutputResolution.p1440, '1440p'),
                (OutputResolution.original, 'Original'),
              ])
                ChoiceChip(
                  label: Text(option.$2),
                  selected: _resolution == option.$1,
                  onSelected: _processingVideo ? null : (_) => setState(() => _resolution = option.$1),
                ),
            ]),
            const SizedBox(height: 8),
            const Text('Status HD focuses on practical social-video sizes. 4K/8K cloud rendering is not part of this workflow.',
              style: TextStyle(color: Colors.white60, fontSize: 12)),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _processingVideo || _source == null ? null : _export,
              icon: _processingVideo
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome_rounded),
              label: Text(_processingVideo ? 'Processing…' : 'Watch ad & prepare video'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            ),
            if (_processingVideo) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            ],
            const SizedBox(height: 14),
            Text(_status, style: const TextStyle(color: Colors.white70)),
            if (preview != null && preview.value.isInitialized) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: preview.value.aspectRatio,
                  child: Stack(alignment: Alignment.center, children: [
                    VideoPlayer(preview),
                    IconButton.filledTonal(
                      tooltip: preview.value.isPlaying ? 'Pause preview' : 'Play preview',
                      onPressed: () {\n                        if (preview.value.isPlaying) {\n                          unawaited(preview.pause());\n                        } else {\n                          unawaited(preview.play());\n                        }\n                        setState(() {});\n                      },
                      icon: Icon(preview.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                    ),
                  ]),
                ),
              ),
            ],
            if (_outputPath != null && _outputBytes != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF151A20),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(children: [
                  const Icon(Icons.check_circle_outline_rounded, color: Colors.greenAccent),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Processed MP4', style: TextStyle(fontWeight: FontWeight.w800)),
                    Text('$_resolutionLabel · ${_formatBytes(_outputBytes!)}',
                      style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  ])),
                ]),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(onPressed: _shareOutput, icon: const Icon(Icons.save_alt_rounded), label: const Text('Save or share video')),
            ],
            const SizedBox(height: 16),
            const Text('A rewarded ad is required before processing. Output size depends on the source, duration and selected resolution; the app reports the actual file size after encoding.',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
