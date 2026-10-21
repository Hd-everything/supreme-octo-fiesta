import 'dart:convert';

class EditClip {
  const EditClip({
    required this.id,
    required this.path,
    required this.name,
    required this.durationMs,
    this.startMs = 0,
    int? endMs,
    this.rotation = 0,
    this.volume = 1,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
  }) : endMs = endMs ?? durationMs;

  final String id;
  final String path;
  final String name;
  final int durationMs;
  final int startMs;
  final int endMs;
  final int rotation;
  final double volume;
  final double brightness;
  final double contrast;
  final double saturation;

  int get lengthMs => endMs - startMs;
  EditClip copyWith({String? id, String? path, String? name, int? durationMs, int? startMs, int? endMs, int? rotation, double? volume, double? brightness, double? contrast, double? saturation}) => EditClip(
        id: id ?? this.id,
        path: path ?? this.path,
        name: name ?? this.name,
        durationMs: durationMs ?? this.durationMs,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        rotation: rotation ?? this.rotation,
        volume: volume ?? this.volume,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'path': path,
        'name': name,
        'durationMs': durationMs,
        'startMs': startMs,
        'endMs': endMs,
        'rotation': rotation,
        'volume': volume,
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
      };
  factory EditClip.fromJson(Map<String, dynamic> json) => EditClip(
        id: json['id'] as String,
        path: json['path'] as String,
        name: json['name'] as String,
        durationMs: (json['durationMs'] as num).toInt(),
        startMs: (json['startMs'] as num?)?.toInt() ?? 0,
        endMs: (json['endMs'] as num?)?.toInt(),
        rotation: (json['rotation'] as num?)?.toInt() ?? 0,
        volume: (json['volume'] as num?)?.toDouble() ?? 1,
        brightness: (json['brightness'] as num?)?.toDouble() ?? 0,
        contrast: (json['contrast'] as num?)?.toDouble() ?? 0,
        saturation: (json['saturation'] as num?)?.toDouble() ?? 0,
      );
}

class EditTextOverlay {
  const EditTextOverlay({required this.id, required this.text, required this.startMs, required this.endMs, this.color = 0xFFFFFFFF, this.fontSize = 34, this.x = 0, this.y = .55});
  final String id;
  final String text;
  final int startMs;
  final int endMs;
  final int color;
  final double fontSize;
  final double x;
  final double y;

  Map<String, Object> toJson() => {'id': id, 'text': text, 'startMs': startMs, 'endMs': endMs, 'color': color, 'fontSize': fontSize, 'x': x, 'y': y};
  factory EditTextOverlay.fromJson(Map<String, dynamic> json) => EditTextOverlay(
        id: json['id'] as String,
        text: json['text'] as String,
        startMs: (json['startMs'] as num).toInt(),
        endMs: (json['endMs'] as num).toInt(),
        color: (json['color'] as num?)?.toInt() ?? 0xFFFFFFFF,
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 34,
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? .55,
      );
}

class EditImageOverlay {
  const EditImageOverlay({required this.id, required this.path, required this.name, required this.startMs, required this.endMs, this.x = .65, this.y = .55, this.scale = .28});
  final String id;
  final String path;
  final String name;
  final int startMs;
  final int endMs;
  final double x;
  final double y;
  final double scale;

  Map<String, Object> toJson() => {'id': id, 'path': path, 'name': name, 'startMs': startMs, 'endMs': endMs, 'x': x, 'y': y, 'scale': scale};
  factory EditImageOverlay.fromJson(Map<String, dynamic> json) => EditImageOverlay(
        id: json['id'] as String,
        path: json['path'] as String,
        name: json['name'] as String,
        startMs: (json['startMs'] as num).toInt(),
        endMs: (json['endMs'] as num).toInt(),
        x: (json['x'] as num?)?.toDouble() ?? .65,
        y: (json['y'] as num?)?.toDouble() ?? .55,
        scale: (json['scale'] as num?)?.toDouble() ?? .28,
      );
}

class EditProject {
  const EditProject({required this.id, required this.name, required this.createdAt, required this.updatedAt, required this.clips, this.aspectRatio = 'Original', this.musicPath, this.musicName, this.musicVolume = .35, this.musicOffsetMs = 0, this.overlays = const [], this.imageOverlays = const []});

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<EditClip> clips;
  final String aspectRatio;
  final String? musicPath;
  final String? musicName;
  final double musicVolume;
  final int musicOffsetMs;
  final List<EditTextOverlay> overlays;
  final List<EditImageOverlay> imageOverlays;

