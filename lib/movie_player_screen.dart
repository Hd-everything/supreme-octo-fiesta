import 'dart:async';
import 'dart:io';
import 'dart:convert';


import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local movie player backed by libmpv through media_kit. This supports a
/// much wider range of containers and codecs than the status-preview player.
class MoviePlayerScreen extends StatefulWidget {
  const MoviePlayerScreen({super.key, this.initialPath, this.initialName});

  final String? initialPath;
  final String? initialName;

  @override
  State<MoviePlayerScreen> createState() => _MoviePlayerScreenState();
}

class _MoviePlayerScreenState extends State<MoviePlayerScreen> {
  late final Player _player;
  late final VideoController _videoController;
  String? _fileName;
  String? _currentPath;
  Timer? _resumeTimer;
  Timer? _sleepTimer;
  Timer? _abRepeatTimer;
  bool _abRepeatSeeking = false;
  Duration? _repeatStart;
  Duration? _repeatEnd;
  String? _sleepTimerLabel;
  String? _playbackMessage;
  bool _controlsLocked = false;
  List<Map<String, String>> _recentMovies = <Map<String, String>>[];
  String _libraryQuery = '';
  String? _error;
  bool _opening = false;
  bool _landscapeSystemUi = false;
  bool _showPictureTuning = false;
  double _brightness = 0;
  double _contrast = 0;
  double _saturation = 0;
  double _speed = 1;
  String? _subtitleMessage;

