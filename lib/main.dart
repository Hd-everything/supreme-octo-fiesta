import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'media_manager_screen.dart';
import 'movie_player_screen.dart';
import 'services/media_processing/video_processing_service.dart';
import 'services/media_processing/processing_job_queue.dart';
import 'services/media_processing/photo_processing_service.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const _mediaChannel = MethodChannel('com.ptip.statushd/media');

const _accentChoices = <Color>[
  Color(0xFF42C7C7),
  Color(0xFF72A7FF),
  Color(0xFFB79CFF),
  Color(0xFFFFA36C),
  Color(0xFFFF7FA8),
  Color(0xFFF4D35E),
];

const _recentExportsKey = 'recent_status_exports_v1';

enum StudioProcessingMode { conventional, neural }

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(StatusHdStartup(preferences: _loadStartupPreferences()));
}

Future<SharedPreferences> _loadStartupPreferences() async {
  try {
    return await SharedPreferences.getInstance();
  } catch (error, stackTrace) {
    debugPrint('Status HD could not load saved settings; using temporary settings: $error');
    debugPrintStack(stackTrace: stackTrace);
    // A preferences plugin failure should not prevent the media tools from
    // opening. The in-memory store keeps this session usable until restart.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    return SharedPreferences.getInstance();
  }
}

class StatusHdStartup extends StatefulWidget {
  const StatusHdStartup({super.key, required this.preferences});

  final Future<SharedPreferences> preferences;

  @override
  State<StatusHdStartup> createState() => _StatusHdStartupState();
}

class _StatusHdStartupState extends State<StatusHdStartup> {
  late Future<SharedPreferences> _preferences = widget.preferences;

  void _retry() => setState(() => _preferences = SharedPreferences.getInstance());

  @override
  Widget build(BuildContext context) => FutureBuilder<SharedPreferences>(
        future: _preferences,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            return StatusHdApp(preferences: snapshot.data!);
          }
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              backgroundColor: const Color(0xFF090B10),
              body: Center(
                child: snapshot.hasError
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Status HD could not load app settings.'),
                          const SizedBox(height: 12),
                          FilledButton(onPressed: _retry, child: const Text('Try again')),
                        ],
                      )
                    : const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Starting Status HD…'),
                        ],
                      ),
              ),
            ),
          );
        },
      );
}

class StatusHdApp extends StatefulWidget {
  const StatusHdApp({super.key, required this.preferences});

  final SharedPreferences preferences;

  @override
  State<StatusHdApp> createState() => _StatusHdAppState();
}

class _StatusHdAppState extends State<StatusHdApp> {
  late int _accentIndex = widget.preferences.getInt('accentIndex') ?? 0;
  late bool _amoled = widget.preferences.getBool('amoled') ?? true;
  late bool _compact = widget.preferences.getBool('compact') ?? false;
  late bool _rounded = widget.preferences.getBool('rounded') ?? true;
  late bool _gradients = widget.preferences.getBool('gradients') ?? true;
  late int _customAccent = widget.preferences.getInt('customAccent') ?? 0xFF55E6A5;
  late List<String> _savedThemes = widget.preferences.getStringList('savedThemes') ?? <String>[];

  Color get accent => _accentIndex == _accentChoices.length ? Color(_customAccent) : _accentChoices[_accentIndex];

  Future<void> _save(String key, Object value) async {
    if (value is bool) await widget.preferences.setBool(key, value);
    if (value is int) await widget.preferences.setInt(key, value);
  }

  void _setAccent(int index) {
    setState(() => _accentIndex = index);
    unawaited(_save('accentIndex', index));
  }

  void _setCustomAccent(Color color) {
    setState(() { _customAccent = color.toARGB32(); _accentIndex = _accentChoices.length; });
    unawaited(_save('customAccent', _customAccent));
    unawaited(_save('accentIndex', _accentIndex));
  }

