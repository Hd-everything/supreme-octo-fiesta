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
