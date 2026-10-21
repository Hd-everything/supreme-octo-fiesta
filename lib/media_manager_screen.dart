import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DeviceMedia {
  const DeviceMedia({
    required this.path,
    required this.name,
    required this.type,
    required this.size,
    required this.duration,
  });

  final String path;
  final String name;
  final String type;
  final int size;
  final int duration;

  bool get isVideo => type == 'video';
}

/// A private in-app MediaStore browser. It deliberately does not delegate
/// selection to the system document picker.
class MediaManagerScreen extends StatefulWidget {
  const MediaManagerScreen({super.key, this.videosOnly = false, this.multiSelectPhotos = false, this.multiSelect = false});

  final bool videosOnly;
  final bool multiSelectPhotos;
  final bool multiSelect;

  @override
  State<MediaManagerScreen> createState() => _MediaManagerScreenState();
}

class _MediaManagerScreenState extends State<MediaManagerScreen> {
  static const _channel = MethodChannel('com.ptip.statushd/media');
  final _search = TextEditingController();
  List<DeviceMedia> _items = const [];
  bool _loading = true;
  String? _error;
  String _filter = 'All';
  String _sort = 'Recent';
  final Set<String> _selectedPaths = <String>{};
  final Map<String, Future<Uint8List?>> _thumbnails = <String, Future<Uint8List?>>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listDeviceMedia');
      final next = <DeviceMedia>[];
      for (final value in raw ?? const []) {
        if (value is! Map) continue;
        final path = value['path']?.toString() ?? '';
        final name = value['name']?.toString() ?? '';
        final type = value['type']?.toString() ?? '';
        if (path.isEmpty || name.isEmpty || (type != 'video' && type != 'image')) continue;
        next.add(DeviceMedia(
          path: path,
          name: name,
          type: type,
          size: (value['size'] as num?)?.toInt() ?? 0,
          duration: (value['duration'] as num?)?.toInt() ?? 0,
        ));
      }
      if (mounted) setState(() => _items = next);
    } catch (_) {
      if (mounted) setState(() => _error = 'We could not read your media library. Allow Photos and videos access, then try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<DeviceMedia> get _visible {
    final query = _search.text.trim().toLowerCase();
    final items = _items.where((item) {
      if (widget.videosOnly && !item.isVideo) return false;
      if (widget.multiSelectPhotos && item.isVideo) return false;
      if (_filter == 'Videos' && !item.isVideo) return false;
      if (_filter == 'Photos' && item.isVideo) return false;
      return query.isEmpty || item.name.toLowerCase().contains(query);
    }).toList();
    if (_sort != 'Recent') items.sort((a, b) => switch (_sort) {
      'Name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      'Largest' => b.size.compareTo(a.size),
      'Longest' => b.duration.compareTo(a.duration),
      _ => 0,
    });
    return items;
  }

  String _time(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<Uint8List?> _thumbnail(String path) {
    if (!_thumbnails.containsKey(path) && _thumbnails.length >= 64) return Future.value(null);
    return _thumbnails.putIfAbsent(path, () async {
      try { return await const MethodChannel('com.ptip.statushd/media').invokeMethod<Uint8List>('videoThumbnail', {'path': path}); } catch (_) { return null; }
    });
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Your media', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          Text(widget.videosOnly ? 'Videos on this device' : 'Photos and videos on this device', style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ]),
        actions: [IconButton(tooltip: 'Refresh library', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded))],
      ),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search your library',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
              ),
            ),
          ),
          if (!widget.videosOnly && !widget.multiSelectPhotos && !widget.multiSelect)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Row(children: ['All', 'Videos', 'Photos'].map((label) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(label: Text(label), selected: _filter == label, onSelected: (_) => setState(() => _filter = label)),
              )).toList()),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Row(children: [
              const Icon(Icons.sort_rounded, size: 18, color: Colors.white54),
              const SizedBox(width: 8),
              const Text('Sort', style: TextStyle(color: Colors.white60, fontSize: 12)),
              const SizedBox(width: 8),
              DropdownButtonHideUnderline(child: DropdownButton<String>(
                value: _sort,
                isDense: true,
                items: const [DropdownMenuItem(value: 'Recent', child: Text('Recently added')), DropdownMenuItem(value: 'Name', child: Text('Name')), DropdownMenuItem(value: 'Largest', child: Text('Largest file')), DropdownMenuItem(value: 'Longest', child: Text('Longest video'))],
                onChanged: (value) => setState(() => _sort = value ?? 'Recent'),
              )),
              const Spacer(),
              Text('${visible.length} items', style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ]),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _message(Icons.perm_media_rounded, _error!, 'Try again')
                    : visible.isEmpty
                        ? _message(Icons.photo_library_outlined, 'No media found', 'Refresh library')
                        : GridView.builder(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: .82),
                            itemCount: visible.length,
                            itemBuilder: (context, index) => _tile(visible[index], accent),
                          ),
          ),
          if (widget.multiSelectPhotos || widget.multiSelect)
            SafeArea(top: false, child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: SizedBox(width: double.infinity, child: FilledButton.icon(
                onPressed: _selectedPaths.isEmpty ? null : () => Navigator.pop(context, _items.where((item) => _selectedPaths.contains(item.path)).toList()),
                icon: const Icon(Icons.check_rounded),
                label: Text('Continue with ${_selectedPaths.length} selected'),
              )),
            )),
        ]),
      ),
    );
  }

  Widget _message(IconData icon, String title, String action) => Center(child: Padding(
    padding: const EdgeInsets.all(32),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 48, color: Colors.white38),
      const SizedBox(height: 14),
      Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white70)),
      const SizedBox(height: 12),
      OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(action)),
    ]),
  ));

  Widget _tile(DeviceMedia item, Color accent) => Material(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () {
        if (widget.multiSelectPhotos || widget.multiSelect) {
          if (!_selectedPaths.contains(item.path) && _selectedPaths.length >= 12) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select up to 12 media files at a time.')));
            return;
          }
          setState(() { _selectedPaths.contains(item.path) ? _selectedPaths.remove(item.path) : _selectedPaths.add(item.path); });
        } else {
          Navigator.pop(context, item);
        }
      },
      child: Semantics(
        label: '${item.name}, ${item.isVideo ? 'video' : 'photo'}${item.isVideo ? ', ${_time(item.duration)}' : ''}, ${_size(item.size)}',
        button: true,
        selected: (widget.multiSelectPhotos || widget.multiSelect) && _selectedPaths.contains(item.path),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Stack(fit: StackFit.expand, children: [
          if (!item.isVideo)
            Image.file(File(item.path), fit: BoxFit.cover, errorBuilder: (_, __, ___) => _videoArt(accent))
          else
            FutureBuilder<Uint8List?>(future: _thumbnail(item.path), builder: (context, snapshot) => snapshot.data == null ? _videoArt(accent) : Image.memory(snapshot.data!, fit: BoxFit.cover, gaplessPlayback: true)),
          Positioned(top: 8, right: 8, child: (widget.multiSelectPhotos || widget.multiSelect) ? Checkbox(value: _selectedPaths.contains(item.path), onChanged: (_) => setState(() { _selectedPaths.contains(item.path) ? _selectedPaths.remove(item.path) : _selectedPaths.add(item.path); })) : Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4), decoration: BoxDecoration(color: Colors.black.withValues(alpha: .62), borderRadius: BorderRadius.circular(99)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(item.isVideo ? Icons.play_arrow_rounded : Icons.image_outlined, size: 12, color: accent), if (item.isVideo) Text(_time(item.duration), style: const TextStyle(fontSize: 10))]))),
        ])),
        Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text('${_size(item.size)}${item.isVideo ? ' · ${_time(item.duration)}' : ''}', style: const TextStyle(color: Colors.white54, fontSize: 10)),
        ])),
      ])),
    ),
  );

  String _size(int bytes) => bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(0)} KB' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  Widget _videoArt(Color accent) => Container(
    decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [accent.withValues(alpha: .50), const Color(0xFF242734), const Color(0xFF0B0D12)])),
    child: Center(child: Icon(Icons.movie_rounded, color: Colors.white.withValues(alpha: .82), size: 38)),
  );
}
