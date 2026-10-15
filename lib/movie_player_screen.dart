import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A focused, cinema-style local movie player using libmpv/media_kit.
/// Video enhancement uses the app's native Media3 encoder; it does not upload
/// private videos to an unspecified third-party service.
class MoviePlayerScreen extends StatefulWidget {
  const MoviePlayerScreen({super.key, this.initialPath, this.initialName});
  final String? initialPath;
  final String? initialName;

  @override
  State<MoviePlayerScreen> createState() => _MoviePlayerScreenState();
}

class _MoviePlayerScreenState extends State<MoviePlayerScreen> {
  static const _channel = MethodChannel('com.ptip.statushd/media');
  static const _extensions = <String>['mp4','mkv','avi','mov','webm','flv','wmv','m4v','3gp','ts','mpeg','mpg','ogv','vob','asf','m2ts','mts','mxf'];
  late final Player _player;
  late final VideoController _video;
  final TextEditingController _search = TextEditingController();
  List<Map<String,String>> _videos = [];
  List<Map<String,String>> _recent = [];
  String? _path;
  String? _name;
  String? _error;
  String? _status;
  int _width = 0, _height = 0, _target = 1080;
  bool _scanning = false, _opening = false, _enhancing = false, _showControls = true;
  double _speed = 1;
  Timer? _hideTimer;

