import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'media_manager_screen.dart';
import 'models/edit_project.dart';
import 'services/edit_project_store.dart';
import 'services/ads/rewarded_ad_service.dart';
import 'services/media_processing/video_processing_service.dart';

class ProjectEditorScreen extends StatefulWidget {
  const ProjectEditorScreen({super.key, required this.project, required this.store});
  final EditProject project;
  final EditProjectStore store;

  @override
  State<ProjectEditorScreen> createState() => _ProjectEditorScreenState();
}

class _ProjectEditorScreenState extends State<ProjectEditorScreen> {
  static const _mediaChannel = MethodChannel('com.ptip.statushd/media');
  late EditProject _project = widget.project;
  late final VideoProcessingService _processing = VideoProcessingService();
  final RewardedAdService _rewardedAds = RewardedAdService();
  final List<EditProject> _undo = [];
  final List<EditProject> _redo = [];
  final Map<String, Future<Uint8List?>> _thumbnails = {};
  VideoPlayerController? _controller;
  VideoPlayerController? _exportController;
  Timer? _saveTimer;
  int _selectedIndex = 0;
  bool _exporting = false;
  bool _watchingRewardedAd = false;
  bool _previewingExport = false;
  double _progress = 0;
  String? _exportPath;
  StreamSubscription<int>? _progressSubscription;
  bool _seekingToRangeStart = false;
  int _previewLoadId = 0;

  EditClip get _selectedClip => _project.clips[_selectedIndex];

