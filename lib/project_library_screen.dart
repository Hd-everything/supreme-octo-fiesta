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
  String _query = '';

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
    final filtered = _projects.where((project) => project.name.toLowerCase().contains(_query.trim().toLowerCase())).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: accent.withValues(alpha: .25)),
                          ),
                          child: Icon(Icons.movie_edit_outlined, color: accent, size: 24),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('VYNTRA', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 2.4)),
                              SizedBox(height: 3),
                              Text('Video studio', style: TextStyle(color: Colors.white54, fontSize: 12)),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Refresh projects',
                          onPressed: _reload,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    const Text('Make something\nworth watching.', style: TextStyle(fontSize: 31, height: 1.05, fontWeight: FontWeight.w900, letterSpacing: -1.2)),
                    const SizedBox(height: 10),
                    const Text('Your next edit starts with a clip.', style: TextStyle(color: Colors.white60, fontSize: 14)),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: FilledButton.icon(
                        onPressed: _create,
                        icon: const Icon(Icons.add_rounded, size: 22),
                        label: const Text('Create new project', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                        style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Row(
                      children: [
                        const Expanded(child: Text('Your projects', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w850, letterSpacing: -.4))),
                        Text('${_projects.length} total', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      onChanged: (value) => setState(() => _query = value),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search projects',
                        prefixIcon: const Icon(Icons.search_rounded),
                        filled: true,
                        fillColor: const Color(0xFF14181D),
                        contentPadding: const EdgeInsets.symmetric(vertical: 14),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: const BorderSide(color: Color(0xFF252B31))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide(color: accent.withValues(alpha: .7))),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (filtered.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 18, 28, 36),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(color: accent.withValues(alpha: .09), borderRadius: BorderRadius.circular(24)),
                          child: Icon(_query.isEmpty ? Icons.video_library_outlined : Icons.search_off_rounded, size: 34, color: accent),
                        ),
                        const SizedBox(height: 18),
                        Text(_query.isEmpty ? 'Your timeline is waiting' : 'No matching projects', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 7),
                        Text(
                          _query.isEmpty ? 'Import clips to build your first edit. Your projects stay saved on this device.' : 'Try another project name.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white60, height: 1.45),
                        ),
                        if (_query.isEmpty) ...[
                          const SizedBox(height: 18),
                          OutlinedButton.icon(onPressed: _create, icon: const Icon(Icons.video_call_outlined), label: const Text('Choose videos')),
                        ],
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.crossAxisExtent >= 620 ? 3 : constraints.crossAxisExtent >= 400 ? 2 : 1;
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: columns == 1 ? 2.45 : .78,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final project = filtered[index];
                          final available = project.clips.where((clip) => File(clip.path).existsSync()).length;
                          return Material(
                            color: const Color(0xFF12161B),
                            borderRadius: BorderRadius.circular(18),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => _open(project),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    flex: columns == 1 ? 5 : 7,
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        FutureBuilder<Uint8List?>(
                                          future: _thumbnail(project),
                                          builder: (context, snapshot) => snapshot.data == null
                                              ? ColoredBox(
                                                  color: const Color(0xFF20272D),
                                                  child: Center(child: Icon(Icons.movie_creation_outlined, size: 36, color: accent.withValues(alpha: .8))),
                                                )
                                              : Image.memory(snapshot.data!, fit: BoxFit.cover, gaplessPlayback: true),
                                        ),
                                        Positioned(
                                          left: 9,
                                          bottom: 9,
                                          child: DecoratedBox(
                                            decoration: BoxDecoration(color: Colors.black.withValues(alpha: .76), borderRadius: BorderRadius.circular(7)),
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                              child: Text(_duration(project.durationMs), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          right: 5,
                                          top: 5,
                                          child: Material(
                                            color: Colors.black.withValues(alpha: .6),
                                            shape: const CircleBorder(),
                                            child: PopupMenuButton<String>(
                                              tooltip: 'Project options',
                                              icon: const Icon(Icons.more_horiz_rounded, size: 21),
                                              onSelected: (value) {
                                                if (value == 'rename') _rename(project);
                                                if (value == 'duplicate') _duplicate(project);
                                                if (value == 'delete') _delete(project);
                                              },
                                              itemBuilder: (_) => const [
                                                PopupMenuItem(value: 'rename', child: Text('Rename')),
                                                PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                                                PopupMenuItem(value: 'delete', child: Text('Delete')),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                                              const SizedBox(height: 5),
                                              Text(
                                                available == project.clips.length ? '${project.clips.length} clips · Edited ${project.updatedAt.toLocal().month}/${project.updatedAt.toLocal().day}' : '$available of ${project.clips.length} source clips missing',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(fontSize: 11, color: available == project.clips.length ? Colors.white54 : Colors.orangeAccent),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Icon(Icons.arrow_outward_rounded, color: accent, size: 18),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                        childCount: filtered.length,
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
