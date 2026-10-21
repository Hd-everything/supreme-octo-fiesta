import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'media_manager_screen.dart';
import 'models/edit_project.dart';
import 'services/ads/rewarded_ad_service.dart';
import 'services/cloud_render_service.dart';

/// Compact status-video export, separate from the multi-clip editor.
class StatusHdScreen extends StatefulWidget {
  const StatusHdScreen({super.key, required this.preferences});
  final SharedPreferences preferences;
  @override
  State<StatusHdScreen> createState() => _StatusHdScreenState();
}

class _StatusHdScreenState extends State<StatusHdScreen> {
  final _ads = RewardedAdService();
  DeviceMedia? _source;
  String _resolution = '1080p';
  List<String> _resolutions = const ['720p', '1080p'];
  bool _loading = true, _rendering = false;
  double _progress = 0;
  String _status = 'Choose a video to prepare for status.';
  String? _outputPath;

  @override
  void initState() {
    super.initState();
    unawaited(_ads.preload());
    unawaited(_loadCapabilities());
  }

  Future<void> _loadCapabilities() async {
    try {
      final response = await CloudRenderService(Supabase.instance.client, preferences: widget.preferences).capabilities();
      final values = (response['resolutions'] as List? ?? const []).whereType<String>()
          .where((v) => const {'720p','1080p','1440p','4k','8k'}.contains(v.toLowerCase())).toList();
      if (!mounted) return;
      setState(() {
        _resolutions = values.isEmpty ? const ['720p','1080p'] : values;
        if (!_resolutions.contains(_resolution)) _resolution = _resolutions.contains('1080p') ? '1080p' : _resolutions.first;
        _loading = false;
      });
    } catch (_) { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _pick() async {
    final picked = await Navigator.of(context).push<List<DeviceMedia>>(
      MaterialPageRoute(builder: (_) => const MediaManagerScreen(videosOnly: true, multiSelect: false)));
    if (!mounted || picked == null || picked.isEmpty) return;
    final item = picked.first;
    if (!File(item.path).existsSync() || item.duration <= 0) {
      setState(() => _status = 'That video is unavailable. Choose another file.'); return;
    }
    setState(() { _source = item; _outputPath = null; _status = 'Ready to export ${item.name}.'; });
  }

  Future<void> _export() async {
    final source = _source;
    if (source == null || _rendering) return;
    final client = Supabase.instance.client;
    if (client.auth.currentUser == null) {
      final signedIn = await _signIn();
      if (!signedIn || !mounted) return;
    }
    setState(() { _rendering = true; _progress = 0; _outputPath = null; _status = 'Preparing rewarded ad…'; });
    try {
      final earned = await _ads.showFor1080p();
      if (!earned) {
        if (mounted) setState(() => _status = 'A rewarded ad was not completed or is unavailable. Try again later.');
        return;
      }
      final now = DateTime.now();
      final project = EditProject(
        id: 'status_${now.microsecondsSinceEpoch}', name: 'Status HD · ${source.name}',
        createdAt: now, updatedAt: now, aspectRatio: '9:16',
        clips: [EditClip(id: 'status_clip_${now.microsecondsSinceEpoch}', path: source.path, name: source.name, durationMs: source.duration)],
      );
      final result = await CloudRenderService(client, preferences: widget.preferences).renderProject(
        project: project, resolution: _resolution,
        onProgress: (event) {
          if (!mounted) return;
          setState(() { _progress = event.progress.clamp(0, 1); _status = event.message ?? event.stage; });
        });
      if (mounted) setState(() { _outputPath = result['path'] as String?; _status = 'Export complete. Output is ready for review.'; });
    } catch (error) {
      if (mounted) setState(() => _status = error.toString().replaceFirst('CloudRenderException: ', ''));
    } finally { if (mounted) setState(() => _rendering = false); }
  }

  Future<bool> _signIn() async {
    final email = TextEditingController(), password = TextEditingController();
    try {
      final credentials = await showDialog<({String email, String password})>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Sign in for cloud export'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
            TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, (email: email.text.trim(), password: password.text)), child: const Text('Sign in')),
          ],
        ));
      if (credentials == null || credentials.email.isEmpty || credentials.password.isEmpty) return false;
      await Supabase.instance.client.auth.signInWithPassword(email: credentials.email, password: credentials.password);
      if (mounted) setState(() => _status = 'Signed in. Tap export again to continue.');
      return true;
    } catch (_) {
      if (mounted) setState(() => _status = 'Sign-in failed. Check your credentials and try again.');
      return false;
    } finally { email.dispose(); password.dispose(); }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: const Text('Status HD')),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(20), children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [accent.withValues(alpha: .18), const Color(0xFF171D25)]),
            borderRadius: BorderRadius.circular(24), border: Border.all(color: accent.withValues(alpha: .24))),
          child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.video_settings_rounded, size: 34), SizedBox(height: 14),
            Text('Status-ready videos', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
            SizedBox(height: 8),
            Text('Prepare a video for social status. Cloud FFmpeg exports and resolutions depend on the verified worker.'),
          ])),
        const SizedBox(height: 18),
        OutlinedButton.icon(onPressed: _rendering ? null : _pick, icon: const Icon(Icons.video_library_outlined),
          label: Text(_source?.name ?? 'Choose a video'),
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), alignment: Alignment.centerLeft)),
        const SizedBox(height: 16),
        Text('Export resolution', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_loading) const LinearProgressIndicator() else Wrap(spacing: 8, runSpacing: 8,
          children: _resolutions.map((resolution) => ChoiceChip(
            label: Text(const {'4k','8k'}.contains(resolution.toLowerCase()) ? '$resolution · Cloud' : resolution),
            selected: resolution == _resolution, onSelected: _rendering ? null : (_) => setState(() => _resolution = resolution),
          )).toList()),
        const SizedBox(height: 8),
        const Text('4K/8K are shown only when advertised by the worker. High-resolution rendering uses more time and data.',
          style: TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 18),
        FilledButton.icon(onPressed: _rendering || _source == null ? null : _export,
          icon: _rendering ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.cloud_upload_outlined),
          label: Text(_rendering ? 'Rendering…' : 'Watch ad & export'),
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16))),
        if (_rendering) ...[const SizedBox(height: 12), LinearProgressIndicator(value: _progress > 0 ? _progress : null)],
        const SizedBox(height: 16), Text(_status, style: const TextStyle(color: Colors.white70)),
        if (_outputPath != null) ...[
          const SizedBox(height: 10), SelectableText(_outputPath!, style: const TextStyle(fontSize: 12, color: Colors.white54)),
          const Text('Output is currently in temporary app storage; save it permanently before clearing app data.',
            style: TextStyle(fontSize: 12, color: Colors.white54)),
        ],
        const SizedBox(height: 24),
        const Text('Cloud export requires a signed-in account, internet access, and a deployed, verified FFmpeg worker. Ads do not guarantee a successful render.',
          style: TextStyle(color: Colors.white54, fontSize: 12)),
      ])),
    );
  }
}