  @override
  void initState() {
    super.initState();
    unawaited(_rewardedAds.preload());
    _progressSubscription = _processing.progress.listen((value) { if (mounted && _exporting) setState(() => _progress = value / 100); });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadClipPreview(0));
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // Flush an edit that is still inside the debounce window when the editor
    // is closed, so a quick back gesture cannot discard the latest trim/order.
    unawaited(widget.store.save(_project));
    _progressSubscription?.cancel();
    _controller?.removeListener(_watchPreview);
    _controller?.dispose();
    _exportController?.dispose();
    super.dispose();
  }

  Future<void> _loadClipPreview(int index) async {
    if (index < 0 || index >= _project.clips.length) return;
    final loadId = ++_previewLoadId;
    final clip = _project.clips[index];
    if (!File(clip.path).existsSync()) { if (mounted) _message('This source video is missing. Re-import it to restore this clip.'); return; }
    final previous = _controller;
    previous?.removeListener(_watchPreview);
    if (mounted) setState(() { _controller = null; _selectedIndex = index; _previewingExport = false; });
    await previous?.dispose();
    final next = VideoPlayerController.file(File(clip.path));
    try {
      await next.initialize();
      await next.seekTo(Duration(milliseconds: clip.startMs));
      next.addListener(_watchPreview);
      if (!mounted || loadId != _previewLoadId) { await next.dispose(); return; }
      setState(() { _selectedIndex = index; _controller = next; _previewingExport = false; });
    } catch (_) {
      await next.dispose();
      if (mounted) _message('Vyntra could not decode this source video on this device.');
    }
  }

  void _watchPreview() {
    final controller = _controller;
    if (controller == null || _selectedIndex >= _project.clips.length || _seekingToRangeStart) return;
    final clip = _selectedClip;
    if (controller.value.isPlaying && controller.value.position.inMilliseconds >= clip.endMs) {
      _seekingToRangeStart = true;
      unawaited(controller.pause().then((_) => controller.seekTo(Duration(milliseconds: clip.startMs))).whenComplete(() => _seekingToRangeStart = false));
    }
  }

  void _message(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _changeClips(List<EditClip> clips, {bool recordUndo = true}) {
    if (recordUndo) { _undo.add(_project); _redo.clear(); }
    setState(() {
      _project = _project.copyWith(clips: clips);
      _exportPath = null;
      _previewingExport = false;
      if (_selectedIndex >= clips.length) _selectedIndex = clips.length - 1;
    });
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () => widget.store.save(_project));
  }

  void _changeProject(EditProject project, {bool recordUndo = true}) {
    if (project.toJson().toString() == _project.toJson().toString()) return;
    if (recordUndo) { _undo.add(_project); _redo.clear(); }
    setState(() { _project = project.copyWith(); _exportPath = null; _previewingExport = false; });
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () => widget.store.save(_project));
  }

  void _updateSelectedClip(EditClip clip, {bool recordUndo = true}) {
    final clips = List<EditClip>.of(_project.clips);
    clips[_selectedIndex] = clip;
    _changeClips(clips, recordUndo: recordUndo);
  }

  Future<void> _addTextOverlay() async {
    final textController = TextEditingController();
    final startController = TextEditingController(text: '0');
    final endController = TextEditingController(text: (_project.durationMs / 1000).toStringAsFixed(1));
    final result = await showDialog<EditTextOverlay>(context: context, builder: (context) => AlertDialog(
      title: const Text('Add timed text'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: textController, autofocus: true, maxLength: 80, decoration: const InputDecoration(labelText: 'Text', hintText: 'Your title or caption')),
        Row(children: [Expanded(child: TextField(controller: startController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Start (seconds)'))), const SizedBox(width: 12), Expanded(child: TextField(controller: endController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'End (seconds)')))]),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () {
        final text = textController.text.trim();
        final start = (double.tryParse(startController.text) ?? 0).clamp(0, _project.durationMs / 1000);
        final end = (double.tryParse(endController.text) ?? _project.durationMs / 1000).clamp(0, _project.durationMs / 1000);
        if (text.isEmpty || end <= start) return;
        Navigator.pop(context, EditTextOverlay(id: DateTime.now().microsecondsSinceEpoch.toString(), text: text, startMs: (start * 1000).round(), endMs: (end * 1000).round()));
      }, child: const Text('Add text'))],
    ));
    textController.dispose();
    startController.dispose();
    endController.dispose();
    if (result == null || !mounted) return;
    _changeProject(_project.copyWith(overlays: [..._project.overlays, result]));
  }

  Future<void> _addMusic() async {
    final selection = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: false, withData: false);
    if (selection == null || selection.files.isEmpty || selection.files.single.path == null || !mounted) return;
    try {
      final destination = await _mediaChannel.invokeMethod<String>('copyAudioToProject', {'inputPath': selection.files.single.path, 'projectId': _project.id});
      if (destination == null) throw StateError('Could not store the selected audio.');
      _changeProject(_project.copyWith(musicPath: destination, musicName: selection.files.single.name));
      _message('Added music. It will be mixed into the exported video.');
    } on PlatformException catch (error) { _message(error.message ?? 'Could not add this audio file.'); }
    catch (_) { _message('Could not add this audio file.'); }
  }

  Future<void> _addImageOverlay() async {
    final selection = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: false, withData: false);
    if (selection == null || selection.files.isEmpty || selection.files.single.path == null || !mounted) return;
    try {
      final path = await _mediaChannel.invokeMethod<String>('copyImageToProject', {'inputPath': selection.files.single.path, 'projectId': _project.id});
      if (path == null) throw StateError('Could not store the selected image.');
      final overlay = EditImageOverlay(id: DateTime.now().microsecondsSinceEpoch.toString(), path: path, name: selection.files.single.name, startMs: 0, endMs: _project.durationMs);
      _changeProject(_project.copyWith(imageOverlays: [..._project.imageOverlays, overlay]));
      _message('Image overlay added. It will be included in the exported video.');
    } on PlatformException catch (error) { _message(error.message ?? 'Could not add this image.'); }
    catch (_) { _message('Could not add this image.'); }
  }

  Future<void> _editImageOverlay(EditImageOverlay overlay) async {
    var x = overlay.x;
    var y = overlay.y;
    var scale = overlay.scale;
    final save = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(builder: (context, updateDialog) => AlertDialog(
      title: const Text('Position image overlay'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [const SizedBox(width: 42, child: Text('Left')), Expanded(child: Slider(value: x, onChanged: (value) => updateDialog(() => x = value)))]),
        Row(children: [const SizedBox(width: 42, child: Text('Top')), Expanded(child: Slider(value: y, onChanged: (value) => updateDialog(() => y = value)))]),
        Row(children: [const SizedBox(width: 42, child: Text('Size')), Expanded(child: Slider(min: .05, max: 1, value: scale, onChanged: (value) => updateDialog(() => scale = value)))]),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Apply'))],
    )));
    if (save != true || !mounted) return;
    final updated = EditImageOverlay(id: overlay.id, path: overlay.path, name: overlay.name, startMs: overlay.startMs, endMs: overlay.endMs, x: x, y: y, scale: scale);
    _changeProject(_project.copyWith(imageOverlays: _project.imageOverlays.map((item) => item.id == overlay.id ? updated : item).toList()));
  }

  Future<void> _addClips() async {
    final selection = await Navigator.of(context).push<List<DeviceMedia>>(MaterialPageRoute(builder: (_) => const MediaManagerScreen(videosOnly: true, multiSelect: true)));
    if (selection == null || selection.isEmpty || !mounted) return;
    if (_project.clips.length + selection.length > 24) { _message('Projects can contain up to 24 clips.'); return; }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    _changeClips([..._project.clips, ...selection.asMap().entries.map((entry) => EditClip(id: '${id}_${entry.key}', path: entry.value.path, name: entry.value.name, durationMs: entry.value.duration))]);
    await _loadClipPreview(_project.clips.length - selection.length);
  }

  void _reorder(int oldIndex, int newIndex) {
    final clips = List<EditClip>.of(_project.clips);
    final clip = clips.removeAt(oldIndex);
    clips.insert(newIndex, clip);
    final selectedId = _selectedClip.id;
    _changeClips(clips);
    final selected = clips.indexWhere((item) => item.id == selectedId);
    unawaited(_loadClipPreview(selected));
  }

  void _applyRange(double startSeconds, double endSeconds) {
    final clip = _selectedClip;
    final start = (startSeconds * 1000).round().clamp(0, clip.durationMs - 1).toInt();
    final end = (endSeconds * 1000).round().clamp(start + 1, clip.durationMs).toInt();
    final clips = List<EditClip>.of(_project.clips);
    clips[_selectedIndex] = clip.copyWith(startMs: start, endMs: end);
    _changeClips(clips, recordUndo: false);
  }

  void _beginTrim() {
    _undo.add(_project);
    _redo.clear();
  }

  Future<void> _splitAtPlayhead() async {
    final controller = _controller;
    if (controller == null) return;
    final clip = _selectedClip;
    final playhead = controller.value.position.inMilliseconds;
    if (playhead <= clip.startMs + 100 || playhead >= clip.endMs - 100) { _message('Move the playhead inside the selected clip range before splitting.'); return; }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final clips = List<EditClip>.of(_project.clips);
    clips.replaceRange(_selectedIndex, _selectedIndex + 1, [
      clip.copyWith(id: '${clip.id}_a_$stamp', endMs: playhead),
      clip.copyWith(id: '${clip.id}_b_$stamp', startMs: playhead),
    ]);
    _changeClips(clips);
    await _loadClipPreview(_selectedIndex + 1);
  }

  void _removeSelected() {
    if (_project.clips.length == 1) { _message('A project needs at least one video clip.'); return; }
    final clips = List<EditClip>.of(_project.clips)..removeAt(_selectedIndex);
    _changeClips(clips);
    unawaited(_loadClipPreview(_selectedIndex.clamp(0, clips.length - 1).toInt()));
  }

  void _duplicateSelected() {
    if (_project.clips.length >= 24) { _message('Projects can contain up to 24 clips.'); return; }
    final clip = _selectedClip;
    final duplicate = clip.copyWith(id: '${DateTime.now().microsecondsSinceEpoch}_copy', name: '${clip.name} copy');
    final clips = List<EditClip>.of(_project.clips)..insert(_selectedIndex + 1, duplicate);
    _changeClips(clips);
    unawaited(_loadClipPreview(_selectedIndex + 1));
  }

  void _undoEdit() {
    if (_undo.isEmpty) return;
    _redo.add(_project);
    final project = _undo.removeLast();
    setState(() { _project = project; _exportPath = null; _previewingExport = false; _selectedIndex = _selectedIndex.clamp(0, project.clips.length - 1).toInt(); });
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () => widget.store.save(_project));
    unawaited(_loadClipPreview(_selectedIndex));
  }

  void _redoEdit() {
    if (_redo.isEmpty) return;
    _undo.add(_project);
    final project = _redo.removeLast();
    setState(() { _project = project; _exportPath = null; _previewingExport = false; _selectedIndex = _selectedIndex.clamp(0, project.clips.length - 1).toInt(); });
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () => widget.store.save(_project));
    unawaited(_loadClipPreview(_selectedIndex));
  }

  Future<void> _renameProject() async {
    final text = TextEditingController(text: _project.name);
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Project name'),
      content: TextField(controller: text, autofocus: true, maxLength: 48),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, text.text.trim()), child: const Text('Save'))],
    ));
    text.dispose();
    if (name == null || name.isEmpty) return;
    setState(() => _project = _project.copyWith(name: name));
    await widget.store.save(_project);
  }

  Future<void> _export() async {
    if (_exporting || _project.clips.isEmpty) return;
    const creditKey = 'vyntra_project_export_credits_v1';
    var credits = widget.store.preferences.getInt(creditKey) ?? 0;
    setState(() { _exporting = true; _watchingRewardedAd = credits <= 0; _progress = 0; });
    try {
      if (credits <= 0) {
        _message('Watch one rewarded ad to unlock one project export.');
        if (!await _rewardedAds.showFor1080p()) {
          if (mounted) _message('The ad was unavailable or not completed. Your project is unchanged.');
          return;
        }
        credits = 1;
        await widget.store.preferences.setInt(creditKey, credits);
      }
      if (mounted) setState(() => _watchingRewardedAd = false);
      _message('Rendering project…');
      final path = '${Directory.systemTemp.path}/vyntra_${_project.id}_${DateTime.now().microsecondsSinceEpoch}.mp4';
      final resultPath = await _processing.exportProject(
        clips: _project.clips,
        outputPath: path,
        aspectRatio: _project.aspectRatio,
        musicPath: _project.musicPath,
        musicVolume: _project.musicVolume,
        musicOffsetMs: _project.musicOffsetMs,
        overlays: _project.overlays,
        imageOverlays: _project.imageOverlays,
      );
      await widget.store.preferences.setInt(creditKey, credits - 1);
      try { await _recordExport(resultPath); } catch (_) {}
      final preview = VideoPlayerController.file(File(resultPath));
      try {
        await preview.initialize();
        await _exportController?.dispose();
        if (!mounted) { await preview.dispose(); return; }
        setState(() { _exportController = preview; _previewingExport = true; _exportPath = resultPath; _progress = 1; });
        _message('Export complete. Review, save, or share your video.');
      } catch (_) {
        await preview.dispose();
        if (mounted) { setState(() { _exportPath = resultPath; _progress = 1; }); _message('Export is ready, but this device could not preview it. You can still save or share the file.'); }
      }
    } catch (error) {
      if (mounted) _message('Export failed: ${error.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() { _exporting = false; _watchingRewardedAd = false; });
    }
  }

  Future<void> _saveExport() async {
    final path = _exportPath;
    if (path == null) return;
    try {
      await _mediaChannel.invokeMethod<String>('saveVideoToGallery', {'inputPath': path, 'displayName': 'Vyntra_${DateTime.now().millisecondsSinceEpoch}.mp4'});
      if (mounted) _message('Saved to Movies/Vyntra.');
    } on PlatformException catch (error) { if (mounted) _message(error.message ?? 'Could not save the exported video.'); }
  }

  Future<void> _recordExport(String path) async {
    const key = 'recent_status_exports_v1';
    final entries = widget.store.preferences.getStringList(key) ?? <String>[];
    entries.removeWhere((raw) { try { return (jsonDecode(raw) as Map<String, dynamic>)['path'] == path; } catch (_) { return false; } });
    entries.insert(0, jsonEncode({'path': path, 'name': '${_project.name}.mp4', 'kind': 'Edited project', 'createdAt': DateTime.now().toIso8601String()}));
    await widget.store.preferences.setStringList(key, entries.take(12).toList());
  }

  Future<void> _shareExport() async {
    final path = _exportPath;
    if (path != null) await Share.shareXFiles([XFile(path, mimeType: 'video/mp4')], subject: 'Created with Vyntra');
  }

  Future<Uint8List?> _thumbnail(EditClip clip) => _thumbnails.putIfAbsent(clip.id, () async {
        try { return await _mediaChannel.invokeMethod<Uint8List>('videoThumbnail', {'path': clip.path, 'timeMs': clip.startMs + 500}); } catch (_) { return null; }
      });

  String _time(int milliseconds) => '${milliseconds ~/ 60000}:${((milliseconds ~/ 1000) % 60).toString().padLeft(2, '0')}';

  Widget _adjustmentSlider(String label, double value, double min, double max, ValueChanged<double> onChanged, {String? labelText}) => Row(children: [
        SizedBox(width: 92, child: Text(label, style: const TextStyle(fontSize: 10, color: Colors.white70))),
        Expanded(child: Slider(min: min, max: max, value: value.clamp(min, max).toDouble(), onChangeStart: (_) => _beginTrim(), onChanged: onChanged)),
        SizedBox(width: 38, child: Text(labelText ?? value.toStringAsFixed(2), textAlign: TextAlign.end, style: const TextStyle(fontSize: 9, color: Colors.white54))),
      ]);

  Widget _timelineCard(EditClip clip, int index, Color accent) {
    final duration = clip.lengthMs;
    final image = _thumbnail(clip);
    final cardWidth = (duration / 1000 * 20).clamp(124, 300).toDouble();
    return SizedBox(width: cardWidth, child: Material(
      key: ValueKey(clip.id),
      color: index == _selectedIndex ? accent.withValues(alpha: .16) : const Color(0xFF191D24),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: () => _loadClipPreview(index), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: FutureBuilder<Uint8List?>(future: image, builder: (context, snapshot) => snapshot.data == null
            ? const Center(child: Icon(Icons.movie_outlined, color: Colors.white54))
            : Image.memory(snapshot.data!, fit: BoxFit.cover, gaplessPlayback: true))),
        Padding(padding: const EdgeInsets.fromLTRB(9, 6, 5, 4), child: Row(children: [
          Expanded(child: Text(clip.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700))),
          Text(_time(duration), style: TextStyle(fontSize: 9, color: accent)),
          ReorderableDragStartListener(index: index, child: const Padding(padding: EdgeInsets.only(left: 5), child: Icon(Icons.drag_indicator_rounded, size: 15, color: Colors.white54))),
        ])),
      ]))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final clip = _selectedClip;
    final player = _previewingExport ? _exportController : _controller;
    final playerReady = player?.value.isInitialized == true;
    final previewAspect = switch (_project.aspectRatio) {
      '9:16' => 9 / 16,
      '16:9' => 16 / 9,
      '1:1' => 1.0,
      '4:5' => 4 / 5,
      _ => playerReady ? (_selectedClip.rotation % 180 == 0 ? player!.value.aspectRatio : 1 / player!.value.aspectRatio) : 16 / 9,
    };
    final selectedGlobalStart = _project.clips.take(_selectedIndex).fold<int>(0, (sum, item) => sum + item.lengthMs);
    final clipPosition = playerReady && !_previewingExport ? (player!.value.position.inMilliseconds - clip.startMs).clamp(0, clip.lengthMs) : 0;
    final projectPosition = selectedGlobalStart + clipPosition;
    final visibleText = _previewingExport ? const <EditTextOverlay>[] : _project.overlays.where((overlay) => overlay.startMs <= projectPosition && overlay.endMs > projectPosition).toList();
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(onTap: _renameProject, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_project.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)), const Text('VYNTRA · VIDEO EDITOR', style: TextStyle(fontSize: 9, letterSpacing: 1.3, color: Colors.white54))])),
        actions: [
          IconButton(tooltip: 'Undo', onPressed: _undo.isEmpty || _exporting ? null : _undoEdit, icon: const Icon(Icons.undo_rounded)),
          IconButton(tooltip: 'Redo', onPressed: _redo.isEmpty || _exporting ? null : _redoEdit, icon: const Icon(Icons.redo_rounded)),
          TextButton.icon(onPressed: _exporting ? null : _export, icon: const Icon(Icons.file_upload_outlined), label: const Text('Export')),
        ],
      ),
      body: SafeArea(child: Column(children: [
        Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 18), children: [
          AspectRatio(aspectRatio: previewAspect, child: ClipRRect(borderRadius: BorderRadius.circular(16), child: ColoredBox(color: Colors.black, child: playerReady ? LayoutBuilder(builder: (context, bounds) => Stack(fit: StackFit.expand, children: [
            Center(child: RotatedBox(quarterTurns: _previewingExport ? 0 : _selectedClip.rotation ~/ 90, child: VideoPlayer(player!))),
            for (final overlay in visibleText) Align(alignment: Alignment(overlay.x, overlay.y * 2 - 1), child: Padding(padding: const EdgeInsets.all(18), child: Text(overlay.text, textAlign: TextAlign.center, style: TextStyle(color: Color(overlay.color), fontWeight: FontWeight.w900, fontSize: overlay.fontSize, shadows: const [Shadow(color: Colors.black87, blurRadius: 8, offset: Offset(1, 2))])))),
            if (!_previewingExport) for (final overlay in _project.imageOverlays.where((overlay) => overlay.startMs <= projectPosition && overlay.endMs > projectPosition)) Positioned(left: (bounds.maxWidth * overlay.x).clamp(0, bounds.maxWidth - 32).toDouble(), top: (bounds.maxHeight * overlay.y).clamp(0, bounds.maxHeight - 32).toDouble(), width: (bounds.maxWidth * overlay.scale).clamp(32, bounds.maxWidth).toDouble(), height: (bounds.maxWidth * overlay.scale).clamp(32, bounds.maxWidth).toDouble(), child: Image.file(File(overlay.path), fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Colors.white70))),
          ])) : const Center(child: CircularProgressIndicator())))),
          const SizedBox(height: 9),
          Row(children: [
            IconButton.filledTonal(onPressed: !playerReady ? null : () { if (player!.value.isPlaying) { player.pause(); } else { player.play(); } }, icon: Icon(playerReady && player!.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded)),
            const SizedBox(width: 8),
            if (playerReady) Expanded(child: ValueListenableBuilder<VideoPlayerValue>(valueListenable: player!, builder: (_, value, __) => Slider(
              min: 0,
          max: (value.duration.inMilliseconds / 1000).clamp(.1, double.infinity).toDouble(),
          value: (value.position.inMilliseconds / 1000).clamp(0, value.duration.inMilliseconds / 1000).toDouble(),
              onChanged: (seconds) => player!.seekTo(Duration(milliseconds: (seconds * 1000).round())),
            ))) else const Spacer(),
            Text(playerReady ? _time(player!.value.position.inMilliseconds) : '0:00', style: const TextStyle(fontSize: 11, color: Colors.white60)),
          ]),
          if (_previewingExport) ...[
            OutlinedButton.icon(onPressed: () => setState(() => _previewingExport = false), icon: const Icon(Icons.edit_rounded), label: const Text('Back to project timeline')),
            Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _saveExport, icon: const Icon(Icons.save_alt_rounded), label: const Text('Save'))), const SizedBox(width: 10), Expanded(child: FilledButton.icon(onPressed: _shareExport, icon: const Icon(Icons.share_rounded), label: const Text('Share')))]),
          ] else ...[
            Row(children: [const Icon(Icons.movie_filter_outlined, size: 17), const SizedBox(width: 7), Text('PROJECT TIMELINE · ${_project.clips.length} CLIPS · ${_time(_project.durationMs)}', style: const TextStyle(fontSize: 10, letterSpacing: .6, fontWeight: FontWeight.w800)), const Spacer(), IconButton(onPressed: _addClips, tooltip: 'Add video clips', icon: Icon(Icons.add_to_photos_outlined, color: accent))]),
            SizedBox(height: 126, child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.only(bottom: 5),
              itemCount: _project.clips.length,
              onReorderItem: _reorder,
              itemBuilder: (context, index) => Padding(key: ValueKey(_project.clips[index].id), padding: const EdgeInsets.only(right: 8), child: _timelineCard(_project.clips[index], index, accent)),
            )),
            const SizedBox(height: 5),
            Row(children: [Text('TRIM SELECTED CLIP', style: TextStyle(fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: accent)), const Spacer(), IconButton(onPressed: _removeSelected, tooltip: 'Remove selected clip', icon: const Icon(Icons.delete_outline_rounded))]),
            RangeSlider(
              min: 0,
              max: (clip.durationMs / 1000).clamp(.5, double.infinity).toDouble(),
              divisions: (clip.durationMs ~/ 250).clamp(1, 500).toInt(),
              values: RangeValues((clip.startMs / 1000).clamp(0, clip.durationMs / 1000).toDouble(), (clip.endMs / 1000).clamp(0, clip.durationMs / 1000).toDouble()),
              onChangeStart: _exporting ? null : (_) => _beginTrim(),
              onChanged: _exporting ? null : (range) => _applyRange(range.start, range.end),
              labels: RangeLabels(_time(clip.startMs), _time(clip.endMs)),
            ),
            const SizedBox(height: 6),
            Text('CANVAS', style: TextStyle(fontSize: 10, letterSpacing: 1.3, fontWeight: FontWeight.w800, color: accent)),
            const SizedBox(height: 7),
            Wrap(spacing: 7, runSpacing: 5, children: [for (final ratio in const ['Original', '9:16', '16:9', '1:1', '4:5']) ChoiceChip(label: Text(ratio), selected: _project.aspectRatio == ratio, onSelected: (_) => _changeProject(_project.copyWith(aspectRatio: ratio)))]),
            const SizedBox(height: 7),
            Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _exporting ? null : () => _updateSelectedClip(clip.copyWith(rotation: (clip.rotation + 90) % 360)), icon: const Icon(Icons.rotate_90_degrees_cw_rounded), label: Text('Rotate ${clip.rotation}°'))), const SizedBox(width: 8), Expanded(child: OutlinedButton.icon(onPressed: _exporting ? null : _addTextOverlay, icon: const Icon(Icons.title_rounded), label: const Text('Add text')))]),
            const SizedBox(height: 7),
            OutlinedButton.icon(onPressed: _exporting ? null : _addImageOverlay, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('Add image overlay')),
            const SizedBox(height: 7),
            Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _exporting ? null : _addMusic, icon: const Icon(Icons.music_note_rounded), label: Text(_project.musicName == null ? 'Add music' : 'Change music'))), if (_project.musicPath != null) IconButton(onPressed: () => _changeProject(_project.copyWith(removeMusic: true)), tooltip: 'Remove music track', icon: const Icon(Icons.delete_outline_rounded))]),
            if (_project.musicPath != null) ...[
              Text('MUSIC · ${_project.musicName ?? 'Audio track'}', style: const TextStyle(fontSize: 10, color: Colors.white60)),
              Row(children: [const Text('Volume', style: TextStyle(fontSize: 10)), Expanded(child: Slider(value: _project.musicVolume, onChangeStart: (_) { _undo.add(_project); _redo.clear(); }, onChanged: (value) => _changeProject(_project.copyWith(musicVolume: value), recordUndo: false))), Text('${(_project.musicVolume * 100).round()}%', style: const TextStyle(fontSize: 10))]),
              Row(children: [const Text('Start', style: TextStyle(fontSize: 10)), Expanded(child: Slider(value: _project.musicOffsetMs.clamp(0, _project.durationMs).toDouble(), max: _project.durationMs.clamp(1, 86400000).toDouble(), onChangeStart: (_) { _undo.add(_project); _redo.clear(); }, onChanged: (value) => _changeProject(_project.copyWith(musicOffsetMs: value.round()), recordUndo: false))), Text(_time(_project.musicOffsetMs), style: const TextStyle(fontSize: 10))]),
            ],
            if (_project.overlays.isNotEmpty) ...[
              const SizedBox(height: 7),
              for (final overlay in _project.overlays) Card(child: ListTile(dense: true, leading: Icon(Icons.title_rounded, color: Color(overlay.color)), title: Text(overlay.text, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text('${_time(overlay.startMs)} – ${_time(overlay.endMs)}'), trailing: IconButton(tooltip: 'Remove text overlay', onPressed: () => _changeProject(_project.copyWith(overlays: _project.overlays.where((item) => item.id != overlay.id).toList())), icon: const Icon(Icons.close_rounded))))
            ],
            if (_project.imageOverlays.isNotEmpty) ...[
              const SizedBox(height: 5),
              for (final overlay in _project.imageOverlays) Card(child: ListTile(dense: true, onTap: () => _editImageOverlay(overlay), leading: const Icon(Icons.image_outlined), title: Text(overlay.name, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text('Tap to position · ${_time(overlay.startMs)} – ${_time(overlay.endMs)}'), trailing: IconButton(tooltip: 'Remove image overlay', onPressed: () => _changeProject(_project.copyWith(imageOverlays: _project.imageOverlays.where((item) => item.id != overlay.id).toList())), icon: const Icon(Icons.close_rounded))))
            ],
            ExpansionTile(title: const Text('Clip sound & picture adjustments', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)), tilePadding: EdgeInsets.zero, children: [
              _adjustmentSlider('Original audio', clip.volume, 0, 1, (value) => _updateSelectedClip(clip.copyWith(volume: value), recordUndo: false), labelText: '${(clip.volume * 100).round()}%'),
              _adjustmentSlider('Brightness', clip.brightness, -.25, .25, (value) => _updateSelectedClip(clip.copyWith(brightness: value), recordUndo: false)),
              _adjustmentSlider('Contrast', clip.contrast, -.3, .3, (value) => _updateSelectedClip(clip.copyWith(contrast: value), recordUndo: false)),
              _adjustmentSlider('Saturation', clip.saturation, -20, 30, (value) => _updateSelectedClip(clip.copyWith(saturation: value), recordUndo: false)),
            ]),
            Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _splitAtPlayhead, icon: const Icon(Icons.content_cut_rounded), label: const Text('Split at playhead'))), const SizedBox(width: 8), Expanded(child: OutlinedButton.icon(onPressed: _addClips, icon: const Icon(Icons.add_rounded), label: const Text('Add clips')))]),
            Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _duplicateSelected, icon: const Icon(Icons.control_point_duplicate_rounded), label: const Text('Duplicate clip'))), const SizedBox(width: 8), Expanded(child: OutlinedButton.icon(onPressed: _removeSelected, icon: const Icon(Icons.delete_outline_rounded), label: const Text('Remove clip')))]),
            const SizedBox(height: 6),
            const Text('Drag clips to reorder. Canvas framing, rotation, clip audio, picture adjustments, timed text, and optional music are applied during export.', style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.4)),
            const SizedBox(height: 5),
            const Text('One rewarded ad unlocks one watermark-free project export.', style: TextStyle(color: Colors.white38, fontSize: 10)),
            if (_exportPath != null) ...[
              const SizedBox(height: 10),
              Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _saveExport, icon: const Icon(Icons.save_alt_rounded), label: const Text('Save export'))), const SizedBox(width: 9), Expanded(child: FilledButton.icon(onPressed: _shareExport, icon: const Icon(Icons.share_rounded), label: const Text('Share export')))]),
            ],
          ],
          if (_exporting) ...[const SizedBox(height: 14), LinearProgressIndicator(value: !_watchingRewardedAd && _progress > 0 ? _progress : null), const SizedBox(height: 7), Row(children: [Expanded(child: Text(_watchingRewardedAd ? 'Unlocking one video export…' : _progress > 0 ? 'Rendering project · ${(_progress * 100).round()}%' : 'Rendering project…', style: TextStyle(color: accent, fontSize: 12))), if (!_watchingRewardedAd) TextButton(onPressed: () => _processing.cancel(), child: const Text('Cancel'))])],
        ])),
      ])),
    );
  }
}
