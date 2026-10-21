import 'dart:isolate';
import 'dart:io';

import 'package:image/image.dart' as img;

class PhotoProcessingResult {
  const PhotoProcessingResult({required this.path, required this.width, required this.height, required this.bytes});
  final String path;
  final int width, height, bytes;
}

/// Offline photo adjustments. Brightness and contrast are deltas around 0,
/// while saturation is a percentage delta around 0, matching the video UI.
/// Image decoding and pixel work run away from Flutter's UI isolate.
class PhotoProcessingService {
  Future<PhotoProcessingResult> process({
    required String inputPath,
    required String outputPath,
    int? targetLongEdge,
    double brightness = .08,
    double contrast = .16,
    double saturation = 8,
    double sharpness = .2,
    double? aspectRatio,
    int quarterTurns = 0,
  }) async {
    final result = await Isolate.run<Map<String, Object>>(() => _processInIsolate(
          inputPath: inputPath,
          outputPath: outputPath,
          targetLongEdge: targetLongEdge,
          brightness: brightness,
          contrast: contrast,
          saturation: saturation,
          sharpness: sharpness,
          aspectRatio: aspectRatio,
          quarterTurns: quarterTurns,
        ));
    return PhotoProcessingResult(
      path: result['path']! as String,
      width: result['width']! as int,
      height: result['height']! as int,
      bytes: result['bytes']! as int,
    );
  }
}

Map<String, Object> _processInIsolate({
  required String inputPath,
  required String outputPath,
  required int? targetLongEdge,
  required double brightness,
  required double contrast,
  required double saturation,
  required double sharpness,
  required double? aspectRatio,
  required int quarterTurns,
}) {
  final source = img.decodeImage(File(inputPath).readAsBytesSync());
  if (source == null || source.width < 2 || source.height < 2) {
    throw const FormatException('Unsupported or unreadable image.');
  }

  var image = source.exif.imageIfd.hasOrientation ? img.bakeOrientation(source) : source;
  final normalizedTurns = quarterTurns % 4;
  if (normalizedTurns != 0) image = img.copyRotate(image, angle: normalizedTurns * 90);

  if (aspectRatio != null && aspectRatio > 0) {
    final ratio = image.width / image.height;
    if (ratio > aspectRatio) {
      final width = (image.height * aspectRatio).round().clamp(1, image.width).toInt();
      image = img.copyCrop(image, x: (image.width - width) ~/ 2, y: 0, width: width, height: image.height);
    } else if (ratio < aspectRatio) {
      final height = (image.width / aspectRatio).round().clamp(1, image.height).toInt();
      image = img.copyCrop(image, x: 0, y: (image.height - height) ~/ 2, width: image.width, height: height);
    }
  }

  // Resize before per-pixel filters so a smaller export does not sharpen and
  // allocate several full-resolution working copies unnecessarily.
  if (targetLongEdge != null && targetLongEdge > 0) {
    final longEdge = image.width > image.height ? image.width : image.height;
    if (longEdge != targetLongEdge) {
      final shortEdge = ((image.width < image.height ? image.width : image.height) * targetLongEdge / longEdge).round().clamp(1, 16384).toInt();
      image = img.copyResize(
        image,
        width: image.width >= image.height ? targetLongEdge : shortEdge,
        height: image.width >= image.height ? shortEdge : targetLongEdge,
        interpolation: img.Interpolation.cubic,
      );
    }
  }

  image = img.adjustColor(
    image,
    brightness: (1 + brightness).clamp(0, 1000),
    contrast: (1 + contrast).clamp(0, 2),
    saturation: (1 + saturation / 100).clamp(0, 1000),
  );
  if (sharpness > 0) {
    image = img.convolution(image, filter: [0, -sharpness, 0, -sharpness, 1 + 4 * sharpness, -sharpness, 0, -sharpness, 0]);
  }

  final output = File(outputPath);
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(img.encodeJpg(image, quality: 94));
  return <String, Object>{'path': output.path, 'width': image.width, 'height': image.height, 'bytes': output.lengthSync()};
}
