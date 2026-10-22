import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import 'media_manager_screen.dart';
import 'models/edit_project.dart';
import 'services/ads/rewarded_ad_service.dart';
import 'services/media_processing/video_processing_service.dart';
import 'services/cloud_render_service.dart';
import 'services/supabase_config.dart';

/// Status HD is a separate, lightweight workflow. Standard sizes can render
/// locally; high-resolution output is offered only by a ready cloud worker.
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
  String _cloudResolution = '1080p';
  Set<String> _cloudResolutions = <String>{'1440p', '2160p', '2880p', '3456p', '4320p'};
  bool _useCloud = false;
  bool _processingVideo = false;
  bool _loadingCapabilities = true;
  bool _cloudAvailable = false;
  bool _removeWatermark = false;
  double _progress = 0;
  String _status = 'Choose a video to prepare for status.';
  String? _outputPath;
  int? _outputBytes;
  VideoPlayerController? _preview;
  StreamSubscription<int>? _progressSubscription;
  late final CloudRenderService? _cloud;

  bool get _cloudConfigured => vyntraSupabaseConfigured && _cloud != null;
  bool get _highResolution => _cloudResolution != '1080p';

  @override
  void initState() {
    super.initState();
    _cloud = vyntraSupabaseConfigured
        ? CloudRenderService(Supabase.instance.client, preferences: widget.preferences)
        : null;
    unawaited(_ads.preload());
    _progressSubscription = _processing.progress.listen((value) {
      if (mounted && _processingVideo) setState(() {
        _progress = value / 100;
        _status = 'On-device processing · ${value.clamp(0, 100)}%';
      });
    });
    unawaited(_loadCloudCapabilities());
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
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

  Future<void> _loadCloudCapabilities() async {
    try {
      if (!_cloudConfigured) {
        if (mounted) setState(() { _loadingCapabilities = false; _cloudAvailable = false; });
        return;
      }
      final caps = await _cloud!.capabilities();
      final resolutions = (caps['resolutions'] as List? ?? const []).map((e) => e.toString()).toSet();
      if (!mounted) return;
      setState(() {
        _cloudAvailable = caps['workerReady'] == true;
        _cloudResolutions = resolutions;
        _loadingCapabilities = false;
        if (resolutions.isNotEmpty && !resolutions.contains(_cloudResolution)) {
          _cloudResolution = resolutions.contains('2160p') ? '2160p' : resolutions.first;
        }
      });
    } catch (_) {
      if (mounted) setState(() { _loadingCapabilities = false; _cloudAvailable = false; });
    }
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

  Future<bool> _earnExportAd() async {
    setState(() => _status = 'Loading rewarded ad…');
    final earned = await _ads.showForExport();
    if (!earned && mounted) setState(() => _status = 'The rewarded ad was not completed or is unavailable. Try again later.');
    return earned;
  }

  Future<void> _export() async {
    final source = _source;
    if (source == null || _processingVideo) return;
    final cloudMode = _useCloud || _highResolution;
    setState(() {
      _processingVideo = true;
      _progress = 0;
      _status = 'Preparing export…';
      _outputPath = null;
      _outputBytes = null;
    });
    try {
      if (cloudMode) {
        if (!_cloudConfigured) throw const CloudRenderException('Cloud export needs the Supabase project configuration in this build.');
        final preflight = await _cloud!.capabilities();
        if (preflight['workerReady'] != true) {
          throw const CloudRenderException('Cloud rendering is being prepared. Please try again after the worker is ready.');
        }
        final supported = (preflight['resolutions'] as List? ?? const []).map((e) => e.toString()).toSet();
        if (!supported.contains(_cloudResolution)) {
          throw CloudRenderException('The cloud renderer does not currently support $_cloudResolution.');
        }
      }
      if (!await _earnExportAd()) return;
      if (!mounted) return;
      String outputPath;
      String outputLabel;
      if (cloudMode) {
        if (!_cloudConfigured) throw const CloudRenderException('Cloud export needs the Supabase project configuration in this build.');
        final capabilities = await _cloud!.capabilities();
        if (capabilities['workerReady'] != true) {
          throw const CloudRenderException('Cloud rendering is being prepared. Your video has not been uploaded and no export job was charged.');
        }
        final supported = (capabilities['resolutions'] as List? ?? const []).map((e) => e.toString()).toSet();
        if (!supported.contains(_cloudResolution)) {
          throw CloudRenderException('The cloud renderer is not yet advertising ${_cloudResolution} output. Choose a supported resolution or try again later.');
        }
        if (!mounted) return;
        final metadata = await _processing.inspect(source.path);
        final now = DateTime.now();
        final id = 'status_${now.microsecondsSinceEpoch}';
        final project = EditProject(
          id: id,
          name: 'Status HD export',
          createdAt: now,
          updatedAt: now,
          aspectRatio: '9:16',
          overlays: _removeWatermark ? const [] : [EditTextOverlay(
            id: '${id}_watermark',
            text: 'Vyntra',
            startMs: 0,
            endMs: metadata.duration.inMilliseconds,
            color: 0xBFFFFFFF,
            fontSize: 22,
            x: .82,
            y: .84,
          )],
          clips: [EditClip(
            id: '${id}_clip',
            path: source.path,
            name: source.name,
            durationMs: metadata.duration.inMilliseconds,
          )],
        );
        final resolution = _cloudResolution;
        final result = await _cloud!.renderProject(
          project: project,
          resolution: resolution,
          onProgress: (p) {
            if (mounted) setState(() {
              _progress = p.progress.clamp(0, 1);
              _status = '${p.message ?? p.stage} · ${(_progress * 100).round()}%';
            });
          },
        );
        outputPath = result['path'] as String;
        outputLabel = switch (resolution) {
          '4320p' => '8K (cloud)',
          '2160p' => '4K (cloud)',
          '1440p' => '2K / QHD (cloud)',
          '2160p' => '4K (cloud)',
          '2880p' => '5K (cloud)',
          '3456p' => '6K (cloud)',
          '4320p' => '8K (cloud)',
          _ => '${resolution} (cloud)',
        };
      } else {
        setState(() => _status = 'Inspecting source video…');
        final metadata = await _processing.inspect(source.path);
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final path = '${Directory.systemTemp.path}/vyntra_status_$stamp.mp4';
        final result = await _processing.process(ProcessingRequest.enhance(
          inputPath: source.path,
          outputPath: path,
          metadata: metadata,
          enhancement: EnhancementConfiguration(
            resolution: _resolution,
            strength: EnhancementStrength.gentle,
            brightness: 0.02,
            contrast: 0.05,
            saturation: 4,
            sharpness: 0.12,
            noiseReduction: 0,
            watermark: !_removeWatermark,
          ),
        ));
        outputPath = result.path;
        outputLabel = _resolutionLabel;
      }
      final outputFile = File(outputPath);
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
        _outputPath = outputPath;
        _outputBytes = size;
        _progress = 1;
        _status = 'Export complete · 100%. Review the actual output before saving or sharing.';
        _lastOutputLabel = outputLabel;
      });
    } catch (error) {
      if (mounted) setState(() => _status = error.toString().replaceFirst('ProcessingValidationException: ', ''));
    } finally {
      if (mounted) setState(() => _processingVideo = false);
    }
  }

  String _lastOutputLabel = '1080p';

  Future<void> _toggleWatermarkRemoval(bool value) async {
    if (_processingVideo || value == _removeWatermark) return;
    if (value) {
      final earned = await _ads.showForExport();
      if (!mounted) return;
      if (!earned) {
        setState(() => _status = 'Complete the rewarded ad to unlock watermark-free on-device export.');
        return;
      }
    }
    setState(() {
      _removeWatermark = value;
      _status = value ? 'Watermark-free on-device export unlocked for this session.' : 'Vyntra watermark will be included on on-device exports.';
    });
  }

  Future<void> _shareOutput() async {
    final path = _outputPath;
    if (path == null || !await File(path).exists()) {
      if (mounted) setState(() => _status = 'The processed file is no longer available. Export it again.');
      return;
    }
    await Share.shareXFiles(
      [XFile(path, mimeType: 'video/mp4', name: 'vyntra_status_${_lastOutputLabel.toLowerCase().replaceAll(' ', '_')}.mp4')],
      text: 'Status video prepared with Vyntra',
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final preview = _preview;
    final cloudOptions = <(String, String)>[
      ('1440p', '2K / QHD · Cloud'),
      ('2160p', '4K · Cloud'),
      ('2880p', '5K · Cloud'),
      ('3456p', '6K · Cloud'),
      ('4320p', '8K · Cloud'),
    ];
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
                Text('Quick on-device exports for standard sizes, plus cloud rendering for higher resolutions when the worker is available. Cloud exports upload your selected video for processing.'),
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
              Text('Source duration: ${(_source!.duration / 1000).toStringAsFixed(1)} s', style: const TextStyle(color: Colors.white60, fontSize: 12)),
            ],
            const SizedBox(height: 20),
            Text('On-device resolution', style: Theme.of(context).textTheme.titleMedium),
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
                  onSelected: _processingVideo ? null : (_) => setState(() { _resolution = option.$1; _useCloud = false; }),
                ),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: Text('Cloud rendering', style: Theme.of(context).textTheme.titleMedium)),
              if (_loadingCapabilities) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              if (!_loadingCapabilities) Text(_cloudAvailable ? 'Ready' : 'Cloud setup pending', style: TextStyle(color: _cloudAvailable ? Colors.greenAccent : Colors.orangeAccent, fontSize: 12)),
            ]),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _useCloud,
              onChanged: _processingVideo ? null : (value) => setState(() => _useCloud = value),
              title: const Text('Render in cloud'),
              subtitle: const Text('Guest access — no sign-in. Cloud exports upload your selected video for processing.'),
            ),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final option in cloudOptions)
                ChoiceChip(
                  label: Text(option.$2),
                  selected: _cloudResolution == option.$1 && _useCloud,
                  onSelected: _processingVideo ? null : (_) => setState(() { _cloudResolution = option.$1; _useCloud = true; }),
                ),
            ]),
            const SizedBox(height: 6),
            Text(
              _cloudAvailable
                  ? 'Cloud renderer is responding. Cloud exports require a completed rewarded ad.'
                  : 'Guest cloud export needs no sign-in screen. High-resolution options are available; cloud processing activates when the FFmpeg worker is deployed and verified. On-device export still works now.',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _removeWatermark,
              onChanged: _processingVideo ? null : _toggleWatermarkRemoval,
              title: const Text('Remove Vyntra watermark'),
              subtitle: const Text('Watch a rewarded ad to unlock watermark-free on-device export for this session.'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _processingVideo || _source == null ? null : _export,
              icon: _processingVideo ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome_rounded),
              label: Text(_processingVideo ? 'Rendering… ${(_progress * 100).round()}%' : 'Watch ad & export'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            ),
            if (_processingVideo) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _progress.clamp(0, 1)),
              const SizedBox(height: 4),
              Text('${(_progress * 100).round()}% complete', textAlign: TextAlign.end, style: const TextStyle(color: Colors.white70, fontSize: 12)),
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
                      onPressed: () {
                        if (preview.value.isPlaying) { unawaited(preview.pause()); } else { unawaited(preview.play()); }
                        setState(() {});
                      },
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
                decoration: BoxDecoration(color: const Color(0xFF151A20), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white12)),
                child: Row(children: [
                  const Icon(Icons.check_circle_outline_rounded, color: Colors.greenAccent),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Processed MP4', style: TextStyle(fontWeight: FontWeight.w800)),
                    Text('$_lastOutputLabel · ${_formatBytes(_outputBytes!)}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  ])),
                ]),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(onPressed: _shareOutput, icon: const Icon(Icons.save_alt_rounded), label: const Text('Save or share video')),
            ],
            const SizedBox(height: 16),
            const Text('Rewarded ads gate exports and the watermark-removal unlock. Actual output size is measured after rendering.', style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