  static const _videoExtensions = <String>[
    'mp4', 'mkv', 'avi', 'mov', 'webm', 'flv', 'wmv', 'm4v', '3gp',
    'ts', 'mpeg', 'mpg', 'ogv', 'vob', 'asf', 'm2ts', 'mts', 'mxf',
  ];

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    unawaited(_loadRecentMovies());
    if (widget.initialPath != null && widget.initialPath!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_openMovie(widget.initialPath!, widget.initialName ?? File(widget.initialPath!).uri.pathSegments.last));
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wantsImmersive = MediaQuery.orientationOf(context) == Orientation.landscape && _fileName != null;
    if (wantsImmersive == _landscapeSystemUi) return;
    _landscapeSystemUi = wantsImmersive;
    unawaited(SystemChrome.setEnabledSystemUIMode(
      wantsImmersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    ));
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    _resumeTimer?.cancel();
    _sleepTimer?.cancel();
    _abRepeatTimer?.cancel();
    unawaited(_persistPlaybackPosition());
    unawaited(_player.dispose());
    super.dispose();
  }

  String _resumeKey(String path) => 'movie_resume_${Uri.encodeComponent(path)}';

  Future<void> _persistPlaybackPosition() async {
    final path = _currentPath;
    if (path == null) return;
    try {
      final position = _player.state.position;
      final duration = _player.state.duration;
      final preferences = await SharedPreferences.getInstance();
      if (duration > Duration.zero && duration - position <= const Duration(seconds: 3)) {
        await preferences.remove(_resumeKey(path));
      } else if (position >= const Duration(seconds: 10)) {
        await preferences.setInt(_resumeKey(path), position.inMilliseconds);
      }
    } catch (_) {
      // Resume history is optional and must never interrupt playback.
    }
  }

  void _startResumeCheckpoint() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_persistPlaybackPosition()),
    );
  }

  Future<void> _loadRecentMovies() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final entries = preferences.getStringList('recent_movies') ?? <String>[];
      final movies = <Map<String, String>>[];
      for (final entry in entries) {
        try {
          final decoded = jsonDecode(entry) as Map<String, dynamic>;
          final path = decoded['path'] as String?;
          final name = decoded['name'] as String?;
          if (path != null && name != null && path.isNotEmpty && name.isNotEmpty) {
            movies.add({'path': path, 'name': name});
          }
        } catch (_) {
          // Ignore invalid entries and keep the rest of the library.
        }
      }
      if (mounted) setState(() => _recentMovies = movies);
    } catch (_) {
      // Recent history is optional.
    }
  }

  Future<void> _rememberRecentMovie(String path, String name) async {
    final next = <Map<String, String>>[
      {'path': path, 'name': name},
      ..._recentMovies.where((movie) => movie['path'] != path),
    ].take(12).toList();
    if (mounted) setState(() => _recentMovies = next);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList('recent_movies', next.map((movie) => jsonEncode(movie)).toList());
    } catch (_) {
      // Recent history is a convenience, not a playback requirement.
    }
  }

  Future<void> _removeRecentMovie(Map<String, String> movie) async {
    final path = movie['path'];
    if (path == null) return;
    final next = _recentMovies.where((entry) => entry['path'] != path).toList();
    if (mounted) setState(() => _recentMovies = next);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setStringList(
        'recent_movies',
        next.map((entry) => jsonEncode(entry)).toList(),
      );
    } catch (_) {
      // Removing a history entry must not affect active playback.
    }
  }

  Future<void> _clearRecentMovies() async {
    if (_recentMovies.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear recent movies?'),
        content: const Text('This only clears the playback history. Your video files will not be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Clear history')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (mounted) setState(() => _recentMovies = <Map<String, String>>[]);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove('recent_movies');
    } catch (_) {
      // History storage is optional.
    }
  }

  Future<void> _addMoviesToLibrary() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _videoExtensions,
        allowMultiple: true,
        withData: false,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      var added = 0;
      for (final file in result.files) {
        final path = file.path;
        if (path == null || path.isEmpty) continue;
        await _rememberRecentMovie(path, file.name);
        added++;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(added == 1 ? 'Added 1 movie to your library.' : 'Added $added movies to your library.')),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not add these videos to the library: $error');
      }
    }
  }

  Future<void> _chooseMovie() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _videoExtensions,
        allowMultiple: false,
        withData: false,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final file = result.files.single;
      final path = file.path;
      if (path == null || path.isEmpty) {
        setState(() => _error = 'This file provider did not return a readable local path. Try choosing the file from device storage.');
        return;
      }
      await _openMovie(path, file.name);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = 'Could not open this movie. Details: $error';
      });
    }
  }

  Future<void> _openMovie(String path, String name) async {
    try {
      _resumeTimer?.cancel();
      _abRepeatTimer?.cancel();
      _repeatStart = null;
      _repeatEnd = null;
      _abRepeatSeeking = false;
      await _persistPlaybackPosition();
      if (!mounted) return;
      setState(() {
        _opening = true;
        _playbackMessage = null;
        _error = null;
        _fileName = name;
        _currentPath = path;
        _brightness = 0;
        _contrast = 0;
        _saturation = 0;
        _speed = 1;
        _subtitleMessage = null;
      });
      await _player.open(Media(path), play: true);
      await _rememberRecentMovie(path, name);
      try {
        final preferences = await SharedPreferences.getInstance();
        final savedPosition = preferences.getInt(_resumeKey(path));
        if (savedPosition != null && savedPosition >= 10000) {
          final duration = await _player.stream.duration
              .firstWhere((value) => value > Duration.zero)
              .timeout(const Duration(seconds: 8), onTimeout: () => _player.state.duration);
          final resumeAt = Duration(milliseconds: savedPosition);
          if (duration > Duration.zero && duration - resumeAt > const Duration(seconds: 3)) {
            await _player.seek(resumeAt);
          } else {
            await preferences.remove(_resumeKey(path));
          }
        }
        _startResumeCheckpoint();
      } catch (_) {
        // Playback must remain available even if resume storage fails.
      }
      if (!mounted) return;
      setState(() => _opening = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = 'Could not play this file. The format may be damaged or use a codec this device cannot decode. Details: $error';
      });
    }
  }


  Future<void> _openRecentMovie(Map<String, String> movie) async {
    final path = movie['path'];
    final name = movie['name'];
    if (path == null || name == null) return;
    if (!await File(path).exists()) {
      if (mounted) setState(() => _error = 'This file is no longer available at its saved location. Choose it again from storage.');
      return;
    }
    await _openMovie(path, name);
  }

  Future<void> _chooseSubtitle() async {
    if (_fileName == null || _opening) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt'],
        allowMultiple: false,
        withData: false,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final path = result.files.single.path;
      if (path == null || path.isEmpty) {
        setState(() => _error = 'The subtitle file could not be accessed.');
        return;
      }
      await _player.setSubtitleTrack(SubtitleTrack.uri(path));
      if (mounted) {
        setState(() => _subtitleMessage = 'Loaded: ${result.files.single.name}');
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not load this subtitle file: $error');
    }
  }

  Future<void> _showSleepTimerPicker() async {
    final options = <int>[15, 30, 45, 60, 90, 120];
    final selected = await showModalBottomSheet<int?>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Sleep timer', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              const Text('Pause playback automatically after the selected time.', style: TextStyle(color: Colors.white60, fontSize: 12)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final minutes in options)
                    ActionChip(
                      label: Text('$minutes min'),
                      onPressed: () => Navigator.pop(sheetContext, minutes),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.timer_off_outlined, size: 16),
                    label: const Text('Turn off'),
                    onPressed: () => Navigator.pop(sheetContext, 0),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    _sleepTimer?.cancel();
    if (selected == 0) {
      setState(() => _sleepTimerLabel = null);
      return;
    }
    setState(() => _sleepTimerLabel = '$selected min');
    _sleepTimer = Timer(Duration(minutes: selected), () async {
      try {
        await _player.pause();
      } catch (_) {}
      if (mounted) setState(() => _sleepTimerLabel = null);
    });
  }

  void _cycleABRepeat() {
    final position = _player.state.position;
    if (_repeatStart == null) {
      setState(() {
        _repeatStart = position;
        _repeatEnd = null;
        _playbackMessage = 'A–B repeat: start point set at ${_time(position)}. Seek to the end and tap A–B again.';
      });
      return;
    }
    if (_repeatEnd == null) {
      if (position <= _repeatStart! + const Duration(seconds: 1)) {
        setState(() => _playbackMessage = 'Move at least one second past point A before setting point B.');
        return;
      }
      setState(() {
        _repeatEnd = position;
        _playbackMessage = 'Repeating ${_time(_repeatStart!)}–${_time(position)}. Tap A–B again to clear.';
      });
      _abRepeatTimer?.cancel();
      _abRepeatTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
        if (!mounted || _abRepeatSeeking || !_player.state.playing || _repeatStart == null || _repeatEnd == null) return;
        if (_player.state.position >= _repeatEnd!) {
          _abRepeatSeeking = true;
          try {
            await _player.seek(_repeatStart!);
          } finally {
            _abRepeatSeeking = false;
          }
        }
      });
      return;
    }
    _abRepeatTimer?.cancel();
    setState(() {
      _repeatStart = null;
      _repeatEnd = null;
      _playbackMessage = 'A–B repeat cleared.';
    });
  }

  Future<void> _showTrackPicker() async {
    if (_fileName == null || _opening) return;
    final audioTracks = _player.state.tracks.audio.where((track) => track.id != 'auto' && track.id != 'no').toList();
    final subtitleTracks = _player.state.tracks.subtitle.where((track) => track.id != 'auto' && track.id != 'no').toList();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Audio & subtitles'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 4, bottom: 6),
                  child: Text('AUDIO TRACK', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5, color: Colors.white60)),
                ),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: const Text('Automatic'),
                  selected: _player.state.track.audio == AudioTrack.auto(),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    unawaited(_player.setAudioTrack(AudioTrack.auto()));
                  },
                ),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.volume_off_outlined),
                  title: const Text('Mute audio track'),
                  selected: _player.state.track.audio == AudioTrack.no(),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    unawaited(_player.setAudioTrack(AudioTrack.no()));
                  },
                ),
                if (audioTracks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('No separate audio tracks detected.', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                for (var i = 0; i < audioTracks.length; i++)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.audiotrack_rounded),
                    title: Text(audioTracks[i].title?.trim().isNotEmpty == true ? audioTracks[i].title! : (audioTracks[i].language?.trim().isNotEmpty == true ? audioTracks[i].language! : 'Audio track ${i + 1}')),
                    subtitle: audioTracks[i].codec == null ? null : Text(audioTracks[i].codec!, style: const TextStyle(fontSize: 11)),
                    selected: _player.state.track.audio == audioTracks[i],
                    onTap: () {
                      final track = audioTracks[i];
                      Navigator.pop(dialogContext);
                      unawaited(_player.setAudioTrack(track));
                    },
                  ),
                const Divider(height: 24),
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text('SUBTITLES', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5, color: Colors.white60)),
                ),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.auto_awesome_outlined),
                  title: const Text('Automatic'),
                  selected: _player.state.track.subtitle == SubtitleTrack.auto(),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    unawaited(_player.setSubtitleTrack(SubtitleTrack.auto()));
                  },
                ),
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.subtitles_off_outlined),
                  title: const Text('Subtitles off'),
                  selected: _player.state.track.subtitle == SubtitleTrack.no(),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    unawaited(_player.setSubtitleTrack(SubtitleTrack.no()));
                  },
                ),
                if (subtitleTracks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('No embedded subtitles detected. You can load an external subtitle file below.', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                for (var i = 0; i < subtitleTracks.length; i++)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.subtitles_rounded),
                    title: Text(subtitleTracks[i].title?.trim().isNotEmpty == true ? subtitleTracks[i].title! : (subtitleTracks[i].language?.trim().isNotEmpty == true ? subtitleTracks[i].language! : 'Subtitle track ${i + 1}')),
                    subtitle: subtitleTracks[i].codec == null ? null : Text(subtitleTracks[i].codec!, style: const TextStyle(fontSize: 11)),
                    selected: _player.state.track.subtitle == subtitleTracks[i],
                    onTap: () {
                      final track = subtitleTracks[i];
                      Navigator.pop(dialogContext);
                      unawaited(_player.setSubtitleTrack(track));
                    },
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _chooseExternalAudio() async {
    if (_fileName == null || _opening) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['aac', 'm4a', 'mp3', 'ogg', 'opus', 'flac', 'wav', 'ac3', 'dts'],
        allowMultiple: false,
        withData: false,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final path = result.files.single.path;
      if (path == null || path.isEmpty) {
        setState(() => _error = 'The audio file could not be accessed.');
        return;
      }
      await _player.setAudioTrack(AudioTrack.uri(path, title: result.files.single.name));
      if (mounted) {
        setState(() => _subtitleMessage = 'Loaded external audio: ${result.files.single.name}');
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not load this audio track: $error');
    }
  }

  List<double> _pictureMatrix(double brightness, double contrast, double saturation) {
    final b = brightness / 255;
    final c = 1 + contrast / 100;
    final s = 1 + saturation / 100;
    const r = 0.213, g = 0.715, bl = 0.072;
    final sr = (1 - s) * r, sg = (1 - s) * g, sb = (1 - s) * bl;
    return <double>[
      (sr + s) * c, sg * c, sb * c, 0, (b + 0.5 - 0.5 * c) * 255,
      sr * c, (sg + s) * c, sb * c, 0, (b + 0.5 - 0.5 * c) * 255,
      sr * c, sg * c, (sb + s) * c, 0, (b + 0.5 - 0.5 * c) * 255,
      0, 0, 0, 1, 0,
    ];
  }

  String _time(Duration value) {
    final seconds = value.inSeconds;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainder = seconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
  }

  Future<void> _seekBy(Duration delta) async {
    final current = _player.state.position;
    final duration = _player.state.duration;
    final target = current + delta;
    final bounded = target < Duration.zero
        ? Duration.zero
        : (target > duration ? duration : target);
    await _player.seek(bounded);
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final visibleRecentMovies = _recentMovies.where((movie) => (movie['name'] ?? '').toLowerCase().contains(_libraryQuery.trim().toLowerCase())).toList();
    final landscapePlayback = MediaQuery.orientationOf(context) == Orientation.landscape && _fileName != null;
    return Scaffold(
      appBar: landscapePlayback ? null : AppBar(
        title: const Text('Movie player'),
        actions: [
          IconButton(
            tooltip: 'Open movie',
            onPressed: _opening ? null : _chooseMovie,
            icon: const Icon(Icons.folder_open_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: OrientationBuilder(
          builder: (context, orientation) {
            if (orientation == Orientation.landscape && _fileName != null) {
              return ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: ColorFiltered(
                        colorFilter: ColorFilter.matrix(_pictureMatrix(_brightness, _contrast, _saturation)),
                        child: Video(controller: _videoController, fit: BoxFit.contain),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      left: 12,
                      right: 12,
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Back to library',
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                          ),
                          Expanded(
                            child: Text(
                              _fileName!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Playback options',
                            onPressed: _showTrackPicker,
                            icon: const Icon(Icons.subtitles_rounded, color: Colors.white),
                          ),
                          IconButton(
                            tooltip: 'Picture tuning',
                            onPressed: () => setState(() => _showPictureTuning = !_showPictureTuning),
                            icon: const Icon(Icons.tune_rounded, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .72),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.white.withValues(alpha: .10)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              StreamBuilder<Duration>(
                                stream: _player.stream.position,
                                initialData: _player.state.position,
                                builder: (context, positionSnapshot) {
                                  final position = positionSnapshot.data ?? Duration.zero;
                                  return StreamBuilder<Duration>(
                                    stream: _player.stream.duration,
                                    initialData: _player.state.duration,
                                    builder: (context, durationSnapshot) {
                                      final duration = durationSnapshot.data ?? Duration.zero;
                                      final maxMs = duration.inMilliseconds;
                                      final currentMs = position.inMilliseconds.clamp(0, maxMs > 0 ? maxMs : 0);
                                      return Row(
                                        children: [
                                          Text(_time(position), style: const TextStyle(color: Colors.white70, fontSize: 11)),
                                          Expanded(
                                            child: Slider(
                                              value: maxMs > 0 ? currentMs.toDouble() : 0,
                                              max: maxMs > 0 ? maxMs.toDouble() : 1,
                                              onChanged: maxMs <= 0 || _controlsLocked ? null : (value) => unawaited(_player.seek(Duration(milliseconds: value.round()))),
                                            ),
                                          ),
                                          Text(_time(duration), style: const TextStyle(color: Colors.white70, fontSize: 11)),
                                        ],
                                      );
                                    },
                                  );
                                },
                              ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconButton(
                                    tooltip: 'Back 10 seconds',
                                    onPressed: () => unawaited(_seekBy(const Duration(seconds: -10))),
                                    icon: const Icon(Icons.replay_10_rounded, color: Colors.white, size: 30),
                                  ),
                                  StreamBuilder<bool>(
                                    stream: _player.stream.playing,
                                    initialData: _player.state.playing,
                                    builder: (context, snapshot) => IconButton.filled(
                                      tooltip: snapshot.data == true ? 'Pause' : 'Play',
                                      onPressed: () => unawaited(snapshot.data == true ? _player.pause() : _player.play()),
                                      icon: Icon(snapshot.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Forward 10 seconds',
                                    onPressed: () => unawaited(_seekBy(const Duration(seconds: 10))),
                                    icon: const Icon(Icons.forward_10_rounded, color: Colors.white, size: 30),
                                  ),
                                  const SizedBox(width: 12),
                                  Text('×${_speed.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_showPictureTuning)
                      Positioned(
                        right: 16,
                        top: 64,
                        child: SizedBox(
                          width: 240,
                          child: Card(
                            color: const Color(0xFF171B19),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('Picture tuning', style: TextStyle(fontWeight: FontWeight.w800)),
                                  for (final setting in ['Brightness', 'Contrast', 'Saturation'])
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(setting, style: const TextStyle(fontSize: 11, color: Colors.white70)),
                                        Slider(
                                          min: -50,
                                          max: 50,
                                          value: setting == 'Brightness' ? _brightness : setting == 'Contrast' ? _contrast : _saturation,
                                          onChanged: (value) => setState(() {
                                            if (setting == 'Brightness') _brightness = value;
                                            if (setting == 'Contrast') _contrast = value;
                                            if (setting == 'Saturation') _saturation = value;
                                          }),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            }
            return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  color: Colors.black,
                  child: _fileName == null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.movie_outlined, size: 54, color: accent),
                              const SizedBox(height: 12),
                              const Text('Choose a movie to start'),
                              const SizedBox(height: 8),
                              const Text(
                                'MP4 · MKV · AVI · MOV · WebM and more',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white54, fontSize: 11),
                              ),
                            ],
                          ),
                        )
                      : ColorFiltered(
                          colorFilter: ColorFilter.matrix(_pictureMatrix(_brightness, _contrast, _saturation)),
                          child: Video(controller: _videoController),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _fileName ?? 'No movie selected',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
                if (_opening)
                  const Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            StreamBuilder<Duration>(
              stream: _player.stream.position,
              initialData: _player.state.position,
              builder: (context, positionSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                return StreamBuilder<Duration>(
                  stream: _player.stream.duration,
                  initialData: _player.state.duration,
                  builder: (context, durationSnapshot) {
                    final duration = durationSnapshot.data ?? Duration.zero;
                    final maxMs = duration.inMilliseconds;
                    final positionMs = position.inMilliseconds.clamp(0, maxMs > 0 ? maxMs : 0);
                    return Column(
                      children: [
                        Slider(
                          value: maxMs > 0 ? positionMs.toDouble() : 0,
                          max: maxMs > 0 ? maxMs.toDouble() : 1,
                          activeColor: accent,
                          onChanged: maxMs <= 0 || _controlsLocked ? null : (value) => _player.seek(Duration(milliseconds: value.round())),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_time(position), style: const TextStyle(color: Colors.white60, fontSize: 11)),
                              Text(_time(duration), style: const TextStyle(color: Colors.white60, fontSize: 11)),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
            if (_playbackMessage != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_playbackMessage!, style: TextStyle(color: accent, fontSize: 11, height: 1.4)),
              ),
              const SizedBox(height: 6),
            ],
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.filledTonal(
                  tooltip: 'Back 10 seconds',
                  onPressed: _fileName == null || _controlsLocked ? null : () => _seekBy(const Duration(seconds: -10)),
                  icon: const Icon(Icons.replay_10_rounded),
                ),
                const SizedBox(width: 18),
                StreamBuilder<bool>(
                  stream: _player.stream.playing,
                  initialData: _player.state.playing,
                  builder: (context, snapshot) => IconButton.filled(
                    tooltip: snapshot.data == true ? 'Pause' : 'Play',
                    onPressed: _controlsLocked ? null : _fileName == null ? _chooseMovie : () => _player.playOrPause(),
                    iconSize: 30,
                    icon: Icon(snapshot.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  ),
                ),
                const SizedBox(width: 18),
                IconButton.filledTonal(
                  tooltip: 'Forward 10 seconds',
                  onPressed: _fileName == null || _controlsLocked ? null : () => _seekBy(const Duration(seconds: 10)),
                  icon: const Icon(Icons.forward_10_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _fileName == null || _opening ? null : _showTrackPicker,
                icon: const Icon(Icons.audio_file_outlined),
                label: const Text('Audio & subtitle tracks'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _fileName == null || _opening ? null : _chooseSubtitle,
                icon: const Icon(Icons.subtitles_outlined),
                label: const Text('Load subtitle file'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _fileName == null || _opening ? null : _chooseExternalAudio,
                icon: const Icon(Icons.audiotrack_rounded),
                label: const Text('Load external audio track'),
              ),
            ),
            if (_subtitleMessage != null) ...[
              const SizedBox(height: 5),
              Text(_subtitleMessage!, style: const TextStyle(color: Colors.white60, fontSize: 11)),
            ],
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.tune_rounded, color: accent),
                        const SizedBox(width: 10),
                        const Expanded(child: Text('Playback & picture', style: TextStyle(fontWeight: FontWeight.w800))),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Expanded(child: Text('Playback speed')),
                        DropdownButton<double>(
                          value: _speed,
                          items: const [
                            DropdownMenuItem(value: 0.5, child: Text('0.5×')),
                            DropdownMenuItem(value: 0.75, child: Text('0.75×')),
                            DropdownMenuItem(value: 1, child: Text('1.0×')),
                            DropdownMenuItem(value: 1.25, child: Text('1.25×')),
                            DropdownMenuItem(value: 1.5, child: Text('1.5×')),
                            DropdownMenuItem(value: 2, child: Text('2.0×')),
                          ],
                          onChanged: _controlsLocked ? null : (value) {
                            if (value == null) return;
                            setState(() => _speed = value);
                            unawaited(_player.setRate(value));
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _showSleepTimerPicker,
                          icon: const Icon(Icons.bedtime_outlined),
                          label: Text(_sleepTimerLabel == null ? 'Sleep timer' : 'Sleep · $_sleepTimerLabel'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _fileName == null || _controlsLocked ? null : _cycleABRepeat,
                          icon: Icon(_repeatEnd != null ? Icons.repeat_one_rounded : Icons.repeat_rounded),
                          label: Text(_repeatStart == null ? 'A–B repeat' : _repeatEnd == null ? 'Set point B' : 'Clear A–B'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => setState(() => _controlsLocked = !_controlsLocked),
                          icon: Icon(_controlsLocked ? Icons.lock_open_rounded : Icons.lock_outline_rounded),
                          label: Text(_controlsLocked ? 'Unlock playback' : 'Lock playback'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Picture enhancement'),
                      subtitle: const Text('Adjust brightness, contrast and colour while watching.'),
                      value: _showPictureTuning,
                      onChanged: (value) => setState(() => _showPictureTuning = value),
                    ),
                    if (_showPictureTuning) ...[
                      _pictureSlider(
                        label: 'Brightness',
                        value: _brightness,
                        accent: accent,
                        onChanged: (value) {
                          setState(() => _brightness = value);
                        },
                      ),
                      _pictureSlider(
                        label: 'Contrast',
                        value: _contrast,
                        accent: accent,
                        onChanged: (value) {
                          setState(() => _contrast = value);
                        },
                      ),
                      _pictureSlider(
                        label: 'Saturation',
                        value: _saturation,
                        accent: accent,
                        onChanged: (value) {
                          setState(() => _saturation = value);
                        },
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () {
                            setState(() {
                              _brightness = 0;
                              _contrast = 0;
                              _saturation = 0;
                            });
                          },
                          child: const Text('Reset picture'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Playback uses a bundled libmpv-based engine with broad container and codec support. Smoothness depends on your device, codec and video resolution. Picture adjustments change appearance; they do not recreate detail missing from a low-quality source.',
              style: TextStyle(color: Colors.white54, fontSize: 11, height: 1.5),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer, fontSize: 12)),
              ),
            ],
            if (_recentMovies.isNotEmpty) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  const Expanded(child: Text('Recently played', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
                  Text('${_recentMovies.length} saved', style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: _clearRecentMovies,
                    child: const Text('Clear'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                onChanged: (value) => setState(() => _libraryQuery = value),
                decoration: InputDecoration(
                  hintText: 'Search your movies',
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    if (visibleRecentMovies.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(18),
                        child: Text('No movies match that search.', style: TextStyle(color: Colors.white60)),
                      ),
                    for (var index = 0; index < visibleRecentMovies.length; index++) ...[
                      if (index > 0) const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: Icon(Icons.movie_outlined, color: accent),
                        title: Text(visibleRecentMovies[index]['name'] ?? 'Video', maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: const Text('Local file · resume playback'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.play_arrow_rounded),
                            PopupMenuButton<String>(
                              tooltip: 'Movie history options',
                              onSelected: (value) {
                                if (value == 'remove') unawaited(_removeRecentMovie(visibleRecentMovies[index]));
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(value: 'remove', child: Text('Remove from history')),
                              ],
                            ),
                          ],
                        ),
                        onTap: _opening ? null : () => _openRecentMovie(visibleRecentMovies[index]),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _opening ? null : _chooseMovie,
                    icon: const Icon(Icons.folder_open_rounded),
                    label: Text(_fileName == null ? 'Choose movie' : 'Open another'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _opening ? null : _addMoviesToLibrary,
                    icon: const Icon(Icons.video_library_outlined),
                    label: const Text('Add to library'),
                  ),
                ),
              ],
            ),
          ],
            );
          },
        ),
      ),
    );
  }

  Widget _pictureSlider({
    required String label,
    required double value,
    required Color accent,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(value.round().toString(), style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
          ],
        ),
        Slider(
          value: value,
          min: -100,
          max: 100,
          divisions: 40,
          activeColor: accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
