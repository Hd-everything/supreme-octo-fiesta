import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_manager_screen.dart';
import 'models/edit_project.dart';
import 'project_editor_screen.dart';
import 'services/edit_project_store.dart';

class ProjectLibraryScreen extends StatefulWidget {
  const ProjectLibraryScreen({super.key, required this.preferences});
  final SharedPreferences preferences;

  @override
  State<ProjectLibraryScreen> createState() => _ProjectLibraryScreenState();
}

class _ProjectLibraryScreenState extends State<ProjectLibraryScreen> {
  static const _channel = MethodChannel('com.ptip.statushd/media');
  late final EditProjectStore _store = EditProjectStore(widget.preferences);
  late List<EditProject> _projects = _store.load();
  final Map<String, Future<Uint8List?>> _thumbnails = {};

  Future<Uint8List?> _thumbnail(EditProject project) => _thumbnails.putIfAbsent(project.id, () async {
        try { return await _channel.invokeMethod<Uint8List>('videoThumbnail', {'path': project.clips.first.path, 'timeMs': 500}); } catch (_) { return null; }
      });

  Future<void> _reload() async {
    if (mounted) setState(() => _projects = _store.load());
  }

  Future<void> _create() async {
    final selected = await Navigator.of(context).push<List<DeviceMedia>>(
      MaterialPageRoute(builder: (_) => const MediaManagerScreen(videosOnly: true, multiSelect: true)),
    );
    if (selected == null || selected.isEmpty || !mounted) return;
    if (selected.any((media) => media.duration <= 0 || !File(media.path).existsSync())) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('At least one selected video is unavailable or has no readable duration. Choose the videos again.')));
      return;
    }
    final now = DateTime.now();
    final id = now.microsecondsSinceEpoch.toString();
    final project = EditProject(
      id: id,
      name: selected.length == 1 ? selected.first.name.replaceAll(RegExp(r'\.[^.]+$'), '') : 'Untitled project',
      createdAt: now,
      updatedAt: now,
      clips: selected.map((media) => EditClip(id: '${id}_${selected.indexOf(media)}', path: media.path, name: media.name, durationMs: media.duration)).toList(),
    );
    await _store.save(project);
    await _open(project);
  }

  Future<void> _open(EditProject project) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ProjectEditorScreen(project: project, store: _store)));
    await _reload();
  }

  Future<void> _rename(EditProject project) async {
    final controller = TextEditingController(text: project.name);
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Rename project'),
      content: TextField(controller: controller, autofocus: true, maxLength: 48, decoration: const InputDecoration(labelText: 'Project name')),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save'))],
    ));
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await _store.save(project.copyWith(name: name));
    await _reload();
  }

  Future<void> _duplicate(EditProject project) async {
    final now = DateTime.now();
    final id = now.microsecondsSinceEpoch.toString();
    await _store.save(EditProject(id: id, name: '${project.name} copy', createdAt: now, updatedAt: now, clips: project.clips.asMap().entries.map((entry) => entry.value.copyWith(id: '${id}_${entry.key}')).toList()));
    await _reload();
  }

  Future<void> _delete(EditProject project) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Delete project?'),
      content: Text('“${project.name}” will be removed from Vyntra. Source videos will stay on your device.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep project')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete'))],
    ));
    if (confirmed == true) { await _store.delete(project.id); await _reload(); }
  }

  String _duration(int ms) => '${ms ~/ 60000}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      body: SafeArea(child: CustomScrollView(slivers: [
        SliverPadding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 16), sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Projects', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: -1)),
          const SizedBox(height: 5),
          const Text('Your edits are saved on this device.', style: TextStyle(color: Colors.white60)),
          const SizedBox(height: 18),
          SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _create, icon: const Icon(Icons.add_rounded), label: const Text('New project'))),
        ]))),
        if (_projects.isEmpty)
          SliverFillRemaining(hasScrollBody: false, child: Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.movie_creation_outlined, size: 56, color: accent.withValues(alpha: .7)),
            const SizedBox(height: 14),
            const Text('No projects yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            const Text('Choose one or more videos to start building an edit.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
          ]))))
        else
          SliverPadding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 28), sliver: SliverList(delegate: SliverChildBuilderDelegate((context, index) {
            final project = _projects[index];
            final available = project.clips.where((clip) => File(clip.path).existsSync()).length;
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(onTap: () => _open(project), child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
                ClipRRect(borderRadius: BorderRadius.circular(14), child: SizedBox(width: 78, height: 78, child: FutureBuilder<Uint8List?>(future: _thumbnail(project), builder: (context, snapshot) => snapshot.data == null
                    ? ColoredBox(color: accent.withValues(alpha: .12), child: Center(child: Icon(Icons.movie_creation_outlined, size: 30, color: accent)))
                    : Image.memory(snapshot.data!, fit: BoxFit.cover, gaplessPlayback: true)))),
                const SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  const SizedBox(height: 5),
                  Text('${project.clips.length} clips · ${_duration(project.durationMs)}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
                  const SizedBox(height: 3),
                  Text(available == project.clips.length ? 'Edited ${project.updatedAt.toLocal().toString().substring(0, 16)}' : '$available of ${project.clips.length} source videos available', style: TextStyle(color: available == project.clips.length ? Colors.white38 : Colors.orangeAccent, fontSize: 10)),
                ])),
                PopupMenuButton<String>(onSelected: (value) { if (value == 'rename') _rename(project); if (value == 'duplicate') _duplicate(project); if (value == 'delete') _delete(project); }, itemBuilder: (_) => const [PopupMenuItem(value: 'rename', child: Text('Rename')), PopupMenuItem(value: 'duplicate', child: Text('Duplicate')), PopupMenuItem(value: 'delete', child: Text('Delete'))]),
              ]))),
            );
          }, childCount: _projects.length))),
      ])),
    );
  }
}