  Color get _accent => Theme.of(context).colorScheme.primary;
  bool get _watching => _path != null && _name != null;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _video = VideoController(_player);
    _loadRecent();
    _scan();
    if (widget.initialPath != null && widget.initialPath!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(widget.initialPath!, widget.initialName ?? File(widget.initialPath!).uri.pathSegments.last));
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
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
          items.add({'path': split.first, 'name': split.sublist(1).join('|')});
        }
      }
      if (mounted) setState(() => _recent = items);
    } catch (_) {}
  }

  Future<void> _saveRecent(String path, String name) async {
    final next = <Map<String,String>>[
      {'path': path, 'name': name},
      ..._recent.where((v) => v['path'] != path),
    ].take(10).toList();
    if (mounted) setState(() => _recent = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('movie_recent_v2', next.map((v) => Uri.encodeComponent('${v['path']}|${v['name']}')).toList());
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
      if (mounted) setState(() => _error = 'Could not scan device videos. Use Browse files to choose a video.');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _browse() async {
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: _extensions, allowMultiple: false, withData: false);
      if (result == null || result.files.isEmpty || !mounted) return;
      final file = result.files.single;
      if (file.path == null) throw StateError('This file provider did not return a readable path.');
      await _open(file.path!, file.name);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open that video: $e');
    }
  }

  Future<void> _open(String path, String name) async {
    if (_opening) return;
    setState(() { _opening = true; _error = null; _status = null; _path = path; _name = name; _width = 0; _height = 0; });
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
    unawaited(_player.stop());
    setState(() { _path = null; _name = null; _status = null; _error = null; });
    unawaited(_scan());
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
      final result = await _channel.invokeMethod<String>('enhanceVideo', {
        'inputPath': source, 'outputPath': output, 'outputWidth': outW, 'outputHeight': outH,
        'brightness': 0.08, 'contrast': 0.16, 'saturation': 14.0,
      });
      if (result == null || !await File(result).exists() || await File(result).length() == 0) throw StateError('No output video was created.');
      try {
        await _channel.invokeMethod('saveVideoToGallery', {'inputPath':result,'displayName':'Movie_${_target}p_${DateTime.now().millisecondsSinceEpoch}.mp4'});
      } catch (_) {}
      if (!mounted) return;
      setState(() { _path = result; _name = 'Enhanced copy · ${_target}p'; _width = outW; _height = outH; _status = 'Playing your new ${_target}p copy'; });
      await _player.open(Media(result), play: true);
      await _saveRecent(result, _name!);
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
              Container(width:76,height:68,decoration:BoxDecoration(color:const Color(0xFF252832),borderRadius:BorderRadius.circular(12)),child:Icon(recent?Icons.history_rounded:Icons.movie_creation_outlined,size:30,color:_accent)),
              const SizedBox(width:12),
              Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                Text(name,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w700,fontSize:14)),
                const SizedBox(height:5),
                Text(recent?'Continue watching':'On this device',style:const TextStyle(color:Colors.white54,fontSize:11)),
              ])),
              const Icon(Icons.play_circle_fill_rounded,size:30),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _library() {
    final q = _search.text.trim().toLowerCase();
    final filtered = _videos.where((v)=>(v['name']??'').toLowerCase().contains(q)).toList();
    return RefreshIndicator(
      onRefresh: _scan,
      child: ListView(padding:const EdgeInsets.fromLTRB(18,10,18,28),children:[
        Row(children:[
          Container(width:48,height:48,decoration:BoxDecoration(color:_accent.withValues(alpha:.16),borderRadius:BorderRadius.circular(15)),child:Icon(Icons.movie_filter_rounded,color:_accent,size:27)),
          const SizedBox(width:12),
          const Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('YOUR MOVIE LIBRARY',style:TextStyle(color:Colors.white54,fontSize:10,fontWeight:FontWeight.w800,letterSpacing:1.7)),
            SizedBox(height:4),
            Text('What shall we watch?',style:TextStyle(fontSize:23,fontWeight:FontWeight.w900,letterSpacing:-.6)),
          ])),
          IconButton(onPressed:_scanning?null:_scan,icon:const Icon(Icons.refresh_rounded)),
        ]),
        const SizedBox(height:17),
        TextField(controller:_search,onChanged:(_)=>setState((){}),decoration:InputDecoration(hintText:'Search videos',prefixIcon:const Icon(Icons.search_rounded),filled:true,fillColor:const Color(0xFF17181D),border:OutlineInputBorder(borderRadius:BorderRadius.circular(16),borderSide:BorderSide.none))),
        const SizedBox(height:12),
        SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:_opening?null:_browse,icon:const Icon(Icons.folder_open_rounded),label:const Text('Browse videos'))),
        _section('On this device',trailing:Text(_scanning?'Scanning…':'${filtered.length} videos',style:TextStyle(color:_accent,fontSize:12,fontWeight:FontWeight.w700))),
        if (_scanning) const LinearProgressIndicator(),
        if (filtered.isEmpty && !_scanning) Padding(padding:const EdgeInsets.symmetric(vertical:22),child:Text(q.isEmpty?'No videos found yet. Browse files to choose a video.':'No videos match your search.',style:const TextStyle(color:Colors.white54))),
        for(final movie in filtered) _posterRow(movie),
        if (_error!=null) Padding(padding:const EdgeInsets.only(top:12),child:Text(_error!,style:TextStyle(color:Theme.of(context).colorScheme.error))),
      ]),
    );
  }

  Widget _watch() {
    return Column(children:[
      Expanded(child:GestureDetector(
        onTap:_armControls,
        child:Container(color:Colors.black,width:double.infinity,child:Stack(fit:StackFit.expand,children:[
          Center(child:Video(controller:_video,fit:BoxFit.contain)),
          if (_showControls) ...[
            Positioned(top:8,left:8,right:8,child:Row(children:[
              IconButton(onPressed:_backToLibrary,icon:const Icon(Icons.arrow_back_rounded,color:Colors.white)),
              Expanded(child:Text(_name??'',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w700))),
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
          Expanded(child:OutlinedButton.icon(onPressed:()=>_showPlayerOptions(),icon:const Icon(Icons.tune_rounded),label:const Text('Player controls'))),
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
    appBar:_watching?null:AppBar(title:const Text('Movie Player',style:TextStyle(fontWeight:FontWeight.w800)),actions:[IconButton(onPressed:_browse,icon:const Icon(Icons.folder_open_rounded))]),
    body:SafeArea(child:_watching?_watch():_library()),
  );
}
