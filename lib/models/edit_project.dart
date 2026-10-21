import 'dart:convert';

class EditClip {
  const EditClip({required this.id, required this.path, required this.name, required this.durationMs, this.startMs = 0, int? endMs})
      : endMs = endMs ?? durationMs;

  final String id;
  final String path;
  final String name;
  final int durationMs;
  final int startMs;
  final int endMs;

  int get lengthMs => endMs - startMs;
  EditClip copyWith({String? id, String? path, String? name, int? durationMs, int? startMs, int? endMs}) => EditClip(
        id: id ?? this.id,
        path: path ?? this.path,
        name: name ?? this.name,
        durationMs: durationMs ?? this.durationMs,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
      );

  Map<String, Object> toJson() => {'id': id, 'path': path, 'name': name, 'durationMs': durationMs, 'startMs': startMs, 'endMs': endMs};
  factory EditClip.fromJson(Map<String, dynamic> json) => EditClip(
        id: json['id'] as String,
        path: json['path'] as String,
        name: json['name'] as String,
        durationMs: (json['durationMs'] as num).toInt(),
        startMs: (json['startMs'] as num?)?.toInt() ?? 0,
        endMs: (json['endMs'] as num?)?.toInt(),
      );
}

class EditProject {
  const EditProject({required this.id, required this.name, required this.createdAt, required this.updatedAt, required this.clips});

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<EditClip> clips;

  int get durationMs => clips.fold(0, (sum, clip) => sum + clip.lengthMs);
  EditProject copyWith({String? name, DateTime? updatedAt, List<EditClip>? clips}) => EditProject(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        clips: clips ?? this.clips,
      );

  Map<String, Object> toJson() => {
        'schemaVersion': 1,
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'clips': clips.map((clip) => clip.toJson()).toList(),
      };

  factory EditProject.fromJson(Map<String, dynamic> json) {
    if ((json['schemaVersion'] as num?)?.toInt() != 1) throw const FormatException('Unsupported project schema version.');
    final clips = (json['clips'] as List<dynamic>).map((item) => EditClip.fromJson(Map<String, dynamic>.from(item as Map))).toList();
    if (clips.isEmpty || clips.any((clip) => clip.path.isEmpty || clip.startMs < 0 || clip.endMs <= clip.startMs || clip.endMs > clip.durationMs)) {
      throw const FormatException('Project contains invalid clips.');
    }
    return EditProject(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      clips: clips,
    );
  }
}

String encodeEditProject(EditProject project) => jsonEncode(project.toJson());
