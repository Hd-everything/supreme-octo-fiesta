import 'dart:io';

import 'package:image/image.dart' as img;

class PhotoProcessingResult {
  const PhotoProcessingResult({required this.path, required this.width, required this.height, required this.bytes});
  final String path;
  final int width, height, bytes;
}

/// Conventional, offline pixel enhancement for still images. It changes
/// actual decoded pixels and writes a separate JPEG; it is not described as
/// neural restoration.
class PhotoProcessingService {
  Future<PhotoProcessingResult> process({required String inputPath, required String outputPath, int? targetLongEdge, double brightness = .08, double contrast = .16, double saturation = 8, double sharpness = .2}) async {
    final source = img.decodeImage(await File(inputPath).readAsBytes());
    if (source == null || source.width < 2 || source.height < 2) throw const FormatException('Unsupported or unreadable image.');
    var image = img.adjustColor(source, brightness: brightness * 100, contrast: contrast * 100, saturation: saturation);
    if (sharpness > 0) image = img.convolution(image, filter: [0, -sharpness, 0, -sharpness, 1 + 4 * sharpness, -sharpness, 0, -sharpness, 0]);
    if (targetLongEdge != null && targetLongEdge > 0) {
      final longEdge = image.width > image.height ? image.width : image.height;
      if (longEdge != targetLongEdge) {
        final shortEdge = (image.width < image.height ? image.width : image.height) * targetLongEdge / longEdge;
        image = img.copyResize(image, width: image.width >= image.height ? targetLongEdge : shortEdge.round(), height: image.width >= image.height ? shortEdge.round() : targetLongEdge, interpolation: img.Interpolation.cubic);
      }
    }
    final bytes = await File(outputPath).parent.create(recursive: true).then((_) => File(outputPath).writeAsBytes(img.encodeJpg(image, quality: 94)));
    return PhotoProcessingResult(path: bytes.path, width: image.width, height: image.height, bytes: await bytes.length());
  }
}
