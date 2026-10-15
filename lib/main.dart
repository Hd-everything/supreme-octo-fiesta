import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'movie_player_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const _mediaChannel = MethodChannel('com.ptip.statushd/media');

const _accentChoices = <Color>[
  Color(0xFF55E6A5),
  Color(0xFF72A7FF),
  Color(0xFFB79CFF),
  Color(0xFFFFA36C),
  Color(0xFFFF7FA8),
  Color(0xFFF4D35E),
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  runApp(StatusHdApp(preferences: preferences));
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
    final background = _amoled ? const Color(0xFF050706) : const Color(0xFF101512);
    final surface = _amoled ? const Color(0xFF111613) : const Color(0xFF1A211D);
    const foreground = Color(0xFFF1F6F2);
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
  final ImagePicker _picker = ImagePicker();
  XFile? _selected;
  bool _busy = false;
  String? _message;
  int _tab = 0;
  VideoPlayerController? _videoController;
  double _trimStart = 0;
  double? _trimEnd;
  bool _exporting = false;
  List<XFile> _segments = [];
  String? _sourceResolution;
  String? _qualityRecommendation;
  int _targetLongEdge = -1;
  String? _exportEstimateMessage;
  bool _cancelExportRequested = false;
  double _enhanceProgress = 0;
  double _brightnessBoost = 0.06;
  double _contrastBoost = 0.12;
  double _saturationBoost = 8;
  XFile? _enhancedVideo;

  bool get _isVideo {
    final name = _selected?.name.toLowerCase() ?? '';
    return name.endsWith('.mp4') || name.endsWith('.mov') ||
        name.endsWith('.m4v') || name.endsWith('.webm') ||
        name.endsWith('.3gp') || name.endsWith('.mkv');
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _pickMedia() async {
    try {
      final file = await _picker.pickMedia();
      if (file == null || !mounted) return;
      await _videoController?.dispose();
      _videoController = null;
      setState(() {
        _selected = file;
        _message = null;
        _trimStart = 0;
        _trimEnd = null;
        _segments = [];
        _sourceResolution = null;
        _qualityRecommendation = null;
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
          _qualityRecommendation = shortEdge < 480
              ? 'Low-resolution source detected. Status HD can apply real brightness, contrast and color adjustments, then encode an enlarged copy. Upscaling alone cannot restore detail that was never captured.'
              : shortEdge < 720
                  ? 'SD source detected. Status HD will process brightness, contrast and color, then encode an enlarged copy. Enlarging alone cannot restore lost detail.'
                  : 'Status HD can apply picture adjustments and re-encode the video. Choose output size based on your needs; larger dimensions do not guarantee more detail.';
          // Status preparation prioritizes a clean, high-bitrate 1080p upload source.
          // Keep Original available as an explicit no-reencode option.
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
                : 8000000;
    final audioBitrate = _targetLongEdge <= 854 ? 128000 : 160000;
    final estimatedBytes = ((videoBitrate + audioBitrate) * duration.inSeconds / 8).round();
    return 'Estimated size: about ${_formatBytes(estimatedBytes)} · actual size varies by video content';
  }

  Future<void> _enhanceVideo() async {
    final file = _selected;
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
    final targetLongEdge = _targetLongEdge == 0
        ? sourceLongEdge
        : _targetLongEdge == -1
            ? (sourceLongEdge < 1920 ? 1920 : sourceLongEdge)
            : _targetLongEdge;
    final targetShortEdge = (sourceShortEdge * targetLongEdge / sourceLongEdge).round();
    final outputWidth = sourceWidth >= sourceHeight ? targetLongEdge : targetShortEdge;
    final outputHeight = sourceWidth >= sourceHeight ? targetShortEdge : targetLongEdge;
    if (_targetLongEdge == 0) {
      setState(() => _message = 'Original selected. The source file remains unchanged; no re-encode is needed.');
      return;
    }
    final presetLabel = _targetLongEdge == -1 ? 'Auto' : _targetLongEdge == 640 ? '360p' : _targetLongEdge == 854 ? '480p' : _targetLongEdge == 1280 ? '720p' : '1080p';
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
      final processedPath = await _mediaChannel.invokeMethod<String>('enhanceVideo', {
        'inputPath': file.path,
        'outputPath': output,
        'outputWidth': outputWidth,
        'outputHeight': outputHeight,
        'brightness': _brightnessBoost,
        'contrast': _contrastBoost,
        'saturation': _saturationBoost,
      });
      if (_cancelExportRequested) {
        if (processedPath != null) {
          try { await File(processedPath).delete(); } catch (_) {}
        }
        throw StateError('Processing cancelled.');
      }
      if (processedPath == null || !await File(processedPath).exists()) {
        throw StateError('The video processor did not produce an output file.');
      }
      final actualLength = await File(processedPath).length();
      if (actualLength == 0) throw StateError('The processed video is empty.');
      if (!mounted) return;
      setState(() {
        _enhancedVideo = XFile(processedPath, mimeType: 'video/mp4');
        _message = 'Finished encoding at $outputWidth×$outputHeight · ${_formatBytes(actualLength)}. Opening the processed file in Movie Player.';
        _exportEstimateMessage = 'Output: ${outputWidth}×${outputHeight} · ${_formatBytes(actualLength)}';
        _enhanceProgress = 1;
      });
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MoviePlayerScreen(
            initialPath: processedPath,
            initialName: File(processedPath).uri.pathSegments.last,
          ),
        ),
      );
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
    final file = _enhancedVideo;
    if (file == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MoviePlayerScreen(initialPath: file.path, initialName: file.name),
      ),
    );
  }

  Future<void> _saveEnhancedVideo() async {
    final file = _enhancedVideo;
    if (file == null || _busy || _exporting) return;
    setState(() { _busy = true; _message = null; });
    try {
      final saved = await _mediaChannel.invokeMethod<String>('saveVideoToGallery', {
        'inputPath': file.path,
        'displayName': 'StatusHD_${DateTime.now().millisecondsSinceEpoch}.mp4',
      });
      if (mounted) {
        setState(() => _message = saved == null
            ? 'Export saved, but the gallery did not return a location.'
            : 'Saved to your Movies/Status HD folder. You can find it in Gallery or Files.');
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
    setState(() { _busy = true; _message = null; });
    try {
      await Share.shareXFiles([file], subject: 'Processed video · Status HD', text: 'Video processed with picture adjustments in Status HD');
      if (mounted) setState(() => _message = 'Enhanced video handed to the share sheet. WhatsApp may still recompress it.');
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not share the enhanced video.');
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
    required ValueChanged<double> onChanged,
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
        const Text('OUTPUT SIZE (ENCODED)', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.5, color: Colors.white54)),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: -1, label: Text('Auto')),
            ButtonSegment(value: 640, label: Text('360p')),
            ButtonSegment(value: 854, label: Text('480p')),
            ButtonSegment(value: 1280, label: Text('720p')),
            ButtonSegment(value: 1920, label: Text('1080p')),
          ],
          selected: {_targetLongEdge},
          onSelectionChanged: _exporting ? null : (values) => setState(() { _targetLongEdge = values.first; _enhancedVideo = null; _exportEstimateMessage = _estimateExportSize(); }),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 12),
        _adjustmentSlider(
          label: 'Brightness',
          value: _brightnessBoost,
          min: -0.10,
          max: 0.20,
          divisions: 30,
          display: '${(_brightnessBoost * 100).round()}%',
          onChanged: (value) => setState(() { _brightnessBoost = value; _enhancedVideo = null; }),
        ),
        _adjustmentSlider(
          label: 'Contrast',
          value: _contrastBoost,
          min: -0.20,
          max: 0.30,
          divisions: 25,
          display: '${(_contrastBoost * 100).round()}%',
          onChanged: (value) => setState(() { _contrastBoost = value; _enhancedVideo = null; }),
        ),
        _adjustmentSlider(
          label: 'Color',
          value: _saturationBoost,
          min: -20,
          max: 30,
          divisions: 25,
          display: '${_saturationBoost.round()}',
          onChanged: (value) => setState(() { _saturationBoost = value; _enhancedVideo = null; }),
        ),
        const SizedBox(height: 10),
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
            label: Text(_exporting ? 'Processing and encoding…' : 'Process video · ${_targetLongEdge == -1 ? 'Auto / 1080p minimum' : _targetLongEdge == 640 ? '360p' : _targetLongEdge == 854 ? '480p' : _targetLongEdge == 1280 ? '720p' : '1080p'}'),
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
        ],
      ),
      drawer: null,
    );
  }

  Future<void> _openMoviePlayer() async {
    final selected = _selected;
    final hasSelectedVideo = selected != null && _isVideo;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MoviePlayerScreen(
          initialPath: hasSelectedVideo ? selected.path : null,
          initialName: hasSelectedVideo ? selected.name : null,
        ),
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
                        Text('Sharper statuses. Smooth playback.', style: TextStyle(color: Colors.white60, fontSize: 12)),
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
              const SizedBox(height: 28),
              Text('Make your status\nlook its best.', style: TextStyle(fontSize: widget.compact ? 30 : 36, height: 1.04, fontWeight: FontWeight.w800, letterSpacing: -1.25)),
              const SizedBox(height: 12),
              const Text('Process a video to a selected output resolution, then watch the encoded result in Movie Player.', style: TextStyle(color: Colors.white60, height: 1.55, fontSize: 14)),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _featurePill(Icons.high_quality_rounded, 'Auto quality', accent),
                  _featurePill(Icons.lock_outline_rounded, 'Original preserved', accent),
                  _featurePill(Icons.phone_android_rounded, 'WhatsApp-ready', accent),
                ],
              ),
              const SizedBox(height: 18),
              Material(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(widget.rounded ? 24 : 12),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _openMoviePlayer,
                  child: Ink(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          accent.withValues(alpha: .20),
                          Theme.of(context).colorScheme.surface,
                          Theme.of(context).colorScheme.surface,
                        ],
                      ),
                      border: Border.all(color: accent.withValues(alpha: .25)),
                      borderRadius: BorderRadius.circular(widget.rounded ? 24 : 12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Row(
                        children: [
                          Container(
                            width: 54,
                            height: 64,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: .14),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(Icons.play_circle_fill_rounded, color: accent, size: 34),
                          ),
                          const SizedBox(width: 14),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('WATCH ANYTHING', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.5, color: Colors.white60)),
                                SizedBox(height: 5),
                                Text('Movie player', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                                SizedBox(height: 4),
                                Text('Portrait or landscape · broad format support · playback controls', style: TextStyle(fontSize: 11, height: 1.4, color: Colors.white60)),
                              ],
                            ),
                          ),
                          Icon(Icons.arrow_forward_rounded, color: accent),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _qualityBanner(accent),
              const SizedBox(height: 12),

              const SizedBox(height: 22),
              if (_selected == null) _emptyPicker(accent) else _mediaPreview(accent),
              if (_selected != null && _isVideo) ...[
                const SizedBox(height: 14),
                _qualityInfo(accent),
                const SizedBox(height: 14),
                _videoTools(accent),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: _statCard(Icons.image_outlined, 'Original file', 'No re-encode', accent)),
                  const SizedBox(width: 10),
                  Expanded(child: _statCard(Icons.ios_share_rounded, 'Share', 'When ready', accent)),
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
              _stepRow('01', 'Choose media', 'Pick a photo or video from your library.', accent),
              _stepRow('02', 'Check the original', 'Status HD shares the selected file without intentionally re-encoding it.', accent),
              _stepRow('03', 'Send to WhatsApp', 'Choose WhatsApp in the system share sheet.', accent),
              const SizedBox(height: 14),
              const Text('Note: WhatsApp can still resize or recompress media after you share it.', style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.5)),
            ]),
          ),
        ),
      ],
    );
  }

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
            Text('Detect source first · choose Auto or a target quality', style: TextStyle(fontSize: 11, color: Colors.white60)),
          ],
        )),
      ],
    ),
  );

  Widget _emptyPicker(Color accent) => InkWell(
    onTap: _pickMedia,
    borderRadius: BorderRadius.circular(widget.rounded ? 26 : 12),
    child: Container(
      height: 220,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(widget.rounded ? 26 : 12),
        border: Border.all(color: accent.withValues(alpha: .38), width: 1.2),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            height: 62,
            width: 62,
            decoration: BoxDecoration(color: accent.withValues(alpha: .13), shape: BoxShape.circle),
            child: Icon(Icons.add_photo_alternate_outlined, color: accent, size: 30),
          ),
          const SizedBox(height: 16),
          const Text('Choose a photo or video', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('Original file • No forced compression', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: _pickMedia, icon: const Icon(Icons.add_rounded), label: const Text('Select media')),
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
      const Text('Studio tools', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -1.1)),
      const SizedBox(height: 8),
      const Text('Prepare status videos at higher quality, cut long clips into parts, or settle in with the local movie player.', style: TextStyle(color: Colors.white60, height: 1.5)),
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
                  Text('One home for every video', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  SizedBox(height: 5),
                  Text('Prepare a WhatsApp status here. Watch full movies in the separate player.', style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.45)),
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
        title: 'Quality studio',
        detail: 'Detect the source, then use Auto or choose 360p, 480p, 720p or 1080p. Keep the original untouched.',
        badge: 'QUALITY',
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
  }) => Padding(
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
                  color: accent.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(icon, color: accent, size: 25),
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
                    Text(badge, style: TextStyle(color: accent, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.arrow_forward_rounded, color: accent),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _settingsContent(Color accent) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
    children: [
      const Text('Settings', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -1)),
      const SizedBox(height: 8),
      const Text('Simple controls for your media workflow.', style: TextStyle(color: Colors.white60)),
      const SizedBox(height: 24),
      _sectionTitle('MEDIA & PRIVACY'),
      const SizedBox(height: 10),
      _infoTile(Icons.high_quality_outlined, 'Quality-aware exports', 'Export status videos at high-quality 1080p by default, or choose a smaller size when you need to save storage. The original file stays unchanged.'),
      _infoTile(Icons.folder_open_outlined, 'Your library stays yours', 'Media is selected through the system picker. This app does not upload your files to a server.'),
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
