import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/edit_project.dart';

class EditProjectStore {
  EditProjectStore(this.preferences);

  static const _key = 'vyntra_edit_projects_v1';
  final SharedPreferences preferences;

  List<EditProject> load() {
    final projects = <EditProject>[];
    for (final raw in preferences.getStringList(_key) ?? const <String>[]) {
      try {
        projects.add(EditProject.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map)));
      } on Object {
        // A damaged project is skipped so it cannot prevent the library opening.
      }
    }
    projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return projects;
  }

  Future<void> save(EditProject project) async {
    final projects = load().where((item) => item.id != project.id).toList()..add(project);
    projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await preferences.setStringList(_key, projects.map(encodeEditProject).toList());
  }

  Future<void> delete(String id) async {
    final projects = load().where((item) => item.id != id).toList();
    await preferences.setStringList(_key, projects.map(encodeEditProject).toList());
  }
}
