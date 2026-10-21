import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'media_manager_screen.dart';
import 'models/edit_project.dart';
import 'services/edit_project_store.dart';
import 'services/cloud_render_service.dart';
import 'services/supabase_config.dart';
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
  String _exportStatus = 'Rendering project…';
  double _timelineZoom = 1.0;
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


  Future<void> _editTextOverlay(EditTextOverlay overlay) async {
    final textController = TextEditingController(text: overlay.text);
    var startMs = overlay.startMs.toDouble();
    var endMs = overlay.endMs.toDouble();
    var fontSize = overlay.fontSize;
    var x = overlay.x;
    var y = overlay.y;
    var color = overlay.color;
    final duration = _project.durationMs.toDouble().clamp(1, 86400000).toDouble();
    const colors = <(String, int)>[
      ('White', 0xFFFFFFFF),
      ('Yellow', 0xFFFFD54F),
      ('Cyan', 0xFF80DEEA),
      ('Pink', 0xFFF48FB1),
      ('Black', 0xFF000000),
    ];
    final save = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          title: const Text('Edit text layer'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(controller: textController, autofocus: true, maxLength: 160, decoration: const InputDecoration(labelText: 'Text')),
                const SizedBox(height: 12),
                Row(children: [
                  const SizedBox(width: 72, child: Text('Size')),
                  Expanded(child: Slider(min: 16, max: 96, value: fontSize.clamp(16, 96).toDouble(), onChanged: (value) => updateDialog(() => fontSize = value))),
                  Text(fontSize.round().toString()),
                ]),
                const SizedBox(height: 6),
                const Text('TEXT COLOR', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.1)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final item in colors)
                    ChoiceChip(
                      label: Text(item.$1),
                      selected: color == item.$2,
                      avatar: CircleAvatar(backgroundColor: Color(item.$2), radius: 7),
                      onSelected: (_) => updateDialog(() => color = item.$2),
                    ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  const SizedBox(width: 72, child: Text('Horizontal')),
                  Expanded(child: Slider(min: -1, max: 1, value: x.clamp(-1, 1).toDouble(), onChanged: (value) => updateDialog(() => x = value))),
                ]),
                Row(children: [
                  const SizedBox(width: 72, child: Text('Vertical')),
                  Expanded(child: Slider(min: -1, max: 1, value: y.clamp(-1, 1).toDouble(), onChanged: (value) => updateDialog(() => y = value))),
                ]),
                const SizedBox(height: 10),
                const Text('VISIBLE TIMELINE RANGE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.1)),
                RangeSlider(
                  min: 0,
                  max: duration,
                  values: RangeValues(startMs.clamp(0, duration).toDouble(), endMs.clamp(0, duration).toDouble()),
                  labels: RangeLabels(_time(startMs.round()), _time(endMs.round())),
                  onChanged: (range) => updateDialog(() {
                    startMs = range.start;
                    endMs = range.end;
                  }),
                ),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('In ' + _time(startMs.round()), style: const TextStyle(fontSize: 11, color: Colors.white70)),
                  Text('Out ' + _time(endMs.round()), style: const TextStyle(fontSize: 11, color: Colors.white70)),
                ]),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Apply')),
          ],
        ),
      ),
    );
    final text = textController.text.trim();
    textController.dispose();
    if (save != true || !mounted || text.isEmpty) return;
    final start = startMs.round().clamp(0, _project.durationMs - 1).toInt();
    final end = endMs.round().clamp(start + 1, _project.durationMs).toInt();
    final updated = EditTextOverlay(
      id: overlay.id,
      text: text,
      startMs: start,
      endMs: end,
      color: color,
      fontSize: fontSize,
      x: x,
      y: y,
    );
    _changeProject(_project.copyWith(overlays: _project.overlays.map((item) => item.id == overlay.id ? updated : item).toList()));
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
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Export project'),
        content: const Text('Choose where to render your edited video. Cloud export uploads source media to your private Vyntra workspace and renders on a remote FFmpeg worker.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          OutlinedButton(onPressed: () => Navigator.pop(dialogContext, 'local'), child: const Text('Local export')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, 'cloud'), child: const Text('Cloud export')),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'local') return _exportLocal();
    if (choice == 'cloud') return _exportCloud();
  }

  Future<bool> _ensureCloudSignedIn(CloudRenderService service) async {
    if (service.isSignedIn) return true;
    final email = TextEditingController();
    final password = TextEditingController();
    var createAccount = false;
    var errorText = '';
    final signedIn = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          title: Text(createAccount ? 'Create Vyntra cloud account' : 'Sign in to Vyntra cloud'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: email, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email], decoration: const InputDecoration(labelText: 'Email')),
              TextField(controller: password, obscureText: true, autofillHints: const [AutofillHints.password], decoration: const InputDecoration(labelText: 'Password')),
              if (errorText.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(errorText, style: const TextStyle(color: Colors.orangeAccent))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => updateDialog(() { createAccount = !createAccount; errorText = ''; }), child: Text(createAccount ? 'Have an account? Sign in' : 'Create account')),
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                try {
                  if (createAccount) {
                    await service.signUp(email.text, password.text);
                  } else {
                    await service.signIn(email.text, password.text);
                  }
                  if (service.isSignedIn && dialogContext.mounted) Navigator.pop(dialogContext, true);
                } catch (error) {
                  updateDialog(() => errorText = error.toString().replaceFirst('Exception: ', ''));
                }
              },
              child: Text(createAccount ? 'Create account' : 'Sign in'),
            ),
          ],
        ),
      ),
    );
    email.dispose();
    password.dispose();
    return signedIn == true && service.isSignedIn;
  }

  Future<void> _exportCloud() async {
    if (!vyntraSupabaseConfigured) {
      _message('Cloud export needs SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY at build time. Local export remains available.');
      return;
    }
    final service = CloudRenderService(Supabase.instance.client, preferences: widget.store.preferences);
    try {
      if (!await _ensureCloudSignedIn(service)) return;
      final capabilities = await service.capabilities();
      if (capabilities['workerReady'] != true) {
        _message('Cloud export is not ready yet: the separate FFmpeg worker has not been deployed and verified.');
        return;
      }
      final resolutions = (capabilities['resolutions'] as List? ?? const []).cast<String>();
      if (resolutions.isEmpty) {
        _message('The deployed worker has not advertised any verified output resolutions.');
        return;
      }
      var selectedResolution = resolutions.contains('2160p') ? '2160p' : resolutions.first;
      final resolution = await showDialog<String>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, updateDialog) => AlertDialog(
            title: const Text('Cloud export resolution'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DropdownButtonFormField<String>(
                value: selectedResolution,
                decoration: const InputDecoration(labelText: 'Output resolution'),
                items: resolutions.map((value) => DropdownMenuItem(value: value, child: Text(value == '2160p' ? '4K · 3840 × 2160' : value == '4320p' ? '8K · 7680 × 4320' : value))).toList(),
                onChanged: (value) => updateDialog(() => selectedResolution = value ?? selectedResolution),
              ),
              const SizedBox(height: 12),
              const Text('The final file is rendered on the cloud worker. Upload and download data charges may apply.', style: TextStyle(color: Colors.white60, fontSize: 12)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, selectedResolution), child: const Text('Start cloud export')),
            ],
          ),
        ),
      );
      if (resolution == null || !mounted) return;
      setState(() { _exporting = true; _watchingRewardedAd = false; _progress = 0; _exportStatus = 'Preparing secure upload…'; });
      final result = await service.renderProject(
        project: _project,
        resolution: resolution,
        onProgress: (progress) {
          if (mounted) setState(() { _progress = progress.progress.clamp(0, 1); _exportStatus = progress.message ?? progress.stage; });
        },
      );
      final resultPath = result['path'] as String;
      try { await _recordExport(resultPath); } catch (_) {}
      final preview = VideoPlayerController.file(File(resultPath));
      try {
        await preview.initialize();
        await _exportController?.dispose();
        if (!mounted) { await preview.dispose(); return; }
        setState(() { _exportController = preview; _previewingExport = true; _exportPath = resultPath; _progress = 1; _exportStatus = 'Cloud export complete'; });
        _message('Cloud export complete. Review, save, or share your video.');
      } catch (_) {
        await preview.dispose();
        if (mounted) { setState(() { _exportPath = resultPath; _progress = 1; }); _message('Cloud export is downloaded, but this device could not preview it. You can still save or share the file.'); }
      }
    } catch (error) {
      if (mounted) _message('Cloud export: ${error.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() { _exporting = false; _watchingRewardedAd = false; });
    }
  }

  Future<void> _exportLocal() async {
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
      setState(() => _exportStatus = 'Rendering project on this device…');
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


  Future<void> _autoEdit() async {
    if (_exporting || _project.clips.isEmpty) return;
    var style = 'Cinematic';
    var ratio = _project.aspectRatio;
    var targetSeconds = 30;
    var addTitle = true;
    final choice = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.auto_awesome_rounded),
            SizedBox(width: 10),
            Expanded(child: Text('Auto Edit')),
          ]),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Build a first draft from your clips. Every choice remains editable on the timeline.', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 18),
              const Text('LOOK', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
              const SizedBox(height: 7),
              for (final option in const [
                ('Cinematic', 'Balanced contrast · restrained color'),
                ('Vibrant', 'More color · punchier contrast'),
                ('Natural', 'Light touch · closer to the source'),
                ('Soft', 'Gentler contrast · softer color'),
              ])
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: option.$1,
                  groupValue: style,
                  title: Text(option.$1, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(option.$2, style: const TextStyle(fontSize: 11)),
                  onChanged: (value) => updateDialog(() => style = value!),
                ),
              const SizedBox(height: 10),
              const Text('CANVAS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
              const SizedBox(height: 7),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final value in const ['Original', '9:16', '16:9', '1:1', '4:5'])
                  ChoiceChip(label: Text(value), selected: ratio == value, onSelected: (_) => updateDialog(() => ratio = value)),
              ]),
              const SizedBox(height: 16),
              const Text('TARGET LENGTH', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
              Slider(
                min: 10, max: 60, divisions: 5, value: targetSeconds.toDouble(),
                label: '$targetSeconds sec',
                onChanged: (value) => updateDialog(() => targetSeconds = value.round()),
              ),
              Center(child: Text('$targetSeconds seconds', style: const TextStyle(fontWeight: FontWeight.w800))),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: addTitle,
                title: const Text('Add an editable opening title'),
                onChanged: (value) => updateDialog(() => addTitle = value ?? false),
              ),
              const SizedBox(height: 4),
              const Text('Auto Edit uses local timeline rules and built-in picture controls. It does not claim to use cloud AI or analyze scene content yet.', style: TextStyle(fontSize: 11, color: Colors.white60, height: 1.4)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton.icon(onPressed: () => Navigator.pop(dialogContext, true), icon: const Icon(Icons.auto_awesome_rounded), label: const Text('Build draft')),
          ],
        ),
      ),
    );
    if (choice != true || !mounted) return;
    final sourceClips = List<EditClip>.of(_project.clips);
    final available = sourceClips.fold<int>(0, (sum, item) => sum + item.lengthMs);
    final floorDuration = sourceClips.fold<int>(0, (sum, item) => sum + (item.lengthMs < 1000 ? item.lengthMs : 1000));
    final target = (targetSeconds * 1000).clamp(floorDuration, available).toInt();
    final styleValues = switch (style) {
      'Vibrant' => (brightness: .025, contrast: .20, saturation: 20.0),
      'Natural' => (brightness: 0.0, contrast: .04, saturation: 3.0),
      'Soft' => (brightness: .025, contrast: -.08, saturation: 2.0),
      _ => (brightness: .015, contrast: .13, saturation: 8.0),
    };
    final edited = <EditClip>[];
    var remainingTarget = target;
    var remainingSource = available;
    for (var i = 0; i < sourceClips.length; i++) {
      final clip = sourceClips[i];
      final isLast = i == sourceClips.length - 1;
      final desired = isLast
          ? remainingTarget
          : (remainingTarget * clip.lengthMs / remainingSource).round();
      final minimum = clip.lengthMs < 1000 ? clip.lengthMs : 1000;
      final length = desired.clamp(minimum, clip.lengthMs).toInt();
      final start = clip.startMs + ((clip.lengthMs - length) ~/ 2);
      edited.add(clip.copyWith(
        startMs: start,
        endMs: start + length,
        brightness: styleValues.brightness,
        contrast: styleValues.contrast,
        saturation: styleValues.saturation,
      ));
      remainingTarget = (remainingTarget - length).clamp(0, remainingTarget).toInt();
      remainingSource -= clip.lengthMs;
    }
    var overlays = List<EditTextOverlay>.of(_project.overlays);
    if (addTitle) {
      final titleController = TextEditingController(text: _project.name);
      final title = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Opening title'),
          content: TextField(controller: titleController, autofocus: true, maxLength: 48, decoration: const InputDecoration(hintText: 'Your title')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Skip')),
            FilledButton(onPressed: () => Navigator.pop(context, titleController.text.trim()), child: const Text('Use title')),
          ],
        ),
      );
      titleController.dispose();
      if (title != null && title.trim().isNotEmpty) {
        overlays.add(EditTextOverlay(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          text: title.trim(),
          startMs: 0,
          endMs: edited.fold<int>(0, (sum, item) => sum + item.lengthMs).clamp(1, edited.fold<int>(0, (sum, item) => sum + item.lengthMs)).toInt(),
          fontSize: 36,
          y: .48,
        ));
      }
    }
    if (!mounted) return;
    _changeProject(_project.copyWith(clips: edited, aspectRatio: ratio, overlays: overlays));
    await _loadClipPreview(0);
    if (mounted) _message('Auto Edit draft created. Review the timeline, fine-tune it, then export.');
  }

  Future<void> _openEditorTool(String tool) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF15191E),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) {
          final clip = _selectedClip;
          Widget action({required IconData icon, required String label, required VoidCallback? onPressed, bool destructive = false}) => OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(label),
            style: OutlinedButton.styleFrom(
              foregroundColor: destructive ? const Color(0xFFFF817B) : Colors.white,
              side: BorderSide(color: destructive ? const Color(0x66FF817B) : const Color(0xFF343B43)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
            ),
          );
          Widget heading(String title, String subtitle) => Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900, letterSpacing: -.4)),
              const SizedBox(height: 5),
              Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 12)),
            ]),
          );
          Widget ratioPicker() => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final ratio in const ['Original', '9:16', '16:9', '1:1', '4:5'])
                ChoiceChip(
                  label: Text(ratio),
                  selected: _project.aspectRatio == ratio,
                  onSelected: (_) {
                    _changeProject(_project.copyWith(aspectRatio: ratio));
                    updateSheet(() {});
                  },
                ),
            ],
          );
          Widget panel;
          switch (tool) {
            case 'Clip':
              panel = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                heading('Clip tools', 'Edit the selected clip without changing the source file.'),
                Row(children: [
                  Expanded(child: action(icon: Icons.content_cut_rounded, label: 'Split', onPressed: _exporting ? null : () { Navigator.pop(sheetContext); unawaited(_splitAtPlayhead()); })),
                  const SizedBox(width: 8),
                  Expanded(child: action(icon: Icons.control_point_duplicate_rounded, label: 'Duplicate', onPressed: _exporting ? null : () { _duplicateSelected(); updateSheet(() {}); })),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: action(icon: Icons.rotate_90_degrees_cw_rounded, label: 'Rotate 90°', onPressed: _exporting ? null : () { _updateSelectedClip(clip.copyWith(rotation: (clip.rotation + 90) % 360)); updateSheet(() {}); })),
                  const SizedBox(width: 8),
                  Expanded(child: action(icon: Icons.delete_outline_rounded, label: 'Delete clip', destructive: true, onPressed: _exporting || _project.clips.length == 1 ? null : () { _removeSelected(); Navigator.pop(sheetContext); })),
                ]),
                const SizedBox(height: 20),
                const Text('TRIM RANGE', style: TextStyle(fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w800, color: Colors.white70)),
                const SizedBox(height: 4),
                RangeSlider(
                  min: 0,
                  max: (clip.durationMs / 1000).clamp(.5, double.infinity).toDouble(),
                  divisions: (clip.durationMs ~/ 250).clamp(1, 500).toInt(),
                  values: RangeValues((clip.startMs / 1000).clamp(0, clip.durationMs / 1000).toDouble(), (clip.endMs / 1000).clamp(0, clip.durationMs / 1000).toDouble()),
                  onChangeStart: _exporting ? null : (_) => _beginTrim(),
                  onChanged: _exporting ? null : (range) { _applyRange(range.start, range.end); updateSheet(() {}); },
                  labels: RangeLabels(_time(clip.startMs), _time(clip.endMs)),
                ),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('In  ${_time(clip.startMs)}', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  Text('Out  ${_time(clip.endMs)}', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                ]),
              ]);
              break;
            case 'Crop':
              panel = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                heading('Crop & canvas', 'Choose the frame your final video is composed for.'),
                ratioPicker(),
                const SizedBox(height: 18),
                action(icon: Icons.rotate_90_degrees_cw_rounded, label: 'Rotate selected clip · ${clip.rotation}°', onPressed: _exporting ? null : () { _updateSelectedClip(clip.copyWith(rotation: (clip.rotation + 90) % 360)); updateSheet(() {}); }),
                const SizedBox(height: 10),
                const Text('The selected frame ratio is applied during export. Use preview framing to check the composition before rendering.', style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.45)),
              ]);
              break;
            case 'Text':
              panel = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                heading('Text & titles', 'Place timed text over your video.'),
                action(icon: Icons.add_rounded, label: 'Add text overlay', onPressed: _exporting ? null : () async { Navigator.pop(sheetContext); await _addTextOverlay(); }),
                const SizedBox(height: 12),
                if (_project.overlays.isEmpty) const Text('No text layers yet.', style: TextStyle(color: Colors.white54))
                else for (final overlay in _project.overlays)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.title_rounded),
                    title: Text(overlay.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${_time(overlay.startMs)} – ${_time(overlay.endMs)} · ${overlay.fontSize.round()} px'),
                    onTap: () async { Navigator.pop(sheetContext); await _editTextOverlay(overlay); },
                    trailing: Wrap(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(tooltip: 'Edit text layer', onPressed: () async { Navigator.pop(sheetContext); await _editTextOverlay(overlay); }, icon: const Icon(Icons.tune_rounded)),
                      IconButton(tooltip: 'Remove text layer', onPressed: () { _changeProject(_project.copyWith(overlays: _project.overlays.where((item) => item.id != overlay.id).toList())); updateSheet(() {}); }, icon: const Icon(Icons.close_rounded)),
                    ]),
                  ),
              ]);
              break;
            case 'Audio':
              panel = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                heading('Audio mixing', 'Balance original clip sound and your soundtrack.'),
                action(icon: Icons.library_music_outlined, label: _project.musicName == null ? 'Add soundtrack' : 'Change soundtrack', onPressed: _exporting ? null : () async { Navigator.pop(sheetContext); await _addMusic(); }),
                if (_project.musicPath != null) ...[
                  const SizedBox(height: 14),
                  Row(children: [Expanded(child: Text(_project.musicName ?? 'Soundtrack', style: const TextStyle(fontWeight: FontWeight.w700))), IconButton(onPressed: () => _changeProject(_project.copyWith(removeMusic: true)), icon: const Icon(Icons.delete_outline_rounded), tooltip: 'Remove soundtrack')]),
                  Row(children: [const SizedBox(width: 70, child: Text('Music', style: TextStyle(color: Colors.white70, fontSize: 12))), Expanded(child: Slider(value: _project.musicVolume.clamp(0, 1), onChangeStart: (_) { _undo.add(_project); _redo.clear(); }, onChanged: (value) { _changeProject(_project.copyWith(musicVolume: value), recordUndo: false); updateSheet(() {}); })), Text('${(_project.musicVolume * 100).round()}%', style: const TextStyle(fontSize: 11))]),
                  Row(children: [const SizedBox(width: 70, child: Text('Start', style: TextStyle(color: Colors.white70, fontSize: 12))), Expanded(child: Slider(value: _project.musicOffsetMs.clamp(0, _project.durationMs).toDouble(), max: _project.durationMs.clamp(1, 86400000).toDouble(), onChangeStart: (_) { _undo.add(_project); _redo.clear(); }, onChanged: (value) { _changeProject(_project.copyWith(musicOffsetMs: value.round()), recordUndo: false); updateSheet(() {}); })), Text(_time(_project.musicOffsetMs), style: const TextStyle(fontSize: 11))]),
                ],
                const SizedBox(height: 10),
                Row(children: [const SizedBox(width: 70, child: Text('Clip audio', style: TextStyle(color: Colors.white70, fontSize: 12))), Expanded(child: Slider(value: clip.volume.clamp(0, 1), onChangeStart: (_) => _beginTrim(), onChanged: (value) { _updateSelectedClip(clip.copyWith(volume: value), recordUndo: false); updateSheet(() {}); })), Text('${(clip.volume * 100).round()}%', style: const TextStyle(fontSize: 11))]),
              ]);
              break;
            case 'Adjust':
              panel = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                heading('Picture adjustments', 'Fine-tune the selected clip. Changes are included in project export.'),
                _adjustmentSlider('Brightness', clip.brightness, -.25, .25, (value) { _updateSelectedClip(clip.copyWith(brightness: value), recordUndo: false); updateSheet(() {}); }),
                _adjustmentSlider('Contrast', clip.contrast, -.3, .3, (value) { _updateSelectedClip(clip.copyWith(contrast: value), recordUndo: false); updateSheet(() {}); }),
                _adjustmentSlider('Saturation', clip.saturation, -20, 30, (value) { _updateSelectedClip(clip.copyWith(saturation: value), recordUndo: false); updateSheet(() {}); }),
                const SizedBox(height: 14),
                const Text('QUICK LOOKS', style: TextStyle(fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w900, color: Colors.white70)),
                const SizedBox(height: 8),
                Wrap(spacing: 7, runSpacing: 7, children: [
                  for (final look in const ['Original', 'Cinematic', 'Vibrant', 'Natural', 'Soft'])
                    ActionChip(
                      label: Text(look),
                      onPressed: _exporting ? null : () {
                        final values = switch (look) {
                          'Cinematic' => (b: .015, c: .13, s: 8.0),
                          'Vibrant' => (b: .025, c: .20, s: 20.0),
                          'Natural' => (b: 0.0, c: .04, s: 3.0),
                          'Soft' => (b: .025, c: -.08, s: 2.0),
                          _ => (b: 0.0, c: 0.0, s: 0.0),
                        };
                        _updateSelectedClip(clip.copyWith(brightness: values.b, contrast: values.c, saturation: values.s));
                        updateSheet(() {});
                      },
                    ),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  TextButton.icon(
                    onPressed: _exporting ? null : () {
                      final updated = _project.clips.map((item) => item.copyWith(brightness: clip.brightness, contrast: clip.contrast, saturation: clip.saturation)).toList();
                      _changeProject(_project.copyWith(clips: updated));
                      updateSheet(() {});
                    },
                    icon: const Icon(Icons.layers_rounded, size: 17),
                    label: const Text('Apply look to all clips'),
                  ),
                  TextButton.icon(
                    onPressed: _exporting ? null : () {
                      _updateSelectedClip(clip.copyWith(brightness: 0, contrast: 0, saturation: 0));
                      updateSheet(() {});
                    },
                    icon: const Icon(Icons.restart_alt_rounded, size: 17),
                    label: const Text('Reset picture'),
                  ),
                ]),
                const Text('Looks are baked into the exported video. The current preview does not apply these color effects live.', style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4)),
              ]);
              break;
            case 'Layers':
              panel = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                heading('Overlay layers', 'Add and manage graphics above your footage.'),
                action(icon: Icons.add_photo_alternate_outlined, label: 'Add image overlay', onPressed: _exporting ? null : () async { Navigator.pop(sheetContext); await _addImageOverlay(); }),
                const SizedBox(height: 10),
                if (_project.imageOverlays.isEmpty) const Text('No image layers yet.', style: TextStyle(color: Colors.white54))
                else for (final overlay in _project.imageOverlays)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.image_outlined),
                    title: Text(overlay.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('Tap to position · ${_time(overlay.startMs)}–${_time(overlay.endMs)}'),
                    onTap: () async { Navigator.pop(sheetContext); await _editImageOverlay(overlay); },
                    trailing: IconButton(tooltip: 'Remove image layer', onPressed: () { _changeProject(_project.copyWith(imageOverlays: _project.imageOverlays.where((item) => item.id != overlay.id).toList())); updateSheet(() {}); }, icon: const Icon(Icons.close_rounded)),
                  ),
              ]);
              break;
            default:
              panel = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                heading('Add media', 'Bring more footage into this project.'),
                action(icon: Icons.video_library_outlined, label: 'Add video clips', onPressed: _exporting ? null : () async { Navigator.pop(sheetContext); await _addClips(); }),
              ]);
          }
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)))),
                    const SizedBox(height: 20),
                    panel,
                    const SizedBox(height: 12),
                    TextButton(onPressed: () => Navigator.pop(sheetContext), child: const Text('Done')),
                  ],
                ),
              ),
            ),
          );
        },
      ),
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
      _ => playerReady ? (_previewingExport || _selectedClip.rotation % 180 == 0 ? player!.value.aspectRatio : 1 / player!.value.aspectRatio) : 16 / 9,
    };
    final selectedGlobalStart = _project.clips.take(_selectedIndex).fold<int>(0, (sum, item) => sum + item.lengthMs);
    final clipPosition = playerReady && !_previewingExport ? (player!.value.position.inMilliseconds - clip.startMs).clamp(0, clip.lengthMs) : 0;
    final projectPosition = selectedGlobalStart + clipPosition;
    final visibleText = _previewingExport ? const <EditTextOverlay>[] : _project.overlays.where((overlay) => overlay.startMs <= projectPosition && overlay.endMs > projectPosition).toList();
    return Scaffold(
      backgroundColor: const Color(0xFF080A0D),
      appBar: AppBar(
        toolbarHeight: 58,
        leading: IconButton(tooltip: 'Back to projects', onPressed: () => Navigator.maybePop(context), icon: const Icon(Icons.arrow_back_rounded)),
        titleSpacing: 0,
        title: GestureDetector(
          onTap: _renameProject,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_project.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
              const Text('VYNTRA STUDIO', style: TextStyle(fontSize: 9, letterSpacing: 1.6, color: Colors.white54)),
            ],
          ),
        ),
        actions: [
          IconButton(tooltip: 'Undo', onPressed: _undo.isEmpty || _exporting ? null : _undoEdit, icon: const Icon(Icons.undo_rounded, size: 21)),
          IconButton(tooltip: 'Redo', onPressed: _redo.isEmpty || _exporting ? null : _redoEdit, icon: const Icon(Icons.redo_rounded, size: 21)),
          Padding(
            padding: const EdgeInsets.only(right: 10, left: 2),
            child: FilledButton(
              onPressed: _exporting ? null : _export,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 13), minimumSize: const Size(0, 38), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: const Text('Export', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                child: LayoutBuilder(
                  builder: (context, bounds) {
                    final maxWidth = bounds.maxWidth;
                    final maxHeight = bounds.maxHeight;
                    final safeAspect = previewAspect.clamp(.45, 2.2).toDouble();
                    final width = (maxHeight * safeAspect).clamp(1, maxWidth).toDouble();
                    return Center(
                      child: SizedBox(
                        width: width,
                        height: width / safeAspect,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: ColoredBox(
                            color: const Color(0xFF000000),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (playerReady)
                                  Center(child: RotatedBox(quarterTurns: _previewingExport ? 0 : clip.rotation ~/ 90, child: VideoPlayer(player!)))
                                else
                                  Center(child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.movie_outlined, size: 38, color: accent.withValues(alpha: .7)),
                                      const SizedBox(height: 10),
                                      const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                                      const SizedBox(height: 10),
                                      const Text('Preparing preview', style: TextStyle(fontSize: 11, color: Colors.white54)),
                                    ],
                                  )),
                                for (final overlay in visibleText)
                                  Align(
                                    alignment: Alignment(overlay.x, overlay.y * 2 - 1),
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Text(overlay.text, textAlign: TextAlign.center, style: TextStyle(color: Color(overlay.color), fontWeight: FontWeight.w900, fontSize: overlay.fontSize.clamp(16, 42), shadows: const [Shadow(color: Colors.black87, blurRadius: 8, offset: Offset(1, 2))])),
                                    ),
                                  ),
                                if (!_previewingExport)
                                  for (final overlay in _project.imageOverlays.where((item) => item.startMs <= projectPosition && item.endMs > projectPosition))
                                    Positioned(
                                      left: (bounds.maxWidth * overlay.x).clamp(0, bounds.maxWidth - 32).toDouble(),
                                      top: (bounds.maxHeight * overlay.y).clamp(0, bounds.maxHeight - 32).toDouble(),
                                      width: (bounds.maxWidth * overlay.scale).clamp(32, bounds.maxWidth).toDouble(),
                                      height: (bounds.maxWidth * overlay.scale).clamp(32, bounds.maxWidth).toDouble(),
                                      child: Image.file(File(overlay.path), fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Colors.white70)),
                                    ),
                                if (_previewingExport)
                                  Positioned(left: 10, top: 10, child: DecoratedBox(decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(7)), child: const Padding(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5), child: Text('EXPORT PREVIEW', style: TextStyle(color: Color(0xFF05251D), fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .8))))),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: playerReady && player!.value.isPlaying ? 'Pause' : 'Play',
                    onPressed: !playerReady ? null : () { if (player!.value.isPlaying) { player.pause(); } else { player.play(); } setState(() {}); },
                    icon: Icon(playerReady && player!.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: playerReady
                      ? ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: player!,
                          builder: (_, value, __) => Column(
                            children: [
                              Slider(
                                min: 0,
                                max: (value.duration.inMilliseconds / 1000).clamp(.1, double.infinity).toDouble(),
                                value: (value.position.inMilliseconds / 1000).clamp(0, value.duration.inMilliseconds / 1000).toDouble(),
                                onChanged: (seconds) => player!.seekTo(Duration(milliseconds: (seconds * 1000).round())),
                              ),
                            ],
                          ),
                        )
                      : const LinearProgressIndicator(minHeight: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(playerReady ? _time(player!.value.position.inMilliseconds) : '0:00', style: const TextStyle(fontSize: 11, fontFeatures: [FontFeature.tabularFigures()], color: Colors.white70)),
                  const Text(' / ', style: TextStyle(fontSize: 11, color: Colors.white30)),
                  Text(_time(clip.lengthMs), style: const TextStyle(fontSize: 11, color: Colors.white54)),
                ],
              ),
            ),
            if (_previewingExport && _exportPath != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(children: [
                  Expanded(child: OutlinedButton.icon(onPressed: () => setState(() => _previewingExport = false), icon: const Icon(Icons.edit_rounded), label: const Text('Back to edit'))),
                  const SizedBox(width: 8),
                  Expanded(child: OutlinedButton.icon(onPressed: _saveExport, icon: const Icon(Icons.save_alt_rounded), label: const Text('Save video'))),
                  const SizedBox(width: 8),
                  Expanded(child: FilledButton.icon(onPressed: _shareExport, icon: const Icon(Icons.share_rounded), label: const Text('Share'))),
                ]),
              ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 7),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFF252B31)))),
              child: Row(
                children: [
                  const Icon(Icons.movie_filter_outlined, size: 17, color: Colors.white70),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('TIMELINE', style: TextStyle(fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w900))),
                  Text('${_project.clips.length} clips · ${_time(_project.durationMs)}', style: const TextStyle(fontSize: 10, color: Colors.white54)),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Undo edit',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(width: 30, height: 30),
                    padding: EdgeInsets.zero,
                    onPressed: _undo.isEmpty || _exporting ? null : _undoEdit,
                    icon: const Icon(Icons.undo_rounded, size: 17),
                  ),
                  IconButton(
                    tooltip: 'Redo edit',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(width: 30, height: 30),
                    padding: EdgeInsets.zero,
                    onPressed: _redo.isEmpty || _exporting ? null : _redoEdit,
                    icon: const Icon(Icons.redo_rounded, size: 17),
                  ),
                  const SizedBox(width: 5),
                  const Icon(Icons.zoom_out_rounded, size: 15, color: Colors.white54),
                  SizedBox(width: 74, child: Slider(
                    min: .6, max: 2, divisions: 7, value: _timelineZoom,
                    onChanged: (value) => setState(() => _timelineZoom = value),
                  )),
                  const Icon(Icons.zoom_in_rounded, size: 15, color: Colors.white54),
                  IconButton(tooltip: 'Add clips', onPressed: _exporting ? null : () => _openEditorTool('Media'), icon: Icon(Icons.add_circle_outline_rounded, color: accent)),
                ],
              ),
            ),
            SizedBox(
              height: 116,
              child: ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                itemCount: _project.clips.length,
                onReorderItem: _reorder,
                itemBuilder: (context, index) {
                  final item = _project.clips[index];
                  final selected = index == _selectedIndex;
                  final thumbnail = _thumbnail(item);
                  return Padding(
                    key: ValueKey(item.id),
                    padding: const EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: (item.lengthMs / 1000 * 17 * _timelineZoom).clamp(90, 300).toDouble(),
                      child: Material(
                        color: selected ? accent.withValues(alpha: .13) : const Color(0xFF15191E),
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _loadClipPreview(index),
                          child: Container(
                            decoration: BoxDecoration(border: Border.all(color: selected ? accent : const Color(0xFF292F36), width: selected ? 1.5 : 1)),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      FutureBuilder<Uint8List?>(
                                        future: thumbnail,
                                        builder: (context, snapshot) => snapshot.data == null
                                          ? const ColoredBox(color: Color(0xFF222830), child: Center(child: Icon(Icons.movie_outlined, color: Colors.white54, size: 23)))
                                          : Image.memory(snapshot.data!, fit: BoxFit.cover, gaplessPlayback: true),
                                      ),
                                      if (selected) Positioned(left: 0, right: 0, top: 0, child: Container(height: 3, color: accent)),
                                      Positioned(right: 5, bottom: 5, child: DecoratedBox(decoration: BoxDecoration(color: Colors.black.withValues(alpha: .75), borderRadius: BorderRadius.circular(5)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3), child: Text(_time(item.lengthMs), style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800))))),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(7, 6, 4, 5),
                                  child: Row(children: [
                                    Expanded(child: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9, fontWeight: selected ? FontWeight.w900 : FontWeight.w600))),
                                    ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_indicator_rounded, size: 14, color: Colors.white54)),
                                  ]),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_exporting)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                child: Column(children: [
                  LinearProgressIndicator(value: !_watchingRewardedAd && _progress > 0 ? _progress : null, minHeight: 3),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(child: Text(_watchingRewardedAd ? 'Unlocking export…' : _exportStatus, style: TextStyle(color: accent, fontSize: 11))),
                    if (!_watchingRewardedAd) TextButton(onPressed: () => _processing.cancel(), child: const Text('Cancel')),
                  ]),
                ]),
              ),
            Container(
              height: 82,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 7),
              decoration: const BoxDecoration(color: Color(0xFF101317), border: Border(top: BorderSide(color: Color(0xFF252B31)))),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _editorToolButton(Icons.tune_rounded, 'Clip', accent, () => _openEditorTool('Clip')),
                    _editorToolButton(Icons.crop_rounded, 'Crop', accent, () => _openEditorTool('Crop')),
                    _editorToolButton(Icons.title_rounded, 'Text', accent, () => _openEditorTool('Text')),
                    _editorToolButton(Icons.graphic_eq_rounded, 'Audio', accent, () => _openEditorTool('Audio')),
                    _editorToolButton(Icons.auto_fix_high_rounded, 'Adjust', accent, () => _openEditorTool('Adjust')),
                    _editorToolButton(Icons.layers_outlined, 'Layers', accent, () => _openEditorTool('Layers')),
                    _editorToolButton(Icons.auto_awesome_rounded, 'Auto Edit', accent, _autoEdit),
                    _editorToolButton(Icons.video_library_outlined, 'Media', accent, () => _openEditorTool('Media')),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _editorToolButton(IconData icon, String label, Color accent, VoidCallback onPressed) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: SizedBox(
      width: 65,
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onPressed,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: accent, size: 22),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white70)),
          ],
        ),
      ),
    ),
  );
}
