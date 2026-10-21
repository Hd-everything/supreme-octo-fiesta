import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:statushd/models/edit_project.dart';
import 'package:statushd/services/edit_project_store.dart';

void main() {
  const clipA = EditClip(id: 'a', path: '/media/a.mp4', name: 'a.mp4', durationMs: 10000, startMs: 1000, endMs: 5000);
  const clipB = EditClip(id: 'b', path: '/media/b.mp4', name: 'b.mp4', durationMs: 12000, startMs: 0, endMs: 8000);
  final created = DateTime(2025, 1, 2);
  final project = EditProject(id: 'project', name: 'Travel', createdAt: created, updatedAt: created, clips: [clipA, clipB]);

  test('project duration uses trimmed timeline ranges', () {
    expect(project.durationMs, 12000);
  });

  test('project JSON round-trips ordered clip trims', () {
    final restored = EditProject.fromJson(jsonDecode(encodeEditProject(project)) as Map<String, dynamic>);
    expect(restored.clips.map((clip) => clip.id), ['a', 'b']);
    expect(restored.clips.first.startMs, 1000);
    expect(restored.clips.first.endMs, 5000);
    expect(restored.durationMs, 12000);
  });

  test('project JSON round-trips clip adjustments, soundtrack, and timed overlays', () {
    final edited = EditProject(
      id: 'project',
      name: 'Travel',
      createdAt: created,
      updatedAt: created,
      clips: [clipA.copyWith(rotation: 90, volume: .6, brightness: .1, contrast: -.1, saturation: 12)],
      aspectRatio: '9:16',
      musicPath: '/projects/audio/theme.mp3',
      musicName: 'theme.mp3',
      musicVolume: .4,
      musicOffsetMs: 350,
      overlays: const [EditTextOverlay(id: 'title', text: 'Hello', startMs: 400, endMs: 2600, color: 0xFFFFCC00, fontSize: 42, x: .2, y: .7)],
      imageOverlays: const [EditImageOverlay(id: 'logo', path: '/projects/images/logo.png', name: 'logo.png', startMs: 1000, endMs: 3000, x: .6, y: .3, scale: .2)],
    );
    final restored = EditProject.fromJson(jsonDecode(encodeEditProject(edited)) as Map<String, dynamic>);
    expect(restored.aspectRatio, '9:16');
    expect(restored.clips.single.rotation, 90);
    expect(restored.clips.single.volume, .6);
    expect(restored.musicPath, '/projects/audio/theme.mp3');
    expect(restored.musicOffsetMs, 350);
    expect(restored.overlays.single.text, 'Hello');
    expect(restored.overlays.single.y, .7);
    expect(restored.imageOverlays.single.path, '/projects/images/logo.png');
    expect(restored.imageOverlays.single.scale, .2);
  });

  test('project rejects invalid timed text and image overlay ranges', () {
    final data = project.toJson();
    data['overlays'] = [const EditTextOverlay(id: 'bad', text: 'Title', startMs: 0, endMs: 13000).toJson()];
    expect(() => EditProject.fromJson(data), throwsFormatException);
    data['overlays'] = [];
    data['imageOverlays'] = [const EditImageOverlay(id: 'bad', path: '', name: 'x', startMs: 0, endMs: 1000).toJson()];
    expect(() => EditProject.fromJson(data), throwsFormatException);
  });

  test('rejects a clip trim outside source duration', () {
    final data = project.toJson();
    data['clips'] = [clipA.copyWith(endMs: 10001).toJson()];
    expect(() => EditProject.fromJson(data), throwsFormatException);
  });

  test('project store restores, updates, and deletes projects', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = EditProjectStore(preferences);
    await store.save(project);
    expect(store.load().single.name, 'Travel');
    await store.save(project.copyWith(name: 'Weekend'));
    expect(store.load().single.name, 'Weekend');
    await store.delete(project.id);
    expect(store.load(), isEmpty);
  });
}
