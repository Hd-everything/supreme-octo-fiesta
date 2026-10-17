import 'dart:io';

import 'package:flutter/services.dart';

import 'super_resolution_model.dart';
import 'processing_job_queue.dart';

/// Typed contract shared by StatusHD Studio and Movie Player. UI code never
/// builds native filter arguments directly.
class VideoMetadata {
  const VideoMetadata({
    required this.width,
    required this.height,
    required this.duration,
    required this.fileSize,
    required this.rotation,
  });

  final int width;
  final int height;
  final Duration duration;
  final int fileSize;
  final int rotation;

  bool get isValid => width >= 2 && height >= 2;
  int get longEdge => width > height ? width : height;
  int get shortEdge => width < height ? width : height;

  factory VideoMetadata.fromMap(Map<dynamic, dynamic> map) => VideoMetadata(
        width: (map['width'] as num?)?.toInt() ?? 0,
        height: (map['height'] as num?)?.toInt() ?? 0,
        duration: Duration(milliseconds: (map['durationMs'] as num?)?.toInt() ?? 0),
        fileSize: (map['fileSize'] as num?)?.toInt() ?? 0,
        rotation: (map['rotation'] as num?)?.toInt() ?? 0,
      );
}

enum OutputResolution { original, p720, p1080, p1440 }

enum EnhancementStrength { gentle, balanced, strong }

class EnhancementConfiguration {
  const EnhancementConfiguration({
    this.resolution = OutputResolution.p1080,
    this.strength = EnhancementStrength.balanced,
    this.brightness = 0.09,
    this.contrast = 0.18,
    this.saturation = 14,
    this.sharpness = 0.22,
    this.noiseReduction = 0,
    this.outputWidth,
    this.outputHeight,
  });

  final OutputResolution resolution;
  final EnhancementStrength strength;
  final double brightness;
  final double contrast;
  final double saturation;
  final double sharpness;
  final double noiseReduction;
  final int? outputWidth;
  final int? outputHeight;

  EnhancementConfiguration reset() => const EnhancementConfiguration();
}

class CropConfiguration {
  const CropConfiguration({required this.aspectRatio, this.x = 0, this.y = 0, this.width = 1, this.height = 1});

  final double? aspectRatio;
  final double x;
  final double y;
  final double width;
  final double height;

  bool get isNormalizedAndValid => x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1;

  factory CropConfiguration.centeredFor(VideoMetadata source, double? aspectRatio) {
    if (aspectRatio == null || aspectRatio <= 0) return const CropConfiguration(aspectRatio: null);
    final sourceRatio = source.width / source.height;
    if (sourceRatio > aspectRatio) {
      final width = aspectRatio / sourceRatio;
      return CropConfiguration(aspectRatio: aspectRatio, x: (1 - width) / 2, width: width);
    }
    final height = sourceRatio / aspectRatio;
    return CropConfiguration(aspectRatio: aspectRatio, y: (1 - height) / 2, height: height);
  }
}

class ProcessingRequest {
  const ProcessingRequest.enhance({required this.inputPath, required this.outputPath, required this.metadata, required this.enhancement})
      : crop = null;

  const ProcessingRequest.crop({required this.inputPath, required this.outputPath, required this.metadata, required this.crop})
      : enhancement = null;

  final String inputPath;
  final String outputPath;
  final VideoMetadata metadata;
  final EnhancementConfiguration? enhancement;
  final CropConfiguration? crop;

  bool get isEnhancement => enhancement != null;
}

class ProcessingResult {
  const ProcessingResult({required this.path, required this.metadata});
  final String path;
  final VideoMetadata metadata;
}

