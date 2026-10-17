import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'media_manager_screen.dart';
import 'services/media_processing/video_processing_service.dart';
import 'services/media_processing/processing_job_queue.dart';
import 'widgets/ad_banner.dart';

/// A focused, cinema-style local movie player using libmpv/media_kit.
/// Video enhancement uses the app's native Media3 encoder for conventional
/// frame filters. Neural super-resolution is a separate, capability-gated
/// model path and is never implied by a larger output size.
class MoviePlayerScreen extends StatefulWidget {
  const MoviePlayerScreen({super.key, this.initialPath, this.initialName});
  final String? initialPath;
  final String? initialName;

  @override
  State<MoviePlayerScreen> createState() => _MoviePlayerScreenState();
}

class _MoviePlayerScreenState extends State<MoviePlayerScreen> {
  static const _channel = MethodChannel('com.ptip.statushd/media');
  final ProcessingJobQueue _jobs = ProcessingJobQueue();
  late final VideoProcessingService _processing = VideoProcessingService(jobs: _jobs);
  static const _extensions = <String>['mp4','mkv','avi','mov','webm','flv','wmv','m4v','3gp','ts','mpeg','mpg','ogv','vob','asf','m2ts','mts','mxf'];
  late final Player _player;
  late final VideoController _video;
  final TextEditingController _search = TextEditingController();
  List<Map<String,String>> _videos = [];
  List<Map<String,String>> _recent = [];
  Set<String> _favorites = <String>{};
  String? _path;
  String? _name;
  String? _error;
  String? _status;
  int _width = 0, _height = 0, _target = 1080;
  bool _scanning = false, _opening = false, _enhancing = false, _showControls = true, _showPlayerView = false, _locked = false;
  double _speed = 1;
  double _zoom = 1;
  String _sortBy = 'Recent';
  String _libraryTab = 'All';
  bool _gridView = false;
  Timer? _hideTimer;
  Timer? _resumeTimer;
  Timer? _sleepTimer;

  Color get _accent => Theme.of(context).colorScheme.primary;
  bool get _watching => _showPlayerView && _path != null && _name != null;
  bool get _hasMedia => _path != null && _name != null;