  int get durationMs => clips.fold(0, (sum, clip) => sum + clip.lengthMs);
  EditProject copyWith({String? name, DateTime? updatedAt, List<EditClip>? clips, String? aspectRatio, String? musicPath, String? musicName, double? musicVolume, int? musicOffsetMs, List<EditTextOverlay>? overlays, List<EditImageOverlay>? imageOverlays, bool removeMusic = false}) => EditProject(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        clips: clips ?? this.clips,
        aspectRatio: aspectRatio ?? this.aspectRatio,
        musicPath: removeMusic ? null : musicPath ?? this.musicPath,
        musicName: removeMusic ? null : musicName ?? this.musicName,
        musicVolume: musicVolume ?? this.musicVolume,
        musicOffsetMs: musicOffsetMs ?? this.musicOffsetMs,
        overlays: overlays ?? this.overlays,
        imageOverlays: imageOverlays ?? this.imageOverlays,
      );

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'clips': clips.map((clip) => clip.toJson()).toList(),
        'aspectRatio': aspectRatio,
        'musicPath': musicPath,
        'musicName': musicName,
        'musicVolume': musicVolume,
        'musicOffsetMs': musicOffsetMs,
        'overlays': overlays.map((overlay) => overlay.toJson()).toList(),
        'imageOverlays': imageOverlays.map((overlay) => overlay.toJson()).toList(),
      };

  factory EditProject.fromJson(Map<String, dynamic> json) {
    if ((json['schemaVersion'] as num?)?.toInt() != 1) throw const FormatException('Unsupported project schema version.');
    final clips = (json['clips'] as List<dynamic>).map((item) => EditClip.fromJson(Map<String, dynamic>.from(item as Map))).toList();
    if (clips.isEmpty || clips.any((clip) => clip.path.isEmpty || clip.startMs < 0 || clip.endMs <= clip.startMs || clip.endMs > clip.durationMs)) {
      throw const FormatException('Project contains invalid clips.');
    }
    final overlays = (json['overlays'] as List<dynamic>?)?.map((item) => EditTextOverlay.fromJson(Map<String, dynamic>.from(item as Map))).toList() ?? const <EditTextOverlay>[];
    final imageOverlays = (json['imageOverlays'] as List<dynamic>?)?.map((item) => EditImageOverlay.fromJson(Map<String, dynamic>.from(item as Map))).toList() ?? const <EditImageOverlay>[];
    final project = EditProject(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      clips: clips,
      aspectRatio: json['aspectRatio'] as String? ?? 'Original',
      musicPath: json['musicPath'] as String?,
      musicName: json['musicName'] as String?,
      musicVolume: (json['musicVolume'] as num?)?.toDouble() ?? .35,
      musicOffsetMs: (json['musicOffsetMs'] as num?)?.toInt() ?? 0,
      overlays: overlays,
      imageOverlays: imageOverlays,
    );
    if (!const {'Original', '9:16', '16:9', '1:1', '4:5'}.contains(project.aspectRatio) ||
        project.musicVolume < 0 || project.musicVolume > 1 || project.musicOffsetMs < 0 ||
        project.clips.any((clip) => clip.rotation % 90 != 0 || clip.volume < 0 || clip.volume > 1 || clip.brightness < -.25 || clip.brightness > .25 || clip.contrast < -.3 || clip.contrast > .3 || clip.saturation < -20 || clip.saturation > 30) ||
        overlays.any((overlay) => overlay.text.trim().isEmpty || overlay.startMs < 0 || overlay.endMs <= overlay.startMs || overlay.endMs > project.durationMs || overlay.x < -1 || overlay.x > 1 || overlay.y < -1 || overlay.y > 1 || overlay.fontSize < 16 || overlay.fontSize > 96) ||
        imageOverlays.any((overlay) => overlay.path.isEmpty || overlay.startMs < 0 || overlay.endMs <= overlay.startMs || overlay.endMs > project.durationMs || overlay.x < -1 || overlay.x > 1 || overlay.y < -1 || overlay.y > 1 || overlay.scale < .05 || overlay.scale > 1)) {
      throw const FormatException('Project contains invalid editing settings.');
    }
    return project;
  }
}

String encodeEditProject(EditProject project) => jsonEncode(project.toJson());