class ProcessingValidationException implements Exception {
  const ProcessingValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class VideoProcessingService {
  VideoProcessingService({MethodChannel? channel, SuperResolutionModelManager? superResolution, ProcessingJobQueue? jobs})
      : _channel = channel ?? const MethodChannel('com.ptip.statushd/media'),
        _superResolution = superResolution ?? SuperResolutionModelManager(),
        _jobs = jobs;
  final MethodChannel _channel;
  final SuperResolutionModelManager _superResolution;
  final ProcessingJobQueue? _jobs;

  /// Checks the packaged model and runs one real representative inference.
  /// The result is intentionally separate from conventional video processing;
  /// callers must not label a resize as neural restoration.
  Future<SuperResolutionCapability> neuralCapability() => _superResolution.capability();

  Future<Map<String, dynamic>> nativeNeuralCapability() async =>
      (await _channel.invokeMapMethod<String, dynamic>('neuralSuperResolutionCapability')) ?? const <String, dynamic>{'ready': false};

  Future<void> closeNeuralRuntime() => _superResolution.close();

  Future<VideoMetadata> inspect(String path) async {
    final result = await _channel.invokeMapMethod<String, dynamic>('inspectVideo', {'inputPath': path});
    if (result == null) throw const ProcessingValidationException('This video could not be inspected.');
    final metadata = VideoMetadata.fromMap(result);
    if (!metadata.isValid) throw const ProcessingValidationException('This video has invalid dimensions.');
    return metadata;
  }

  ({int width, int height}) outputSize(VideoMetadata source, OutputResolution resolution) {
    final target = switch (resolution) {
      OutputResolution.original => source.longEdge,
      OutputResolution.p720 => 1280,
      OutputResolution.p1080 => 1920,
      OutputResolution.p1440 => 2560,
    };
    final short = (source.shortEdge * target / source.longEdge).round().clamp(2, 4096).toInt();
    return source.width >= source.height ? (width: target, height: short) : (width: short, height: target);
  }

  void validate(ProcessingRequest request) {
    if (!request.metadata.isValid) throw const ProcessingValidationException('The source dimensions are not supported.');
    if (request.metadata.duration.inMilliseconds <= 0) throw const ProcessingValidationException('The source duration could not be read.');
    if (!File(request.inputPath).isFileSync()) throw const ProcessingValidationException('The source video is no longer available.');
    if (request.enhancement case final config?) {
      if (config.brightness < -.25 || config.brightness > .25 || config.contrast < -.3 || config.contrast > .3 || config.saturation < -20 || config.saturation > 30 || config.sharpness < 0 || config.sharpness > .5) {
        throw const ProcessingValidationException('One or more picture adjustments are outside the supported range.');
      }
    }
    if (request.crop case final crop?) {
      if (!crop.isNormalizedAndValid) throw const ProcessingValidationException('The crop area must remain inside the video frame.');
    }
  }

  Future<ProcessingResult> process(ProcessingRequest request) async {
    validate(request);
    final jobId = 'job_${DateTime.now().microsecondsSinceEpoch}';
    final job = ProcessingJob(id: jobId, inputPath: request.inputPath, outputPath: request.outputPath, operation: request.isEnhancement ? 'enhancement' : 'crop', createdAt: DateTime.now());
    await _jobs?.add(job);
    await _jobs?.update(jobId, state: ProcessingJobState.preparing, message: 'Preparing source metadata');
    final payload = <String, Object>{
      'inputPath': request.inputPath,
      'outputPath': request.outputPath,
      'operation': request.isEnhancement ? 'enhance' : 'crop',
    };
    if (request.enhancement case final config?) {
      final size = config.outputWidth != null && config.outputHeight != null
          ? (width: config.outputWidth!, height: config.outputHeight!)
          : outputSize(request.metadata, config.resolution);
      payload.addAll({
        'outputWidth': size.width,
        'outputHeight': size.height,
        'brightness': config.brightness,
        'contrast': config.contrast,
        'saturation': config.saturation,
        'sharpness': config.sharpness,
        'noiseReduction': config.noiseReduction,
      });
    }
    if (request.crop case final crop?) {
      payload.addAll({'cropX': crop.x, 'cropY': crop.y, 'cropWidth': crop.width, 'cropHeight': crop.height, 'cropAspectRatio': crop.aspectRatio ?? 0});
    }
    try {
      await _jobs?.update(jobId, state: ProcessingJobState.decoding, message: 'Decoding frames');
      await _jobs?.update(jobId, state: ProcessingJobState.enhancing, message: request.isEnhancement ? 'Applying enhancement' : 'Applying crop');
      final result = await _channel.invokeMapMethod<String, dynamic>('processVideo', payload);
      await _jobs?.update(jobId, state: ProcessingJobState.encoding, message: 'Encoding output');
      final path = result?['path']?.toString();
      if (path == null || !File(path).isFile || await File(path).length() == 0) throw const ProcessingValidationException('Processing did not create a readable output file.');
      await _jobs?.update(jobId, state: ProcessingJobState.verifying, message: 'Verifying output');
      final metadata = await inspect(path);
      await _jobs?.update(jobId, state: ProcessingJobState.complete, progress: 1, message: 'Complete');
      return ProcessingResult(path: path, metadata: metadata);
    } catch (error) {
      await _jobs?.update(jobId, state: ProcessingJobState.failed, message: 'Processing failed', error: error.toString());
      rethrow;
    }
  }

  Future<void> cancel() => _channel.invokeMethod<void>('cancelProcessing');
}
