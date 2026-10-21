import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final List<List<EditClip>> _undo = [];
  final List<List<EditClip>> _redo = [];
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
    if (recordUndo) { _undo.add(List<EditClip>.of(_project.clips)); _redo.clear(); }
    setState(() {
      _project = _project.copyWith(clips: clips);
      _exportPath = null;
      _previewingExport = false;
      if (_selectedIndex >= clips.length) _selectedIndex = clips.length - 1;
    });
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () => widget.store.save(_project));
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
    if (newIndex > oldIndex) newIndex--;
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
    _undo.add(List<EditClip>.of(_project.clips));
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

  void _undoEdit() {
    if (_undo.isEmpty) return;
    _redo.add(List<EditClip>.of(_project.clips));
    final clips = _undo.removeLast();
    _changeClips(clips, recordUndo: false);
    unawaited(_loadClipPreview(_selectedIndex.clamp(0, clips.length - 1).toInt()));
  }

  void _redoEdit() {
    if (_redo.isEmpty) return;
    _undo.add(List<EditClip>.of(_project.clips));
    final clips = _redo.removeLast();
    _changeClips(clips, recordUndo: false);
    unawaited(_loadClipPreview(_selectedIndex.clamp(0, clips.length - 1).toInt()));
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
      final resultPath = await _processing.exportProject(clips: _project.clips, outputPath: path);
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
          AspectRatio(aspectRatio: 16 / 9, child: ClipRRect(borderRadius: BorderRadius.circular(16), child: ColoredBox(color: Colors.black, child: playerReady ? VideoPlayer(player!) : const Center(child: CircularProgressIndicator())))),
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
              onReorder: _reorder,
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
            Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _splitAtPlayhead, icon: const Icon(Icons.content_cut_rounded), label: const Text('Split at playhead'))), const SizedBox(width: 9), Expanded(child: OutlinedButton.icon(onPressed: _addClips, icon: const Icon(Icons.add_rounded), label: const Text('Add clips')))]),
            const SizedBox(height: 6),
            const Text('Drag clips to reorder. Select a clip to preview and trim. Export joins the trimmed clips with their original audio.', style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.4)),
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