  @override
  void initState() {
    super.initState();
    unawaited(_jobs.load());
    _player = Player();
    _video = VideoController(_player);
    _resumeTimer = Timer.periodic(const Duration(seconds: 5), (_) => _persistResume());
    _loadRecent();
    _loadFavorites();
    _scan();
    if (widget.initialPath != null && widget.initialPath!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(widget.initialPath!, widget.initialName ?? File(widget.initialPath!).uri.pathSegments.last));
    }
  }

  @override
  void dispose() {
    _jobs.dispose();
    _hideTimer?.cancel();
    _resumeTimer?.cancel();
    _sleepTimer?.cancel();
    _search.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  String _resumeKey(String path) => 'movie_resume_${Uri.encodeComponent(path)}';

  Future<void> _loadRecent() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final items = <Map<String,String>>[];
      for (final raw in prefs.getStringList('movie_recent_v2') ?? const <String>[]) {
        final split = Uri.decodeComponent(raw).split('|');
        if (split.length >= 2 && split.first.isNotEmpty && split.sublist(1).join('|').isNotEmpty) {
          items.add({'path': split.first, 'name': split[1], if (split.length > 2) 'resume': split[2]});
        }
      }
      if (mounted) setState(() => _recent = items);
    } catch (_) {}
  }

  Future<void> _saveRecent(String path, String name) async {
    final next = <Map<String,String>>[
      {'path': path, 'name': name, 'resume': _player.state.position.inMilliseconds.toString()},
      ..._recent.where((v) => v['path'] != path),
    ].take(10).toList();
    if (mounted) setState(() => _recent = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('movie_recent_v2', next.map((v) => Uri.encodeComponent('${v['path']}|${v['name']}|${v['resume'] ?? 0}')).toList());
    } catch (_) {}
  }

  Future<void> _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _favorites = (prefs.getStringList('movie_favorites_v1') ?? const <String>[]).toSet());
  }

  Future<void> _toggleFavorite(String path) async {
    final next = {..._favorites};
    if (!next.add(path)) next.remove(path);
    if (mounted) setState(() => _favorites = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('movie_favorites_v1', next.toList());
  }

  Future<void> _persistResume() async {
    final path = _path;
    if (path == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_resumeKey(path), _player.state.position.inMilliseconds);
      final index = _recent.indexWhere((item) => item['path'] == path);
      if (index >= 0) {
        final next = [..._recent];
        next[index] = {...next[index], 'resume': _player.state.position.inMilliseconds.toString()};
        if (mounted) setState(() => _recent = next);
      }
    } catch (_) {}
  }

  Future<void> _scan() async {
    if (!Platform.isAndroid || _scanning) return;
    setState(() => _scanning = true);
    try {
      final items = await _channel.invokeMethod<List<dynamic>>('listDeviceVideos');
      final next = <Map<String,String>>[];
      for (final item in items ?? const []) {
        if (item is Map) {
          final path = item['path']?.toString() ?? '';
          final name = item['name']?.toString() ?? '';
          if (path.isNotEmpty && name.isNotEmpty) next.add({'path':path,'name':name});
        }
      }
      if (mounted) setState(() { _videos = next; _error = null; });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not scan device videos. Refresh after allowing media access.');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _browse() async {
    try {
      final selected = await Navigator.of(context).push<DeviceMedia>(
        MaterialPageRoute(builder: (_) => const MediaManagerScreen(videosOnly: true)),
      );
      if (selected == null || !mounted) return;
      await _open(selected.path, selected.name);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open that video: $e');
    }
  }

  Future<void> _open(String path, String name) async {
    if (_opening) return;
    setState(() { _opening = true; _error = null; _status = null; _path = path; _name = name; _width = 0; _height = 0; _showPlayerView = true; _locked = false; _zoom = 1; });
    try {
      await _player.open(Media(path), play: true);
      try {
        final dimensions = await _channel.invokeMapMethod<String,dynamic>('getVideoDimensions', {'path':path});
        if (mounted && dimensions != null) setState(() {
          _width = (dimensions['width'] as num?)?.toInt() ?? 0;
          _height = (dimensions['height'] as num?)?.toInt() ?? 0;
        });
      } catch (_) {}
      await _saveRecent(path, name);
      try {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getInt(_resumeKey(path));
        if (saved != null && saved > 10000) await _player.seek(Duration(milliseconds: saved));
      } catch (_) {}
      if (mounted) setState(() => _opening = false);
      _armControls();
    } catch (e) {
      if (mounted) setState(() { _opening = false; _error = 'This video could not be played: $e'; });
    }
  }

  void _armControls() {
    _hideTimer?.cancel();
    if (mounted) setState(() => _showControls = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _player.state.playing) setState(() => _showControls = false);
    });
  }

  void _backToLibrary() {
    unawaited(_persistResume());
    setState(() { _showPlayerView = false; _status = null; _error = null; });
  }

  Future<void> _closePlayer() async {
    await _persistResume();
    await _player.stop();
    if (mounted) setState(() { _path = null; _name = null; _status = null; _error = null; _showPlayerView = false; });
  }

  String _time(Duration d) {
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${m.toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}' : '$m:${s.toString().padLeft(2,'0')}';
  }

  Future<void> _enhance() async {
    final source = _path;
    if (source == null || _enhancing || _width < 2 || _height < 2) return;
    final longEdge = _width > _height ? _width : _height;
    final shortEdge = _width < _height ? _width : _height;
    final outShort = (shortEdge * _target / longEdge).round().clamp(2, 4096);
    final outW = _width >= _height ? _target : outShort;
    final outH = _width >= _height ? outShort : _target;
    final output = '${Directory.systemTemp.path}/movie_${outW}x${outH}_${DateTime.now().microsecondsSinceEpoch}.mp4';
    setState(() { _enhancing = true; _status = 'Preparing a clearer ${_target}p copy…'; _error = null; });
    try {
      await _player.pause();
      final metadata = await _processing.inspect(source);
      final result = await _processing.process(ProcessingRequest.enhance(
        inputPath: source,
        outputPath: output,
        metadata: metadata,
        enhancement: EnhancementConfiguration(
          resolution: _target >= 2560 ? OutputResolution.p1440 : _target >= 1920 ? OutputResolution.p1080 : OutputResolution.p720,
          brightness: .08,
          contrast: .16,
          saturation: 14,
          outputWidth: outW,
          outputHeight: outH,
        ),
      ));
      try {
        await _channel.invokeMethod('saveVideoToGallery', {'inputPath':result.path,'displayName':'Movie_${_target}p_${DateTime.now().millisecondsSinceEpoch}.mp4'});
      } catch (_) {}
      if (!mounted) return;
      setState(() { _path = result.path; _name = 'Enhanced copy · ${_target}p'; _width = result.metadata.width; _height = result.metadata.height; _status = 'Playing your new ${_target}p copy'; });
      await _player.open(Media(result.path), play: true);
      await _saveRecent(result.path, _name!);
      _armControls();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not improve this video: ${e.toString().replaceFirst('Exception: ','')}');
    } finally {
      if (mounted) setState(() => _enhancing = false);
    }
  }

  Widget _section(String title, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 22, 2, 10),
    child: Row(children:[Expanded(child:Text(title,style:const TextStyle(fontSize:17,fontWeight:FontWeight.w800))),if(trailing!=null) trailing]),
  );

  Widget _posterRow(Map<String,String> movie, {bool recent = false}) {
    final name = movie['name'] ?? 'Video';
    final file = File(movie['path'] ?? '');
    final size = file.existsSync() ? file.lengthSync() : 0;
    final resume = int.tryParse(movie['resume'] ?? '') ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom:10),
      child: Material(
        color: const Color(0xFF17181D),
        borderRadius: BorderRadius.circular(17),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _opening ? null : () => _open(movie['path']!, name),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children:[
              Container(width:76,height:68,decoration:BoxDecoration(gradient:LinearGradient(colors:[_accent.withValues(alpha:.35),const Color(0xFF252832)]),borderRadius:BorderRadius.circular(12)),child:Icon(recent?Icons.history_rounded:Icons.movie_creation_outlined,size:30,color:_accent)),
              const SizedBox(width:12),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(name,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w700,fontSize:14)),
                const SizedBox(height:5),
                Text(recent && resume > 0 ? 'Resume at ${_time(Duration(milliseconds: resume))}' : '${_formatBytes(size)} · On this device',style:const TextStyle(color:Colors.white54,fontSize:11)),
              ])),
              IconButton(tooltip: _favorites.contains(movie['path']) ? 'Remove favorite' : 'Add favorite', onPressed: () => _toggleFavorite(movie['path']!), icon: Icon(_favorites.contains(movie['path']) ? Icons.star_rounded : Icons.star_border_rounded, color: _favorites.contains(movie['path']) ? _accent : Colors.white54)),
              const Icon(Icons.play_circle_fill_rounded,size:30),
            ]),
          ),
        ),
      ),
    );
  }

  String _formatBytes(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  Widget _library() {
    final q = _search.text.trim().toLowerCase();
    final filtered = _videos.where((v) {
      final path = v['path'] ?? '';
      final recent = _recent.any((item) => item['path'] == path);
      final tabMatch = switch (_libraryTab) {
        'Recent' => recent,
        'Favorites' => _favorites.contains(path),
        'Processed' => (v['name'] ?? '').toLowerCase().contains('processed') || (v['name'] ?? '').toLowerCase().contains('enhanced'),
        'Downloads' => path.toLowerCase().contains('/download') || path.toLowerCase().contains('\\download'),
        _ => true,
      };
      return tabMatch && (_sortBy != 'Favorites' || _favorites.contains(path)) && (v['name']??'').toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) => _sortBy == 'Name' ? (a['name'] ?? '').compareTo(b['name'] ?? '') : 0);
    return Stack(children:[RefreshIndicator(
      onRefresh: _scan,
      child: ListView(padding:EdgeInsets.fromLTRB(18,10,18,_hasMedia ? 112 : 28),children:[
        Row(children:[
          Container(width:48,height:48,decoration:BoxDecoration(color:_accent.withValues(alpha:.16),borderRadius:BorderRadius.circular(15)),child:Icon(Icons.movie_filter_rounded,color:_accent,size:27)),
          const SizedBox(width:12),
          const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('MOVIE PLAYER',style:TextStyle(color:Colors.white54,fontSize:10,fontWeight:FontWeight.w800,letterSpacing:1.7)),
            SizedBox(height:4),
            Text('Your cinema,\non your device.',style:TextStyle(fontSize:25,height:1.02,fontWeight:FontWeight.w900,letterSpacing:-.8)),
          ])),
          IconButton(tooltip: _gridView ? 'List view' : 'Grid view', onPressed: () => setState(() => _gridView = !_gridView), icon: Icon(_gridView ? Icons.view_list_rounded : Icons.grid_view_rounded)),
          PopupMenuButton<String>(onSelected:(value)=>setState(()=>_sortBy=value),itemBuilder:(_)=>const [PopupMenuItem(value:'Recent',child:Text('Sort: device order')),PopupMenuItem(value:'Name',child:Text('Sort: name')),PopupMenuItem(value:'Favorites',child:Text('Show favorites'))],icon:const Icon(Icons.sort_rounded)),
        ]),
        const SizedBox(height:17),
        TextField(controller:_search,onChanged:(_)=>setState((){}),decoration:InputDecoration(hintText:'Search videos',prefixIcon:const Icon(Icons.search_rounded),filled:true,fillColor:const Color(0xFF17181D),border:OutlineInputBorder(borderRadius:BorderRadius.circular(16),borderSide:BorderSide.none))),
        const SizedBox(height: 10),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [for (final tab in const ['All', 'Recent', 'Favorites', 'Processed', 'Downloads']) Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(tab), selected: _libraryTab == tab, onSelected: (_) => setState(() => _libraryTab = tab))) ])),
        const StatusHdAdBanner(),
        const SizedBox(height:12),
        SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:_opening?null:_browse,icon:const Icon(Icons.video_library_rounded),label:const Text('Open media manager'))),
        if(_recent.isNotEmpty) ...[
          _section('Continue watching',trailing:Text('${_recent.length} recent',style:TextStyle(color:_accent,fontSize:12,fontWeight:FontWeight.w700))),
          for(final movie in _recent.take(3)) _posterRow(movie,recent:true),
        ],
        _section('Your library',trailing:Text(_scanning?'Scanning…':'${filtered.length} videos',style:TextStyle(color:_accent,fontSize:12,fontWeight:FontWeight.w700))),
        if (_scanning) const LinearProgressIndicator(),
        if (filtered.isEmpty && !_scanning) Center(child:Padding(padding:const EdgeInsets.symmetric(vertical:30),child:Column(children:[Icon(q.isEmpty?Icons.video_library_outlined:Icons.search_off_rounded,size:42,color:Colors.white38),const SizedBox(height:12),Text(q.isEmpty?'No videos found yet':'No videos match your search.',style:const TextStyle(color:Colors.white70,fontWeight:FontWeight.w700)),const SizedBox(height:5),Text(q.isEmpty?'Open the media manager or refresh after granting media access.':'Try another title or clear the search.',style:const TextStyle(color:Colors.white54,fontSize:12))]))),
        if (_gridView)
          GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), itemCount: filtered.length, gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.35), itemBuilder: (_, index) => _gridTile(filtered[index]))
        else
          for(final movie in filtered) _posterRow(movie),
        if (_error!=null) Padding(padding:const EdgeInsets.only(top:12),child:Text(_error!,style:TextStyle(color:Theme.of(context).colorScheme.error))),
      ]),
    ),if(_hasMedia) Positioned(left:12,right:12,bottom:12,child:_miniPlayer())]);
  }

  Widget _gridTile(Map<String, String> movie) {
    final path = movie['path'] ?? '';
    final favorite = _favorites.contains(path);
    return Material(
      color: const Color(0xFF17181D),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _opening ? null : () => _open(path, movie['name'] ?? 'Video'),
        child: Stack(children: [
          Positioned.fill(child: Container(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_accent.withValues(alpha: .48), const Color(0xFF20232B), Colors.black])), child: Icon(Icons.movie_rounded, size: 38, color: Colors.white.withValues(alpha: .78)))),
          Positioned(left: 10, right: 10, bottom: 8, child: Text(movie['name'] ?? 'Video', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
          Positioned(top: 4, right: 4, child: IconButton(onPressed: () => _toggleFavorite(path), icon: Icon(favorite ? Icons.star_rounded : Icons.star_border_rounded, color: favorite ? _accent : Colors.white70, size: 19))),
        ]),
      ),
    );
  }

  Widget _miniPlayer() => Material(
    color: const Color(0xFF17181D),
    borderRadius: BorderRadius.circular(18),
    elevation: 10,
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => setState(() => _showPlayerView = true),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        child: Row(children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(color: _accent.withValues(alpha: .18), borderRadius: BorderRadius.circular(12)), child: Icon(Icons.movie_rounded, color: _accent)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_name ?? 'Now playing', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
            StreamBuilder<Duration>(stream: _player.stream.position, initialData: _player.state.position, builder: (_, snapshot) => Text('${_time(snapshot.data ?? Duration.zero)} · Tap to return', style: const TextStyle(fontSize: 11, color: Colors.white54))),
          ])),
          StreamBuilder<bool>(stream: _player.stream.playing, initialData: _player.state.playing, builder: (_, snapshot) => IconButton(onPressed: () => snapshot.data == true ? _player.pause() : _player.play(), icon: Icon(snapshot.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded))),
          IconButton(tooltip: 'Close player', onPressed: _closePlayer, icon: const Icon(Icons.close_rounded)),
        ]),
      ),
    ),
  );

  Widget _watch() {
    return Column(children:[
      Expanded(child:GestureDetector(
        onTap:_locked ? null : _armControls,
        onScaleUpdate:_locked ? null : (details) { if(details.scale != 1) setState(()=>_zoom = details.scale.clamp(1.0, 1.8).toDouble()); },
        child:Container(color:Colors.black,width:double.infinity,child:Stack(fit:StackFit.expand,children:[
          Center(child:Transform.scale(scale:_zoom,child:Video(controller:_video,fit:BoxFit.contain))),
          if(!_locked) Positioned.fill(child:Row(children:[
            Expanded(child:GestureDetector(onDoubleTap:(){_player.seek(_player.state.position-const Duration(seconds:10));_armControls();})),
            Expanded(child:GestureDetector(onDoubleTap:(){_player.seek(_player.state.position+const Duration(seconds:10));_armControls();})),
          ])),
          if (_showControls) ...[
            Positioned(top:8,left:8,right:8,child:Row(children:[
              IconButton(onPressed:_backToLibrary,icon:const Icon(Icons.arrow_back_rounded,color:Colors.white)),
              Expanded(child:Text(_name??'',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w700))),
              IconButton(tooltip:_locked?'Unlock controls':'Lock controls',onPressed:(){_hideTimer?.cancel();setState(()=>_locked=!_locked);},icon:Icon(_locked?Icons.lock_rounded:Icons.lock_open_rounded,color:Colors.white)),
              IconButton(onPressed:()=>setState(()=>_speed=_speed==2?0.5:_speed+0.25),icon:Text('${_speed.toStringAsFixed(2)}×',style:const TextStyle(color:Colors.white,fontSize:12))),
            ])),
            Center(child:Row(mainAxisAlignment:MainAxisAlignment.center,children:[
              IconButton(iconSize:35,onPressed:()=>_player.seek(_player.state.position-Duration(seconds:10)),icon:const Icon(Icons.replay_10_rounded,color:Colors.white)),
              const SizedBox(width:24),
              StreamBuilder<bool>(stream:_player.stream.playing,initialData:_player.state.playing,builder:(context,snap)=>IconButton(iconSize:62,onPressed:(){if(snap.data??false){_player.pause();}else{_player.play();}_armControls();},icon:Icon((snap.data??false)?Icons.pause_circle_filled_rounded:Icons.play_circle_fill_rounded,color:Colors.white))),
              const SizedBox(width:24),
              IconButton(iconSize:35,onPressed:()=>_player.seek(_player.state.position+Duration(seconds:10)),icon:const Icon(Icons.forward_10_rounded,color:Colors.white)),
            ])),
            Positioned(bottom:8,left:12,right:12,child:Column(children:[
              StreamBuilder<Duration>(stream:_player.stream.position,initialData:_player.state.position,builder:(context,p)=>StreamBuilder<Duration>(stream:_player.stream.duration,initialData:_player.state.duration,builder:(context,d){
                final duration=d.data??Duration.zero, pos=p.data??Duration.zero;
                final max=duration.inMilliseconds.toDouble();
                return Row(children:[Text(_time(pos),style:const TextStyle(color:Colors.white70,fontSize:11)),Expanded(child:Slider(value:max>0?pos.inMilliseconds.clamp(0,max.toInt()).toDouble():0,max:max>0?max:1,onChanged:max>0?(v)=>_player.seek(Duration(milliseconds:v.round())):null)),Text(_time(duration),style:const TextStyle(color:Colors.white70,fontSize:11))]);
              })),
            ])),
          ],
        ])),
      )),
      Container(color:const Color(0xFF111216),padding:const EdgeInsets.fromLTRB(16,12,16,16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[Expanded(child:Text(_name??'Now playing',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w800,fontSize:16))),if(_width>0)Text('${_width}×$_height',style:TextStyle(color:_accent,fontSize:11,fontWeight:FontWeight.w700))]),
        const SizedBox(height:12),
        Row(children:[
          Expanded(child:OutlinedButton.icon(onPressed:_showPlayerOptions,icon:const Icon(Icons.tune_rounded),label:const Text('Now playing'))),
          const SizedBox(width:10),
          Expanded(child:FilledButton.icon(onPressed:_enhancing||_width<2?null:_showEnhancementOptions,icon:_enhancing?const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.auto_awesome_rounded),label:Text(_enhancing?'Improving…':'Improve video'))),
        ]),
        if(_enhancing) const Padding(padding:EdgeInsets.only(top:12),child:LinearProgressIndicator()),
        if(_status!=null) Padding(padding:const EdgeInsets.only(top:8),child:Text(_status!,style:TextStyle(color:_accent,fontSize:12))),
        if(_error!=null) Padding(padding:const EdgeInsets.only(top:8),child:Text(_error!,style:TextStyle(color:Theme.of(context).colorScheme.error,fontSize:12))),
      ])),
    ]);
  }

  Future<void> _showEnhancementOptions() async {
    var selected = _target;
    final result = await showModalBottomSheet<int>(context:context,backgroundColor:const Color(0xFF17181D),showDragHandle:true,builder:(ctx)=>StatefulBuilder(builder:(ctx,setSheet)=>SafeArea(child:Padding(padding:const EdgeInsets.fromLTRB(20,8,20,24),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('Make this video clearer',style:TextStyle(fontSize:21,fontWeight:FontWeight.w900)),
      const SizedBox(height:6),
      Text('Source: ${_width}×$_height. The original is kept; a new copy is created.',style:const TextStyle(color:Colors.white60,fontSize:12)),
      const SizedBox(height:18),
      Wrap(spacing:8,children:[for(final size in [480,720,1080,1440]) ChoiceChip(label:Text('${size}p'),selected:selected==size,onSelected:(_)=>setSheet(()=>selected=size))]),
      const SizedBox(height:12),
      const Text('The export applies visible brightness, contrast, colour and high-quality resampling. It creates a separate copy; resizing alone cannot recover missing detail.',style:TextStyle(color:Colors.white54,fontSize:12,height:1.45)),
      const SizedBox(height:12),
      SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:()=>Navigator.pop(ctx,selected),icon:const Icon(Icons.auto_awesome_rounded),label:const Text('Create clearer copy'))),
    ])))));
    if(result!=null&&mounted){setState(()=>_target=result);unawaited(_enhance());}
  }

  void _setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    if (minutes <= 0) {
      setState(() => _status = 'Sleep timer is off.');
      return;
    }
    setState(() => _status = 'Sleep timer set for $minutes minutes.');
    _sleepTimer = Timer(Duration(minutes: minutes), () async {
      await _player.pause();
      if (mounted) setState(() => _status = 'Sleep timer paused playback.');
    });
  }

  Future<void> _showSleepTimer() async {
    final minutes = await showModalBottomSheet<int>(context: context, backgroundColor: const Color(0xFF17181D), showDragHandle: true, builder: (ctx) => SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('Sleep timer', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: 10),
      for (final value in [15, 30, 60, 0]) ListTile(leading: const Icon(Icons.bedtime_rounded), title: Text(value == 0 ? 'Turn off timer' : '$value minutes'), onTap: () => Navigator.pop(ctx, value)),
    ]))));
    if (minutes != null && mounted) _setSleepTimer(minutes);
  }

  Future<void> _showPlayerOptions() async {
    var speed = _speed;
    final result = await showModalBottomSheet<double>(context:context,backgroundColor:const Color(0xFF17181D),showDragHandle:true,builder:(ctx)=>StatefulBuilder(builder:(ctx,setSheet)=>SafeArea(child:Padding(padding:const EdgeInsets.fromLTRB(20,8,20,24),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('Playback settings',style:TextStyle(fontSize:20,fontWeight:FontWeight.w800)),
      const SizedBox(height:12),
      const Text('Playback speed'),
      Wrap(spacing:8,children:[for(final value in [0.5,0.75,1.0,1.25,1.5,2.0])ChoiceChip(label:Text('${value}×'),selected:speed==value,onSelected:(_)=>setSheet(()=>speed=value))]),
      const SizedBox(height:10),
      ListTile(leading:const Icon(Icons.subtitles_rounded),title:const Text('Load subtitles'),onTap:()async{Navigator.pop(ctx,speed);await _chooseSubtitle();}),
      ListTile(leading:const Icon(Icons.audiotrack_rounded),title:const Text('Audio and subtitle tracks'),onTap:(){Navigator.pop(ctx,speed);unawaited(_showTracks());}),
      ListTile(leading:const Icon(Icons.bedtime_rounded),title:const Text('Sleep timer'),subtitle:const Text('Pause automatically after 15, 30 or 60 minutes'),onTap:(){Navigator.pop(ctx,speed);unawaited(_showSleepTimer());}),
      ListTile(leading:const Icon(Icons.zoom_out_map_rounded),title:const Text('Reset video zoom'),onTap:(){setState(()=>_zoom=1);Navigator.pop(ctx,speed);}),
    ])))));
    if(result!=null&&mounted){setState(()=>_speed=result);await _player.setRate(result);}
  }

  Future<void> _chooseSubtitle() async {
    final result=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:const ['srt','ass','ssa','vtt'],withData:false);
    final path=result == null || result.files.isEmpty ? null : result.files.single.path;
    if(path==null)return;
    try{await _player.setSubtitleTrack(SubtitleTrack.uri(path));if(mounted)setState(()=>_status='Subtitle loaded: ${result!.files.single.name}');}catch(e){if(mounted)setState(()=>_error='Could not load subtitles: $e');}
  }

  Future<void> _showTracks() async {
    final tracks=_player.state.tracks;
    if(!mounted)return;
    await showModalBottomSheet<void>(context:context,backgroundColor:const Color(0xFF17181D),showDragHandle:true,builder:(ctx)=>SafeArea(child:ListView(shrinkWrap:true,padding:const EdgeInsets.all(16),children:[
      const Text('Audio tracks',style:TextStyle(fontSize:18,fontWeight:FontWeight.w800)),
      for(final track in tracks.audio) ListTile(title:Text(track.title??track.language??'Audio track'),onTap:(){_player.setAudioTrack(track);Navigator.pop(ctx);}),
      const Divider(),
      const Text('Subtitle tracks',style:TextStyle(fontSize:18,fontWeight:FontWeight.w800)),
      for(final track in tracks.subtitle) ListTile(title:Text(track.title??track.language??'Subtitle track'),onTap:(){_player.setSubtitleTrack(track);Navigator.pop(ctx);}),
      ListTile(title:const Text('Subtitles off'),onTap:(){_player.setSubtitleTrack(SubtitleTrack.no());Navigator.pop(ctx);}),
    ])));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor:const Color(0xFF08090B),
    appBar:_watching?null:AppBar(title:const Text('Movie Player',style:TextStyle(fontWeight:FontWeight.w800)),actions:[IconButton(tooltip:'Open media manager',onPressed:_browse,icon:const Icon(Icons.video_library_rounded))]),
    body:SafeArea(child:_watching?_watch():_library()),
  );
}