  Future<void> _saveTheme() async {
    final controller = TextEditingController(text: 'My theme ${_savedThemes.length + 1}');
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Save theme'),
      content: TextField(controller: controller, autofocus: true, maxLength: 32, decoration: const InputDecoration(labelText: 'Theme name')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
      ],
    ));
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    final entry = jsonEncode({'name': name, 'accentIndex': _accentIndex, 'customAccent': _customAccent, 'amoled': _amoled, 'compact': _compact, 'rounded': _rounded, 'gradients': _gradients});
    final next = [..._savedThemes, entry];
    setState(() => _savedThemes = next);
    await widget.preferences.setStringList('savedThemes', next);
  }

  Future<void> _applyTheme(String raw) async {
    try {
      final t = jsonDecode(raw) as Map<String, dynamic>;
      setState(() {
        _accentIndex = ((t['accentIndex'] as num?)?.toInt() ?? 0).clamp(0, _accentChoices.length);
        _customAccent = (t['customAccent'] as num?)?.toInt() ?? _customAccent;
        _amoled = t['amoled'] as bool? ?? true;
        _compact = t['compact'] as bool? ?? false;
        _rounded = t['rounded'] as bool? ?? true;
        _gradients = t['gradients'] as bool? ?? true;
      });
      for (final e in <String, Object>{'accentIndex': _accentIndex, 'customAccent': _customAccent, 'amoled': _amoled, 'compact': _compact, 'rounded': _rounded, 'gradients': _gradients}.entries) { await _save(e.key, e.value); }
    } catch (_) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not load this saved theme.'))); }
  }

  Future<void> _deleteTheme(int index) async {
    final next = [..._savedThemes]..removeAt(index);
    setState(() => _savedThemes = next);
    await widget.preferences.setStringList('savedThemes', next);
  }

  void _setAmoled(bool value) {
    setState(() => _amoled = value);
    unawaited(_save('amoled', value));
  }

  void _setCompact(bool value) {
    setState(() => _compact = value);
    unawaited(_save('compact', value));
  }

  void _setRounded(bool value) {
    setState(() => _rounded = value);
    unawaited(_save('rounded', value));
  }

  void _setGradients(bool value) {
    setState(() => _gradients = value);
    unawaited(_save('gradients', value));
  }

  @override
  Widget build(BuildContext context) {
    // The app stays dark; AMOLED toggles only the dark surface palette.
    const brightness = Brightness.dark;
    final background = _amoled ? const Color(0xFF090B10) : const Color(0xFF101319);
    final surface = _amoled ? const Color(0xFF15191F) : const Color(0xFF1B2028);
    const foreground = Color(0xFFF4F1EA);
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      surface: surface,
    ).copyWith(
      primary: accent,
      onPrimary: const Color(0xFF062015),
      surface: surface,
      onSurface: foreground,
    );

    return MaterialApp(
      title: 'Status HD',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: brightness,
        colorScheme: scheme,
        scaffoldBackgroundColor: background,
        splashFactory: InkSparkle.splashFactory,
        textTheme: ThemeData(brightness: brightness).textTheme.apply(bodyColor: foreground, displayColor: foreground),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_rounded ? 24 : 12),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.055)),
          ),
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: accent,
          thumbColor: accent,
          overlayColor: accent.withValues(alpha: .12),
        ),
      ),
      home: HomeScreen(
        preferences: widget.preferences,
        accent: accent,
        accentIndex: _accentIndex,
        customAccent: _customAccent,
        savedThemes: _savedThemes,
        onCustomAccentChanged: _setCustomAccent,
        onSaveTheme: _saveTheme,
        onApplyTheme: _applyTheme,
        onDeleteTheme: _deleteTheme,
        amoled: _amoled,
        compact: _compact,
        rounded: _rounded,
        gradients: _gradients,
        onGradientsChanged: _setGradients,
        onAccentChanged: _setAccent,
        onAmoledChanged: _setAmoled,
        onCompactChanged: _setCompact,
        onRoundedChanged: _setRounded,
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.preferences,
    required this.accent,
    required this.accentIndex,
    required this.customAccent,
    required this.savedThemes,
    required this.onCustomAccentChanged,
    required this.onSaveTheme,
    required this.onApplyTheme,
    required this.onDeleteTheme,
    required this.amoled,
    required this.compact,
    required this.rounded,
    required this.gradients,
    required this.onGradientsChanged,
    required this.onAccentChanged,
    required this.onAmoledChanged,
    required this.onCompactChanged,
    required this.onRoundedChanged,
  });

  final SharedPreferences preferences;
  final Color accent;
  final int accentIndex;
  final int customAccent;
  final List<String> savedThemes;
  final ValueChanged<Color> onCustomAccentChanged;
  final VoidCallback onSaveTheme;
  final ValueChanged<String> onApplyTheme;
  final ValueChanged<int> onDeleteTheme;
  final bool amoled;
  final bool compact;
  final bool rounded;
  final bool gradients;
  final ValueChanged<bool> onGradientsChanged;
  final ValueChanged<int> onAccentChanged;
  final ValueChanged<bool> onAmoledChanged;
  final ValueChanged<bool> onCompactChanged;
  final ValueChanged<bool> onRoundedChanged;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProcessingJobQueue _jobs = ProcessingJobQueue();
  late final VideoProcessingService _processing = VideoProcessingService(jobs: _jobs);
  final PhotoProcessingService _photos = PhotoProcessingService();
  XFile? _selected;
  bool _busy = false;
  String? _message;
  int _tab = 0;
  VideoPlayerController? _videoController;
  VideoPlayerController? _enhancedPreviewController;
  double _trimStart = 0;
  double? _trimEnd;
  String _cropRatio = '9:16';
  bool _exporting = false;
  List<XFile> _segments = [];
  String? _sourceResolution;
  String? _qualityRecommendation;
  int _targetLongEdge = -1;
  String? _exportEstimateMessage;
  bool _cancelExportRequested = false;
  bool _showOriginalComparison = false;
  bool _addWatermark = false;
  StudioProcessingMode _processingMode = StudioProcessingMode.conventional;
  bool _neuralReady = false;
  String _neuralStatus = 'Checking neural runtime…';
  double _enhanceProgress = 0;
  double _brightnessBoost = 0.09;
  double _contrastBoost = 0.20;
  double _saturationBoost = 14;
  double _sharpnessBoost = 0.26;
  XFile? _enhancedVideo;
  List<Map<String, String>> _recentExports = <Map<String, String>>[];

  bool get _isVideo {
    final name = _selected?.name.toLowerCase() ?? '';
    return name.endsWith('.mp4') || name.endsWith('.mov') ||
        name.endsWith('.m4v') || name.endsWith('.webm') ||
        name.endsWith('.3gp') || name.endsWith('.mkv');
  }

  bool get _canApplyPictureAdjustments =>
      !_isVideo || _processingMode == StudioProcessingMode.conventional;

  ({double clarity, double sharpness}) _qualityForOutputSize(int longEdge) =>
      switch (longEdge) {
        640 => (clarity: 0.10, sharpness: 0.14),
        854 => (clarity: 0.13, sharpness: 0.17),
        1280 => (clarity: 0.16, sharpness: 0.21),
        1920 || -1 => (clarity: 0.20, sharpness: 0.26),
        2560 => (clarity: 0.24, sharpness: 0.32),
        _ => (clarity: 0.20, sharpness: 0.26),
      };

  void _selectOutputSize(int longEdge) {
    final quality = _qualityForOutputSize(longEdge);
    setState(() {
      _targetLongEdge = longEdge;
      _contrastBoost = quality.clarity;
      _sharpnessBoost = quality.sharpness;
      _enhancedVideo = null;
      _exportEstimateMessage = _estimateExportSize();
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(_jobs.load());
    unawaited(_loadNeuralCapability());
    _loadRecentExports();
  }

  Future<void> _loadNeuralCapability() async {
    try {
      final result = await _processing.nativeNeuralCapability();
      if (!mounted) return;
      setState(() {
        _neuralReady = result['ready'] == true && result['videoPipeline'] == true;
        _neuralStatus = _neuralReady
            ? 'Neural video processing is ready.'
            : 'Neural video export unavailable on this runtime';
      });
    } catch (_) {
      if (mounted) setState(() => _neuralStatus = 'Neural video export unavailable on this runtime');
    }
  }

  Future<void> _loadRecentExports() async {
    final entries = <Map<String, String>>[];
    for (final raw in widget.preferences.getStringList(_recentExportsKey) ?? const <String>[]) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final path = decoded['path']?.toString() ?? '';
        if (path.isNotEmpty) {
          entries.add({
            'path': path,
            'name': decoded['name']?.toString() ?? 'Status HD export',
            'kind': decoded['kind']?.toString() ?? 'Export',
            'createdAt': decoded['createdAt']?.toString() ?? '',
          });
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _recentExports = entries);
  }

  @override
  void dispose() {
    _jobs.dispose();
    _videoController?.dispose();
    _enhancedPreviewController?.dispose();
    super.dispose();
  }

  Future<void> _recordExports(List<XFile> files, String kind) async {
    final now = DateTime.now().toIso8601String();
    final next = <Map<String, String>>[
      for (final file in files) {
        'path': file.path,
        'name': file.name,
        'kind': kind,
        'createdAt': now,
      },
      ..._recentExports.where((entry) => !files.any((file) => file.path == entry['path'])),
    ].take(12).toList();
    if (mounted) setState(() => _recentExports = next);
    await widget.preferences.setStringList(
      _recentExportsKey,
      next.map(jsonEncode).toList(),
    );
  }

  Future<void> _shareRecentExport(Map<String, String> entry) async {
    final path = entry['path']!;
    if (!await File(path).exists()) {
      if (mounted) setState(() => _message = 'This temporary export is no longer available. Saved copies remain in your gallery.');
      return;
    }
    await Share.shareXFiles([XFile(path, mimeType: 'video/mp4')], subject: entry['name']);
  }

  Future<void> _removeRecentExport(Map<String, String> entry) async {
    final next = [..._recentExports]..remove(entry);
    setState(() => _recentExports = next);
    await widget.preferences.setStringList(_recentExportsKey, next.map(jsonEncode).toList());
  }

  void _applyWhatsAppStatusPreset() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    final total = controller.value.duration.inMilliseconds / 1000.0;
    final quality = _qualityForOutputSize(1920);
    setState(() {
      _cropRatio = '9:16';
      _targetLongEdge = 1920;
      _contrastBoost = quality.clarity;
      _sharpnessBoost = quality.sharpness;
      _trimStart = 0;
      _trimEnd = total > 30 ? 30 : total;
      _enhancedVideo = null;
      _segments = [];
      _exportEstimateMessage = _estimateExportSize();
      _message = total > 30
          ? 'WhatsApp Status preset applied: 9:16 frame, 1080p output and the first 30 seconds selected. Use Auto-cut for every clip.'
          : 'WhatsApp Status preset applied: 9:16 frame, 1080p output and a status-length clip.';
    });
  }

  Future<void> _pickMedia() async {
    try {
      final picked = await Navigator.of(context).push<DeviceMedia>(
        MaterialPageRoute(builder: (_) => const MediaManagerScreen()),
      );
      if (picked == null || !mounted) return;
      final file = XFile(picked.path, name: picked.name);
      final autoQuality = _qualityForOutputSize(-1);
      await _videoController?.dispose();
      await _enhancedPreviewController?.dispose();
      _videoController = null;
      _enhancedPreviewController = null;
      setState(() {
        _selected = file;
        _message = null;
        _trimStart = 0;
        _trimEnd = null;
        _segments = [];
        _sourceResolution = null;
        _qualityRecommendation = null;
        _targetLongEdge = -1;
        _contrastBoost = autoQuality.clarity;
        _sharpnessBoost = autoQuality.sharpness;
        _enhancedVideo = null;
        _enhanceProgress = 0;
        _exportEstimateMessage = null;
      });
      final name = file.name.toLowerCase();
      final video = name.endsWith('.mp4') || name.endsWith('.mov') ||
          name.endsWith('.m4v') || name.endsWith('.webm') ||
          name.endsWith('.3gp') || name.endsWith('.mkv');
      if (video) {
        final controller = VideoPlayerController.file(File(file.path));
        await controller.initialize();
        if (!mounted) {
          await controller.dispose();
          return;
        }
        setState(() {
          _videoController = controller;
          _trimEnd = controller.value.duration.inMilliseconds / 1000.0;
          final width = controller.value.size.width.round();
          final height = controller.value.size.height.round();
          _sourceResolution = '$width×$height';
          final shortEdge = width < height ? width : height;
          _qualityRecommendation = shortEdge < 720
              ? 'Low-resolution video detected. Status HD can apply conventional enhancement and upscale it, but larger dimensions do not recreate missing detail.'
              : 'Choose an output size for conventional enhancement. The new copy adjusts picture tone and sharpness while leaving your original untouched.';
          // Auto selects at least 1080p; output size can be changed below the preview.
          _targetLongEdge = -1;
          _exportEstimateMessage = _estimateExportSize();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not open this media. Please try another file.');
    }
  }

  String? _estimateExportSize() {
    final duration = _videoController?.value.duration;
    if (duration == null || duration.inSeconds <= 0 || _targetLongEdge == 0) return null;
    final videoBitrate = _targetLongEdge == 640
        ? 1200000
        : _targetLongEdge == 854
            ? 2000000
            : _targetLongEdge == 1280
                ? 4500000
                : _targetLongEdge == 2560
                    ? 14000000
                    : 8000000;
    final audioBitrate = _targetLongEdge <= 854 ? 128000 : 160000;
    final estimatedBytes = ((videoBitrate + audioBitrate) * duration.inSeconds / 8).round();
    return 'Estimated size: about ${_formatBytes(estimatedBytes)} · actual size varies by video content';
  }

  Future<void> _enhanceVideo() async {
    final file = _selected;
    if (file != null && !_isVideo) {
      await _enhancePhoto(file);
      return;
    }
    final controller = _videoController;
    if (file == null || controller == null || !controller.value.isInitialized || _exporting || _busy) return;
    final sourceWidth = controller.value.size.width.round();
    final sourceHeight = controller.value.size.height.round();
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      setState(() => _message = 'Could not detect the video dimensions.');
      return;
    }
    final sourceLongEdge = sourceWidth > sourceHeight ? sourceWidth : sourceHeight;
    final sourceShortEdge = sourceWidth < sourceHeight ? sourceWidth : sourceHeight;
    final requestedLongEdge = _targetLongEdge == 0
        ? sourceLongEdge
        : _targetLongEdge == -1
            ? (sourceLongEdge < 1920 ? 1920 : sourceLongEdge)
            : _targetLongEdge;
    final boundedLongEdge = requestedLongEdge.clamp(2, 4096).toInt();
    final targetLongEdge = boundedLongEdge.isEven ? boundedLongEdge : boundedLongEdge - 1;
    final requestedShortEdge = (sourceShortEdge * targetLongEdge / sourceLongEdge).round();
    final boundedShortEdge = requestedShortEdge.clamp(2, 4096).toInt();
    final targetShortEdge = boundedShortEdge.isEven ? boundedShortEdge : boundedShortEdge + 1;
    final outputWidth = sourceWidth >= sourceHeight ? targetLongEdge : targetShortEdge;
    final outputHeight = sourceWidth >= sourceHeight ? targetShortEdge : targetLongEdge;
    if (_targetLongEdge == 0) {
      setState(() => _message = 'Original selected. The source file remains unchanged; no re-encode is needed.');
      return;
    }
    final presetLabel = _targetLongEdge == -1 ? 'Auto' : _targetLongEdge == 640 ? '360p' : _targetLongEdge == 854 ? '480p' : _targetLongEdge == 1280 ? '720p' : _targetLongEdge == 2560 ? '1440p' : '1080p';
    setState(() {
      _exporting = true;
      _cancelExportRequested = false;
      _enhanceProgress = 0;
      _message = 'Preparing $presetLabel status export…';
      _enhancedVideo = null;
      _exportEstimateMessage = _estimateExportSize();
    });
    try {
      final output = '${Directory.systemTemp.path}/statushd_enhanced_${DateTime.now().microsecondsSinceEpoch}.mp4';
      final metadata = await _processing.inspect(file.path);
      final resolution = _targetLongEdge == 2560
          ? OutputResolution.p1440
          : _targetLongEdge == 1280
              ? OutputResolution.p720
              : OutputResolution.p1080;
      final processed = _processingMode == StudioProcessingMode.neural
          ? await _processing.processNeural(inputPath: file.path, outputPath: output, metadata: metadata, outputWidth: outputWidth, outputHeight: outputHeight)
          : await _processing.process(ProcessingRequest.enhance(inputPath: file.path, outputPath: output, metadata: metadata, enhancement: EnhancementConfiguration(resolution: resolution, brightness: _brightnessBoost, contrast: _contrastBoost, saturation: _saturationBoost, sharpness: _sharpnessBoost, outputWidth: outputWidth, outputHeight: outputHeight, watermark: _addWatermark)));
      final processedPath = processed.path;
      if (_cancelExportRequested) {
        try { await File(processedPath).delete(); } catch (_) {}
        throw StateError('Processing cancelled.');
      }
      final actualLength = await File(processedPath).length();
      if (actualLength == 0) throw StateError('The processed video is empty.');
      await _enhancedPreviewController?.dispose();
      final previewController = VideoPlayerController.file(File(processedPath));
      await previewController.initialize();
      await previewController.setLooping(true);
      await previewController.play();
      if (!mounted) {
        await previewController.dispose();
        return;
      }
      setState(() {
        _enhancedVideo = XFile(processedPath, mimeType: 'video/mp4');
        _enhancedPreviewController = previewController;
        _message = 'Processed output ready: ${outputWidth}×${outputHeight} · ${_formatBytes(actualLength)}. Review it below.';
        _exportEstimateMessage = 'Encoded output: ${outputWidth}×${outputHeight} · ${_formatBytes(actualLength)}';
        _enhanceProgress = 1;
      });
      unawaited(_recordExports([XFile(processedPath, mimeType: 'video/mp4')], 'Enhanced video'));
    } catch (error) {
      if (mounted) setState(() => _message = _cancelExportRequested
          ? 'Export cancelled. The original video is unchanged.'
          : 'Video export failed on this device. Try a smaller output size or a shorter clip. Details: ${error.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _exporting = false);
      _cancelExportRequested = false;
    }
  }

  Future<void> _previewEnhancedVideo() async {
    final controller = _enhancedPreviewController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  Widget _processedOutputPreview(Color accent) {
    final file = _enhancedVideo;
    final controller = _enhancedPreviewController;
    if (file != null && file.path.toLowerCase().endsWith('.jpg')) {
      return Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.verified_rounded, color: accent), const SizedBox(width: 8), const Expanded(child: Text('ENHANCED PHOTO', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4))), const Text('JPEG', style: TextStyle(color: Colors.white54, fontSize: 11))]),
        const SizedBox(height: 12),
        ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.file(File(file.path), height: 240, width: double.infinity, fit: BoxFit.contain)),
        const SizedBox(height: 10),
        Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : _saveEnhancedVideo, icon: const Icon(Icons.save_alt_rounded), label: const Text('Save copy'))), const SizedBox(width: 8), Expanded(child: FilledButton.icon(onPressed: _busy ? null : _shareEnhancedVideo, icon: const Icon(Icons.ios_share_rounded), label: const Text('Share')))]),
      ])));
    }
    if (file == null || controller == null || !controller.value.isInitialized) return const SizedBox.shrink();
    final width = controller.value.size.width.round();
    final height = controller.value.size.height.round();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.verified_rounded, color: accent),
            const SizedBox(width: 8),
            const Expanded(child: Text('PROCESSED OUTPUT', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.4))),
            Text('$width×$height', style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio > 0 ? controller.value.aspectRatio : 16 / 9,
              child: Stack(alignment: Alignment.center, children: [
                VideoPlayer(_showOriginalComparison && _videoController?.value.isInitialized == true ? _videoController! : controller),
                IconButton.filled(
                  onPressed: _previewEnhancedVideo,
                  iconSize: 32,
                  icon: Icon(controller.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
                Positioned(left: 10, right: 10, bottom: 10,
                  child: VideoProgressIndicator(controller, allowScrubbing: true, colors: VideoProgressColors(playedColor: accent))),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(_showOriginalComparison ? 'Original source preview' : 'Encoded file preview', style: const TextStyle(color: Colors.white54, fontSize: 11)),
          Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: () => setState(() => _showOriginalComparison = !_showOriginalComparison), icon: Icon(_showOriginalComparison ? Icons.compare_arrows_rounded : Icons.visibility_outlined), label: Text(_showOriginalComparison ? 'Show processed' : 'Compare original'))),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : _saveEnhancedVideo, icon: const Icon(Icons.save_alt_rounded), label: const Text('Save to device'))),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.icon(onPressed: _busy ? null : _shareEnhancedVideo, icon: const Icon(Icons.ios_share_rounded), label: const Text('Share output'))),
          ]),
        ]),
      ),
    );
  }

  Future<void> _saveEnhancedVideo() async {
    final file = _enhancedVideo;
    if (file == null || _busy || _exporting) return;
    final isPhoto = _isPhotoOutput(file);
    setState(() { _busy = true; _message = null; });
    try {
      final saved = await _mediaChannel.invokeMethod<String>('saveVideoToGallery', {
        'inputPath': file.path,
        'displayName': 'StatusHD_${DateTime.now().millisecondsSinceEpoch}.${isPhoto ? 'jpg' : 'mp4'}',
      });
      if (mounted) {
        setState(() => _message = saved == null
            ? 'Export saved, but the gallery did not return a location.'
            : 'Saved to your ${isPhoto ? 'Pictures' : 'Movies'}/Status HD folder. You can find it in Gallery or Files.');
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? 'Could not save this export to the gallery. Use Share instead.');
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not save this export to the gallery. Use Share instead.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareEnhancedVideo() async {
    final file = _enhancedVideo;
    if (file == null || _busy) return;
    final isPhoto = _isPhotoOutput(file);
    setState(() { _busy = true; _message = null; });
    try {
      await Share.shareXFiles([file], subject: 'Processed ${isPhoto ? 'photo' : 'video'} · Status HD', text: '${isPhoto ? 'Photo' : 'Video'} processed with picture adjustments in Status HD');
      if (mounted) setState(() => _message = isPhoto
          ? 'Enhanced photo handed to the share sheet.'
          : 'Enhanced video handed to the share sheet. WhatsApp may still recompress it.');
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not share the enhanced ${isPhoto ? 'photo' : 'video'}.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareMedia() async {
    final file = _selected;
    if (file == null || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await Share.shareXFiles(
        [XFile(file.path, mimeType: _isVideo ? 'video/*' : 'image/*')],
        subject: 'Status HD media',
        text: 'Shared from Status HD',
      );
      if (mounted) setState(() => _message = 'Media handed to the share sheet. The destination app may recompress it.');
    } catch (_) {
      if (mounted) setState(() => _message = 'Sharing failed. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }



  Future<void> _cropVideo() async {
    final file = _selected;
    final controller = _videoController;
    if (file == null || controller == null || !controller.value.isInitialized || _exporting || _busy) return;
    final sourceWidth = controller.value.size.width.round();
    final sourceHeight = controller.value.size.height.round();
    if (sourceWidth < 2 || sourceHeight < 2) {
      setState(() => _message = 'Could not detect the video dimensions.');
      return;
    }
    late final int outputWidth;
    late final int outputHeight;
    switch (_cropRatio) {
      case '9:16':
        outputWidth = 1080;
        outputHeight = 1920;
        break;
      case '1:1':
        outputWidth = 1080;
        outputHeight = 1080;
        break;
      case '16:9':
        outputWidth = 1920;
        outputHeight = 1080;
        break;
      case '4:3':
        outputWidth = 1440;
        outputHeight = 1080;
        break;
      default:
        final longEdge = sourceWidth > sourceHeight ? sourceWidth : sourceHeight;
        final shortEdge = sourceWidth < sourceHeight ? sourceWidth : sourceHeight;
        outputWidth = sourceWidth >= sourceHeight ? longEdge : shortEdge;
        outputHeight = sourceWidth >= sourceHeight ? shortEdge : longEdge;
    }
    setState(() {
      _exporting = true;
      _cancelExportRequested = false;
      _message = 'Cropping video to $_cropRatio…';
      _enhancedVideo = null;
      _segments = [];
    });
    try {
      final output = '${Directory.systemTemp.path}/statushd_crop_${DateTime.now().microsecondsSinceEpoch}.mp4';
      final metadata = await _processing.inspect(file.path);
      final aspectRatio = outputWidth / outputHeight;
      final processed = await _processing.process(ProcessingRequest.crop(
        inputPath: file.path,
        outputPath: output,
        metadata: metadata,
        crop: CropConfiguration.centeredFor(metadata, aspectRatio),
      ));
      final path = processed.path;
      final outputBytes = await File(path).length();
      await _enhancedPreviewController?.dispose();
      final preview = VideoPlayerController.file(File(path));
      await preview.initialize();
      await preview.setLooping(true);
      if (!mounted) {
        await preview.dispose();
        return;
      }
      setState(() {
        _enhancedVideo = XFile(path, mimeType: 'video/mp4');
        _enhancedPreviewController = preview;
        _message = 'Cropped video ready: ${preview.value.size.width.round()}×${preview.value.size.height.round()}. The original is unchanged.';
        _exportEstimateMessage = 'Cropped output: ${_formatBytes(outputBytes)}';
      });
      unawaited(_recordExports([XFile(path, mimeType: 'video/mp4')], 'Cropped video'));
      await preview.play();
      if (mounted) setState(() {});
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? 'Could not crop this video on this device.');
    } catch (error) {
      if (mounted) setState(() => _message = 'Could not crop this video. Try another video. Details: ${error.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportVideoSegments() async {
    final file = _selected;
    final controller = _videoController;
    if (file == null || controller == null || !controller.value.isInitialized || _exporting) return;
    final durationMs = controller.value.duration.inMilliseconds;
    final startMs = (_trimStart * 1000).round().clamp(0, durationMs).toInt();
    final endMs = ((_trimEnd ?? durationMs / 1000) * 1000).round().clamp(0, durationMs).toInt();
    if (endMs - startMs < 1000) {
      setState(() => _message = 'Choose a video range of at least one second.');
      return;
    }
    setState(() { _exporting = true; _message = null; _segments = []; });
    try {
      final List<XFile> exported = [];
      var cursor = startMs;
      var index = 1;
      while (cursor < endMs) {
        final segmentEnd = (cursor + 30000).clamp(0, endMs).toInt();
        final output = '${Directory.systemTemp.path}/statushd_${DateTime.now().microsecondsSinceEpoch}_$index.mp4';
        final path = await _mediaChannel.invokeMethod<String>('trimVideo', {
          'inputPath': file.path,
          'startMs': cursor,
          'endMs': segmentEnd,
          'outputPath': output,
        });
        if (path == null || !await File(path).exists()) {
          throw PlatformException(code: 'export_failed', message: 'The video segment could not be created.');
        }
        exported.add(XFile(path, mimeType: 'video/mp4'));
        cursor = segmentEnd;
        index++;
      }
      if (!mounted) return;
      setState(() {
        _segments = exported;
        _message = 'Created ${exported.length} segment(s), each up to 30 seconds. The video is remuxed where supported, without intentional re-encoding.';
      });
      unawaited(_recordExports(exported, 'Status clip'));
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? 'This video could not be trimmed on this device.');
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not prepare video segments. Try an MP4 video and check available storage.');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _autoSplitFullVideo() async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized || _exporting) return;
    final duration = controller.value.duration.inMilliseconds / 1000.0;
    if (duration <= 0) {
      setState(() => _message = 'Could not read the video duration.');
      return;
    }
    setState(() {
      _trimStart = 0;
      _trimEnd = duration;
      _segments = [];
      _message = 'Automatically splitting the full video into status-length clips…';
    });
    await _exportVideoSegments();
  }

  Future<void> _saveSegments() async {
    if (_segments.isEmpty || _busy || _exporting) return;
    setState(() { _busy = true; _message = null; });
    var savedCount = 0;
    try {
      for (var i = 0; i < _segments.length; i++) {
        await _mediaChannel.invokeMethod<String>('saveVideoToGallery', {
          'inputPath': _segments[i].path,
          'displayName': 'StatusHD_Clip_${DateTime.now().millisecondsSinceEpoch}_${i + 1}.mp4',
        });
        savedCount++;
      }
      if (mounted) setState(() => _message = 'Saved $savedCount clip(s) to Movies/Status HD.');
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = savedCount > 0
          ? 'Saved $savedCount clip(s). The remaining clips could not be saved: ${error.message ?? 'Gallery error'}.'
          : error.message ?? 'Could not save the clips to Gallery.');
    } catch (_) {
      if (mounted) setState(() => _message = savedCount > 0
          ? 'Saved $savedCount clip(s); the remaining clips could not be saved.'
          : 'Could not save the clips to Gallery.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareSegments() async {
    if (_segments.isEmpty || _busy) return;
    setState(() { _busy = true; _message = null; });
    try {
      await Share.shareXFiles(_segments, subject: 'Status HD video segments', text: 'Video segments prepared with Status HD');
      if (mounted) setState(() => _message = 'Segments handed to the share sheet. WhatsApp may process them during upload.');
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not share the exported segments.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _formatTime(double seconds) {
    final total = seconds.floor();
    final minutes = total ~/ 60;
    final remaining = total % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remaining.toString().padLeft(2, '0')}';
  }

  Widget _adjustmentSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
              Text(display, style: TextStyle(fontSize: 11, color: widget.accent, fontWeight: FontWeight.w700)),
            ],
          ),
          Slider(
            min: min,
            max: max,
            divisions: divisions,
            value: value.clamp(min, max).toDouble(),
            onChanged: _exporting ? null : onChanged,
          ),
        ],
      ),
    );
  }

  Widget _outputAndQualityControls(Color accent) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(widget.rounded ? 18 : 10),
          border: Border.all(color: accent.withValues(alpha: .25)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('OUTPUT SIZE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.5, color: Colors.white54)),
          const SizedBox(height: 4),
          const Text('Each resolution sets recommended clarity and sharpness; fine-tune them below.', style: TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in const <(int, String)>[
                (-1, 'Auto'),
                (640, '360p'),
                (854, '480p'),
                (1280, '720p'),
                (1920, '1080p'),
                (2560, '1440p'),
              ])
                ChoiceChip(
                  label: Text(option.$2),
                  selected: _targetLongEdge == option.$1,
                  onSelected: _exporting
                      ? null
                      : (_) => _selectOutputSize(option.$1),
                ),
            ],
          ),
          const SizedBox(height: 14),
          const Text('PICTURE ADJUSTMENTS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.5, color: Colors.white54)),
          const SizedBox(height: 4),
          Text(
            _canApplyPictureAdjustments
                ? 'Clarity and sharpness change the exported pixels.'
                : 'Switch to Conventional mode to apply these picture adjustments.',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 8),
          _adjustmentSlider(
            label: 'Brightness', value: _brightnessBoost, min: -0.10, max: 0.20,
            divisions: 30, display: '${(_brightnessBoost * 100).round()}%',
            onChanged: _canApplyPictureAdjustments ? (value) => setState(() { _brightnessBoost = value; _enhancedVideo = null; }) : null,
          ),
          _adjustmentSlider(
            label: 'Clarity (contrast)', value: _contrastBoost, min: -0.20, max: 0.30,
            divisions: 25, display: '${(_contrastBoost * 100).round()}%',
            onChanged: _canApplyPictureAdjustments ? (value) => setState(() { _contrastBoost = value; _enhancedVideo = null; }) : null,
          ),
          _adjustmentSlider(
            label: 'Color', value: _saturationBoost, min: -20, max: 30,
            divisions: 25, display: '${_saturationBoost.round()}',
            onChanged: _canApplyPictureAdjustments ? (value) => setState(() { _saturationBoost = value; _enhancedVideo = null; }) : null,
          ),
          _adjustmentSlider(
            label: 'Sharpness', value: _sharpnessBoost, min: 0, max: 0.5,
            divisions: 50, display: '${(_sharpnessBoost * 100).round()}%',
            onChanged: _canApplyPictureAdjustments ? (value) => setState(() { _sharpnessBoost = value; _enhancedVideo = null; }) : null,
          ),
        ]),
      );

  Widget _qualityInfo(Color accent) {
    final resolution = _sourceResolution;
    if (resolution == null || _qualityRecommendation == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(widget.rounded ? 18 : 10),
        border: Border.all(color: accent.withValues(alpha: .25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.high_quality_rounded, color: accent),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Detected source quality', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(resolution, style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(_qualityRecommendation!, style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.4)),
          ])),
        ]),
        const SizedBox(height: 14),
        const Text('PROCESSING MODE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.5, color: Colors.white54)),
        const SizedBox(height: 8),
        SegmentedButton<StudioProcessingMode>(
          segments: [
            const ButtonSegment(value: StudioProcessingMode.conventional, label: Text('Conventional'), icon: Icon(Icons.tune_rounded)),
            ButtonSegment(value: StudioProcessingMode.neural, label: const Text('Neural'), icon: const Icon(Icons.auto_awesome_rounded), enabled: _neuralReady),
          ],
          selected: {_processingMode},
          onSelectionChanged: _exporting ? null : (values) => setState(() { _processingMode = values.first; _enhancedVideo = null; }),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 5),
        Text(_processingMode == StudioProcessingMode.neural ? 'Neural mode processes decoded frames with the validated model.' : _neuralStatus, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        const SizedBox(height: 10),
        if (_processingMode == StudioProcessingMode.conventional)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Add Status HD watermark'),
            subtitle: Text(_addWatermark ? 'The exported video will include a visible watermark.' : 'Off. The exported video will not include a watermark.'),
            value: _addWatermark,
            onChanged: _exporting ? null : (value) => setState(() { _addWatermark = value; _enhancedVideo = null; }),
          )
        else
          const Text('Neural mode does not add a watermark.', style: TextStyle(color: Colors.white54, fontSize: 11)),
        if (_exporting) ...[
          LinearProgressIndicator(value: _enhanceProgress > 0 ? _enhanceProgress : null),
          const SizedBox(height: 6),
          Text(_enhanceProgress > 0 ? 'Encoding… ${(_enhanceProgress * 100).round()}%' : 'Applying picture filters and encoding on device…', style: const TextStyle(color: Colors.white60, fontSize: 11)),
        ],
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _exporting || _busy ? null : _enhanceVideo,
            icon: _exporting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome_rounded),
            label: Text(_exporting ? 'Processing video…' : 'Process video · ${_targetLongEdge == -1 ? 'Auto' : _targetLongEdge == 640 ? '360p' : _targetLongEdge == 854 ? '480p' : _targetLongEdge == 1280 ? '720p' : _targetLongEdge == 2560 ? '1440p' : '1080p'}'),
          ),
        ),
        if (_exportEstimateMessage != null) ...[
          const SizedBox(height: 5),
          Text(_exportEstimateMessage!, style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w700)),
        ],
        if (_exporting) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                _cancelExportRequested = true;
                await _processing.cancel();
                _message = 'Cancellation is requested after the current device processing finishes.';
              },
              icon: const Icon(Icons.close_rounded, size: 16),
              label: const Text('Cancel export'),
            ),
          ),
        ],
        if (_enhancedVideo != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _previewEnhancedVideo,
              icon: const Icon(Icons.play_circle_fill_rounded),
              label: const Text('Play processed output'),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _shareEnhancedVideo,
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('Share'),
                ),
              ),
              if (Platform.isAndroid) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : _saveEnhancedVideo,
                    icon: const Icon(Icons.save_alt_rounded),
                    label: const Text('Save to device'),
                  ),
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: 6),
        const Text('These controls apply actual brightness, contrast and color filters before video encoding. Larger output dimensions do not recreate missing detail. Processing uses device resources and creates a new copy; the source file is kept unchanged.', style: TextStyle(color: Colors.white38, fontSize: 10, height: 1.4)),
      ]),
    );
  }

  Widget _videoTools(Color accent) {
    final controller = _videoController;
    final duration = controller?.value.duration.inMilliseconds ?? 0;
    final totalSeconds = duration / 1000.0;
    if (totalSeconds <= 0 || controller?.value.isInitialized != true) {
      return const SizedBox.shrink();
    }
    final start = _trimStart.clamp(0, totalSeconds).toDouble();
    final end = (_trimEnd ?? totalSeconds).clamp(start, totalSeconds).toDouble();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(widget.rounded ? 22 : 12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.crop_rounded, color: accent),
          const SizedBox(width: 9),
          const Expanded(child: Text('Video crop', style: TextStyle(fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 6),
        const Text('Crop the frame to a format for status, square posts or widescreen. Cropping exports a new video and keeps the original untouched.', style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.4)),
        const SizedBox(height: 10),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: '9:16', label: Text('Status 9:16')),
            ButtonSegment(value: '1:1', label: Text('1:1')),
            ButtonSegment(value: '16:9', label: Text('16:9')),
            ButtonSegment(value: '4:3', label: Text('4:3')),
            ButtonSegment(value: 'Original', label: Text('Original')),
          ],
          selected: {_cropRatio},
          onSelectionChanged: _exporting ? null : (values) => setState(() => _cropRatio = values.first),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _exporting || _busy ? null : _cropVideo,
            icon: _exporting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.crop_rounded),
            label: Text(_exporting ? 'Processing video…' : 'Crop & preview video'),
          ),
        ),
        const SizedBox(height: 22),
        Row(children: [
          Icon(Icons.content_cut_rounded, color: accent),
          const SizedBox(width: 9),
          const Expanded(child: Text('Trim & split for Status', style: TextStyle(fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 6),
        const Text('Choose the section to keep. Longer selections are split into clips of up to 30 seconds.', style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.4)),
        const SizedBox(height: 10),
        RangeSlider(
          min: 0,
          max: totalSeconds,
          divisions: totalSeconds.round().clamp(1, 10000).toInt(),
          values: RangeValues(start, end > start ? end : (start + .1).clamp(0, totalSeconds).toDouble()),
          labels: RangeLabels(_formatTime(start), _formatTime(end)),
          activeColor: accent,
          onChanged: _exporting ? null : (range) => setState(() { _trimStart = range.start; _trimEnd = range.end; _segments = []; }),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('IN  ${_formatTime(start)}', style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w800)),
          Text('OUT  ${_formatTime(end)}', style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w800)),
          Text('TOTAL  ${_formatTime(totalSeconds)}', style: const TextStyle(color: Colors.white54, fontSize: 10)),
        ]),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: FilledButton.icon(
          onPressed: _exporting ? null : _autoSplitFullVideo,
          icon: _exporting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome_motion_rounded),
          label: Text(_exporting ? 'Auto-cutting status clips…' : 'Auto-cut full video into status clips'),
        )),
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
          onPressed: _exporting ? null : _exportVideoSegments,
          icon: const Icon(Icons.tune_rounded),
          label: const Text('Create clips from selected range'),
        )),
        if (_segments.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _shareSegments,
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('Share clips'),
                ),
              ),
              if (Platform.isAndroid) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : _saveSegments,
                    icon: const Icon(Icons.save_alt_rounded),
                    label: const Text('Save clips'),
                  ),
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: 5),
        const Text('Lossless remuxing depends on the source codec and keyframes; clip boundaries may align to a nearby keyframe.', style: TextStyle(color: Colors.white38, fontSize: 10, height: 1.4)),
      ]),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: [
            _homeContent(accent),
            _toolsContent(accent),
            const SizedBox.shrink(),
            _settingsContent(accent),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        height: widget.compact ? 62 : 74,
        selectedIndex: _tab,
        onDestinationSelected: (index) {
          if (index == 2) {
            unawaited(_openMoviePlayer());
          } else {
            setState(() => _tab = index);
          }
        },
        backgroundColor: Theme.of(context).colorScheme.surface,
        indicatorColor: accent.withValues(alpha: .16),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.grid_view_rounded), selectedIcon: Icon(Icons.grid_view_rounded), label: 'Studio'),
          NavigationDestination(icon: Icon(Icons.video_library_outlined), selectedIcon: Icon(Icons.video_library_rounded), label: 'Tools'),
          NavigationDestination(icon: Icon(Icons.play_circle_outline_rounded), selectedIcon: Icon(Icons.play_circle_fill_rounded), label: 'Movie Player'),
          NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune_rounded), label: 'Settings'),
        ],
      ),
      drawer: null,
    );
  }

  Future<void> _openMoviePlayer() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const MoviePlayerScreen(),
      ),
    );
  }

  Widget _homeContent(Color accent) {
    final padding = widget.compact ? 16.0 : 20.0;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding, 14, padding, 24),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(15)),
                    child: const Icon(Icons.high_quality_rounded, color: Color(0xFF062015), size: 26),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('STATUS HD', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 2.2)),
                        SizedBox(height: 2),
                        Text('Sharper WhatsApp Status. Your original is never changed.', style: TextStyle(color: Colors.white60, fontSize: 12)),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Open movie player',
                    onPressed: _openMoviePlayer,
                    icon: const Icon(Icons.movie_outlined),
                  ),
                  IconButton(
                    tooltip: 'Media tools',
                    onPressed: () => setState(() => _tab = 1),
                    icon: const Icon(Icons.tune_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              Text('Status HD starts with a\nclip from your phone.', style: TextStyle(fontSize: widget.compact ? 30 : 36, height: 1.06, fontWeight: FontWeight.w800, letterSpacing: -1.15)),
              const SizedBox(height: 12),
              const Text('Choose a photo or video, preview it, then prepare a separate copy for Status. The source stays untouched.', style: TextStyle(color: Colors.white60, height: 1.55, fontSize: 14)),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _featurePill(Icons.high_quality_rounded, 'Quality-ready', accent),
                  _featurePill(Icons.lock_outline_rounded, 'Original preserved', accent),
                  _featurePill(Icons.phone_android_rounded, 'Made for Status', accent),
                ],
              ),
              const SizedBox(height: 18),
              _qualityBanner(accent),
              const SizedBox(height: 12),

              const SizedBox(height: 22),
              if (_selected == null)
                _emptyPicker(accent)
              else ...[
                _outputAndQualityControls(accent),
                const SizedBox(height: 14),
                _mediaPreview(accent),
              ],
              if (_selected != null && !_isVideo) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _exporting || _busy
                        ? null
                        : () => _enhancePhoto(_selected!),
                    icon: _exporting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_rounded),
                    label: Text(_exporting ? 'Processing photo…' : 'Process photo'),
                  ),
                ),
                if (_enhancedVideo != null) ...[
                  const SizedBox(height: 14),
                  _processedOutputPreview(accent),
                ],
              ],
              if (_selected != null && _isVideo) ...[
                const SizedBox(height: 14),
                _whatsAppStatusPreset(accent),
                const SizedBox(height: 14),
                _qualityInfo(accent),
                const SizedBox(height: 14),
                _videoTools(accent),
                if (_enhancedVideo != null) ...[
                  const SizedBox(height: 14),
                  _processedOutputPreview(accent),
                ],
              ],
              if (_recentExports.isNotEmpty) ...[
                const SizedBox(height: 22),
                _recentExportsCard(accent),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: _statCard(Icons.image_outlined, 'Original file', 'Left untouched', accent)),
                  const SizedBox(width: 10),
                  Expanded(child: _statCard(Icons.high_quality_rounded, 'Processed copy', 'Preview first', accent)),
                ],
              ),
              if (_message != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: accent.withValues(alpha: .09), borderRadius: BorderRadius.circular(16)),
                  child: Text(_message!, style: const TextStyle(fontSize: 12, height: 1.45)),
                ),
              ],
              const SizedBox(height: 20),
              const Text('HOW IT WORKS', style: TextStyle(fontSize: 11, letterSpacing: 1.8, fontWeight: FontWeight.w800, color: Colors.white54)),
              const SizedBox(height: 12),
              _stepRow('01', 'Choose a video', 'Status HD detects the source dimensions and format.', accent),
              _stepRow('02', 'Process a new copy', 'Choose an output size; Status HD applies conventional picture enhancement and re-encodes the video on this device.', accent),
              _stepRow('03', 'Review the result', 'Watch the encoded preview here, then save or share the processed copy.', accent),
              const SizedBox(height: 14),
              const Text('Note: WhatsApp can still resize or recompress media after you share it.', style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.5)),
            ]),
          ),
        ),
      ],
    );
  }

  bool _isPhotoOutput(XFile file) => file.path.toLowerCase().endsWith('.jpg') || file.path.toLowerCase().endsWith('.jpeg') || file.path.toLowerCase().endsWith('.png');

  Future<void> _enhancePhoto(XFile file) async {
    if (_exporting || _busy) return;
    setState(() { _exporting = true; _message = 'Preparing enhanced photo…'; _enhancedVideo = null; });
    try {
      final output = '${Directory.systemTemp.path}/statushd_photo_${DateTime.now().microsecondsSinceEpoch}.jpg';
      final result = await _photos.process(inputPath: file.path, outputPath: output, targetLongEdge: _targetLongEdge > 0 ? _targetLongEdge : null, brightness: _brightnessBoost, contrast: _contrastBoost, saturation: _saturationBoost, sharpness: _sharpnessBoost);
      if (!mounted) return;
      setState(() { _enhancedVideo = XFile(result.path, mimeType: 'image/jpeg'); _message = 'Enhanced photo ready: ${result.width}×${result.height} · ${_formatBytes(result.bytes)}. Save or share the new copy.'; _enhanceProgress = 1; });
      unawaited(_recordExports([XFile(result.path, mimeType: 'image/jpeg')], 'Enhanced photo'));
    } catch (error) {
      if (mounted) setState(() => _message = 'Photo enhancement failed: ${error.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _whatsAppStatusPreset(Color accent) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: accent.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(widget.rounded ? 20 : 12),
      border: Border.all(color: accent.withValues(alpha: .28)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.phone_android_rounded, color: accent),
        const SizedBox(width: 9),
        const Expanded(child: Text('WhatsApp Status preset', style: TextStyle(fontWeight: FontWeight.w800))),
        Text('9:16 · 1080p', style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 6),
      const Text('Sets a vertical frame, 1080p output and a 30-second selection. Review and export each step; your original is never changed.', style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.4)),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _exporting ? null : _applyWhatsAppStatusPreset,
          icon: const Icon(Icons.auto_awesome_rounded),
          label: const Text('Apply Status preset'),
        ),
      ),
    ]),
  );

  Widget _recentExportsCard(Color accent) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(widget.rounded ? 20 : 12),
      border: Border.all(color: Colors.white.withValues(alpha: .07)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.history_rounded, color: accent),
        const SizedBox(width: 9),
        const Expanded(child: Text('Recent exports', style: TextStyle(fontWeight: FontWeight.w800))),
        Text('${_recentExports.length}', style: TextStyle(color: accent, fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 6),
      const Text('Quickly share a processed file again. Save important exports to your device; temporary workspace files may be cleared by Android.', style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.4)),
      const SizedBox(height: 8),
      for (final entry in _recentExports.take(4))
        FutureBuilder<bool>(
          future: File(entry['path']!).exists(),
          builder: (context, snapshot) {
            final available = snapshot.data ?? false;
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(available ? Icons.video_file_rounded : Icons.video_file_outlined, color: available ? accent : Colors.white38),
              title: Text(entry['name']!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              subtitle: Text(available ? entry['kind']! : 'Temporary file cleared', style: const TextStyle(fontSize: 11, color: Colors.white54)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: 'Share export', onPressed: available ? () => _shareRecentExport(entry) : null, icon: const Icon(Icons.ios_share_rounded, size: 19)),
                IconButton(tooltip: 'Remove from recent exports', onPressed: () => _removeRecentExport(entry), icon: const Icon(Icons.close_rounded, size: 19)),
              ]),
            );
          },
        ),
    ]),
  );

  Widget _featurePill(IconData icon, String label, Color accent) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: accent.withValues(alpha: .18)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: accent),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white70)),
      ],
    ),
  );

  Widget _qualityBanner(Color accent) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(widget.rounded ? 22 : 12),
      gradient: widget.gradients ? LinearGradient(
        colors: [accent.withValues(alpha: .19), accent.withValues(alpha: .055)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ) : null,
      color: widget.gradients ? null : Theme.of(context).colorScheme.surface,
      border: Border.all(color: accent.withValues(alpha: .23)),
    ),
    child: Row(
      children: [
        Icon(Icons.verified_outlined, color: accent, size: 25),
        const SizedBox(width: 12),
        const Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status quality studio', style: TextStyle(fontWeight: FontWeight.w800)),
            SizedBox(height: 3),
            Text('Detect the source · choose a resolution · encode and review the result', style: TextStyle(fontSize: 11, color: Colors.white60)),
          ],
        )),
      ],
    ),
  );

  Widget _emptyPicker(Color accent) => InkWell(
    onTap: _pickMedia,
    borderRadius: BorderRadius.circular(widget.rounded ? 26 : 12),
    child: Container(
      height: 252,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: widget.gradients
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [accent.withValues(alpha: .18), Theme.of(context).colorScheme.surface, const Color(0xFF10151A)],
              )
            : null,
        color: widget.gradients ? null : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(widget.rounded ? 26 : 12),
        border: Border.all(color: accent.withValues(alpha: .28), width: 1.2),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            height: 62,
            width: 62,
            decoration: BoxDecoration(color: accent.withValues(alpha: .13), shape: BoxShape.circle),
            child: Icon(Icons.add_rounded, color: accent, size: 30),
          ),
          const SizedBox(height: 16),
          const Text('Choose a photo or video', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('Original file • No forced compression', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _pickMedia, icon: const Icon(Icons.add_rounded), label: const Text('Choose from device')),
        ],
      ),
    ),
  );

  Widget _mediaPreview(Color accent) {
    final file = _selected!;
    final video = _isVideo;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(widget.rounded ? 24 : 12),
        border: Border.all(color: Colors.white.withValues(alpha: .07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 9 / 13,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (video && _videoController?.value.isInitialized == true)
                  GestureDetector(
                    onTap: () {
                      final controller = _videoController!;
                      setState(() {
                        if (controller.value.isPlaying) {
                          controller.pause();
                        } else {
                          controller.play();
                        }
                      });
                    },
                    child: VideoPlayer(_videoController!),
                  )
                else if (!video)
                  Image.file(File(file.path), fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image_outlined, size: 48)))
                else
                  const Center(child: CircularProgressIndicator()),
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: .65), borderRadius: BorderRadius.circular(99)),
                    child: Row(children: [
                      Icon(video ? Icons.videocam_outlined : Icons.image_outlined, size: 14, color: accent),
                      const SizedBox(width: 5),
                      Text(video ? 'VIDEO PREVIEW' : 'PHOTO PREVIEW', style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1)),
                    ]),
                  ),
                ),
                if (video && _videoController?.value.isInitialized == true)
                  Positioned(
                    bottom: 12,
                    left: 12,
                    right: 12,
                    child: VideoProgressIndicator(_videoController!, allowScrubbing: true, colors: VideoProgressColors(playedColor: accent)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 5),
                Text('${_formatBytes(File(file.path).existsSync() ? File(file.path).lengthSync() : 0)}  •  Original selected file', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(child: OutlinedButton.icon(onPressed: _pickMedia, icon: const Icon(Icons.swap_horiz_rounded), label: const Text('Change'))),
                  const SizedBox(width: 10),
                  Expanded(child: FilledButton.icon(onPressed: _busy ? null : _shareMedia, icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.ios_share_rounded), label: Text(_busy ? 'Sharing…' : 'Share media'))),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard(IconData icon, String title, String subtitle, Color accent) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(widget.rounded ? 18 : 10)),
    child: Row(children: [
      Icon(icon, color: accent, size: 21),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        const SizedBox(height: 3),
        Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 10)),
      ])),
    ]),
  );

  Widget _stepRow(String number, String title, String detail, Color accent) => Padding(
    padding: const EdgeInsets.only(bottom: 13),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 32, height: 32,
        decoration: BoxDecoration(color: accent.withValues(alpha: .12), borderRadius: BorderRadius.circular(10)),
        alignment: Alignment.center,
        child: Text(number, style: TextStyle(color: accent, fontWeight: FontWeight.w800, fontSize: 10)),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        const SizedBox(height: 3),
        Text(detail, style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.4)),
      ])),
    ]),
  );

  Future<void> _customColorDialog() async {
    var red = widget.customAccent >> 16 & 255;
    var green = widget.customAccent >> 8 & 255;
    var blue = widget.customAccent & 255;
    final color = await showDialog<Color>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Custom RGB color'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 48, height: 48, decoration: BoxDecoration(color: Color.fromARGB(255, red, green, blue), shape: BoxShape.circle)),
          for (final channel in ['Red', 'Green', 'Blue'])
            StatefulBuilder(builder: (context, setLocal) {
              final value = channel == 'Red' ? red : channel == 'Green' ? green : blue;
              return Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(channel), Text('$value')]),
                Slider(min: 0, max: 255, divisions: 255, value: value.toDouble(), onChanged: (v) => setDialogState(() { if (channel == 'Red') red=v.round(); if (channel == 'Green') green=v.round(); if (channel == 'Blue') blue=v.round(); })),
              ]);
            }),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, Color.fromARGB(255, red, green, blue)), child: const Text('Apply')),
        ],
      ),
    ));
    if (color != null) widget.onCustomAccentChanged(color);
  }

  Widget _toolsContent(Color accent) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
    children: [
      const Text('Tools', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -1.1)),
      const SizedBox(height: 8),
      const Text('Everything you need, in two places. Prepare a Status or settle in with a movie.', style: TextStyle(color: Colors.white60, height: 1.5)),
      const SizedBox(height: 20),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [accent.withValues(alpha: .18), Theme.of(context).colorScheme.surface],
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: accent.withValues(alpha: .22)),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: accent.withValues(alpha: .13), borderRadius: BorderRadius.circular(16)),
              child: Icon(Icons.video_settings_rounded, color: accent, size: 27),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Each app has its own door', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  SizedBox(height: 5),
                  Text('Use Status HD for preparing media. Use Movie player for comfortable playback.', style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.45)),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      _toolCard(
        icon: Icons.movie_creation_outlined,
        title: 'Movie player',
        detail: 'Watch local videos with resume support, subtitle tracks, sleep timer, A–B repeat and picture tuning.',
        badge: 'PLAYER',
        onTap: _openMoviePlayer,
        accent: accent,
      ),
      _toolCard(
        icon: Icons.high_quality_rounded,
        title: 'Status HD',
        detail: 'Prepare photos and videos for WhatsApp Status without recompressing your originals. Preview the result before sharing.',
        badge: 'STATUS HD',
        onTap: () {
          setState(() => _tab = 0);
          unawaited(_pickMedia());
        },
        accent: accent,
      ),
      _toolCard(
        icon: Icons.content_cut_rounded,
        title: 'Trim & split',
        detail: 'Select a video, choose the section to keep and prepare short status clips.',
        badge: 'CLIPS',
        onTap: () {
          setState(() => _tab = 0);
          unawaited(_pickMedia());
        },
        accent: accent,
      ),
      _toolCard(
        icon: Icons.ios_share_rounded,
        title: 'Prepare & share',
        detail: 'Preview selected media and pass the prepared file to WhatsApp or another app.',
        badge: 'SHARE',
        onTap: () {
          setState(() => _tab = 0);
          unawaited(_pickMedia());
        },
        accent: accent,
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent.withValues(alpha: .18)),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.tips_and_updates_outlined, color: Color(0xFF55E6A5)),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'A larger resolution is not the same as recovered detail. Status HD detects the source and lets you choose an export size; it does not claim AI restoration.',
                style: TextStyle(color: Colors.white70, height: 1.45, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _toolCard({
    required IconData icon,
    required String title,
    required String detail,
    required String badge,
    required VoidCallback onTap,
    required Color accent,
  }) {
    final tone = badge == 'PLAYER' ? const Color(0xFFFFB755) : accent;
    return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(icon, color: tone, size: 25),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 5),
                    Text(detail, style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.4)),
                    const SizedBox(height: 9),
                    Text(badge, style: TextStyle(color: tone, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.arrow_forward_rounded, color: tone),
            ],
          ),
        ),
      ),
    ),
  );
  }

  Widget _settingsContent(Color accent) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
    children: [
      const Text('Settings', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -1)),
      const SizedBox(height: 8),
      const Text('A private, device-first setup for your media workflow.', style: TextStyle(color: Colors.white60)),
      const SizedBox(height: 24),
      _sectionTitle('MEDIA & PRIVACY'),
      const SizedBox(height: 10),
      _infoTile(Icons.high_quality_outlined, 'Video quality improvement', 'Choose 480p, 720p, 1080p or 1440p, tune brightness, contrast and colour, then preview the processed copy before saving. The original stays unchanged.'),
      _infoTile(Icons.photo_library_outlined, 'Your library stays yours', 'Choose media in Status HD’s own library. Your files stay on this device and are never uploaded to a server.'),
      _infoTile(Icons.privacy_tip_outlined, 'No account required', 'No login or cloud account is needed for the current core workflow.'),
      const SizedBox(height: 24),
      _sectionTitle('ABOUT'),
      const SizedBox(height: 10),
      _infoTile(Icons.auto_awesome_outlined, 'Status HD', 'Version 1.0.0 · Flutter'),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: () => setState(() => _tab = 1),
        icon: const Icon(Icons.video_library_outlined),
        label: const Text('Open media tools'),
      ),
      const SizedBox(height: 18),
      const Text('WhatsApp is a separate service and may compress media during upload. Status HD is not affiliated with WhatsApp.', style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.5)),
    ],
  );

  Widget _sectionTitle(String title) => Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.8, color: Colors.white54));

  Widget _settingTile(IconData icon, String title, String detail, bool value, ValueChanged<bool> onChanged) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(widget.rounded ? 18 : 10),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        secondary: Icon(icon, color: widget.accent),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        subtitle: Text(detail, style: const TextStyle(color: Colors.white54, fontSize: 11, height: 1.35)),
        value: value,
        activeThumbColor: widget.accent,
        onChanged: onChanged,
      ),
    ),
  );

  Widget _infoTile(IconData icon, String title, String detail) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(widget.rounded ? 18 : 10)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: widget.accent, size: 22),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        const SizedBox(height: 5),
        Text(detail, style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.45)),
      ])),
    ]),
  );
}
