import 'package:flutter_test/flutter_test.dart';
import 'package:statushd/services/media_processing/video_processing_service.dart';

void main() {
  const landscape = VideoMetadata(
    width: 1920,
    height: 1080,
    duration: Duration(seconds: 30),
    fileSize: 1024,
    rotation: 0,
  );
  const portrait = VideoMetadata(
    width: 1080,
    height: 1920,
    duration: Duration(seconds: 30),
    fileSize: 1024,
    rotation: 0,
  );

  test('preserves orientation while calculating output resolution', () {
    final service = VideoProcessingService();
    expect(service.outputSize(landscape, OutputResolution.p720), (width: 1280, height: 720));
    expect(service.outputSize(portrait, OutputResolution.p1080), (width: 1080, height: 1920));
  });

  test('rejects crop rectangles outside the visible source frame', () {
    final request = ProcessingRequest.crop(
      inputPath: 'missing.mp4',
      outputPath: 'out.mp4',
      metadata: landscape,
      crop: const CropConfiguration(aspectRatio: 1, x: .8, y: 0, width: .3, height: 1),
    );
    expect(() => VideoProcessingService().validate(request), throwsA(isA<ProcessingValidationException>()));
  });

  test('parses inspected metadata safely', () {
    final metadata = VideoMetadata.fromMap({'width': 720, 'height': 1280, 'durationMs': 8000, 'fileSize': 42, 'rotation': 90});
    expect(metadata.isValid, isTrue);
    expect(metadata.duration, const Duration(seconds: 8));
    expect(metadata.longEdge, 1280);
  });
}
