import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:statushd/services/media_processing/photo_processing_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('photo framing center-crops to the requested aspect ratio', () async {
    final directory = await Directory.systemTemp.createTemp('vyntra_photo_test_');
    addTearDown(() => directory.delete(recursive: true));
    final input = File('${directory.path}/source.png');
    await input.writeAsBytes(img.encodePng(img.Image(width: 8, height: 4)));

    final result = await PhotoProcessingService().process(
      inputPath: input.path,
      outputPath: '${directory.path}/square.jpg',
      aspectRatio: 1,
      brightness: 0,
      contrast: 0,
      saturation: 0,
      sharpness: 0,
    );

    expect(result.width, result.height);
    expect(File(result.path).lengthSync(), greaterThan(0));
  });

  test('photo rotation creates a separate portrait output', () async {
    final directory = await Directory.systemTemp.createTemp('vyntra_photo_test_');
    addTearDown(() => directory.delete(recursive: true));
    final input = File('${directory.path}/source.png');
    await input.writeAsBytes(img.encodePng(img.Image(width: 8, height: 4)));

    final result = await PhotoProcessingService().process(
      inputPath: input.path,
      outputPath: '${directory.path}/rotated.jpg',
      quarterTurns: 1,
      brightness: 0,
      contrast: 0,
      saturation: 0,
      sharpness: 0,
    );

    expect(result.width, 4);
    expect(result.height, 8);
  });
}
