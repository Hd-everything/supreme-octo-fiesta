import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Metadata for the packaged ESPCN model. This is a genuine 3x
/// super-resolution model, not a resize filter. The model expects NCHW RGB
/// tensors in [0,1] and returns a 3x NCHW RGB tensor in [0,1].
class SuperResolutionModelManifest {
  const SuperResolutionModelManifest({
    required this.asset,
    required this.sha256,
    required this.scale,
    required this.inputShape,
    required this.outputShape,
    required this.license,
  });

  final String asset;
  final String sha256;
  final int scale;
  final List<int> inputShape;
  final List<int> outputShape;
  final String license;

  static const packaged = SuperResolutionModelManifest(
    asset: 'assets/models/espcn_x3.tflite',
    sha256: 'e1607d2ce4f02b2f03b74fc5699cf709570e9d3d407dd9e69e9f16806bfd77d54',
    scale: 3,
    inputShape: [1, 3, 64, 64],
    outputShape: [1, 3, 192, 192],
    license: 'Apache-2.0 (ailia-models-tflite ESPCN)',
  );
}

enum SuperResolutionStatus { unavailable, ready, failed }

class SuperResolutionCapability {
  const SuperResolutionCapability({
    required this.status,
    required this.model,
    this.message,
    this.inferenceMs,
  });

  final SuperResolutionStatus status;
  final SuperResolutionModelManifest model;
  final String? message;
  final int? inferenceMs;

  bool get isReady => status == SuperResolutionStatus.ready;
}

/// Owns the single interpreter used by both StatusHD and Movie Player.
///
/// This class intentionally exposes frame-tensor inference rather than
/// pretending that a dimension change is neural restoration. The Android
/// video bridge should feed decoded tiles into [run], then encode the returned
/// tiles. The interpreter is lazily created and can be closed between jobs.
class SuperResolutionModelManager {
  SuperResolutionModelManager({this.manifest = SuperResolutionModelManifest.packaged});

  final SuperResolutionModelManifest manifest;
  Interpreter? _interpreter;
  SuperResolutionCapability? _capability;

  Future<SuperResolutionCapability> capability() async {
    if (_capability != null) return _capability!;
    try {
      final data = await rootBundle.load(manifest.asset);
      final digest = sha256.convert(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)).toString();
      if (digest != manifest.sha256) {
        return _capability = SuperResolutionCapability(status: SuperResolutionStatus.failed, model: manifest, message: 'Packaged model hash did not match the signed manifest.');
      }
      final interpreter = await _load();
      final input = interpreter.getInputTensor(0);
      final output = interpreter.getOutputTensor(0);
      if (!_sameShape(input.shape, manifest.inputShape) || !_sameShape(output.shape, manifest.outputShape)) {
        interpreter.close();
        return _capability = SuperResolutionCapability(status: SuperResolutionStatus.failed, model: manifest, message: 'The packaged model tensor shape is incompatible.');
      }
      final started = DateTime.now();
      run(_zeroTensor(manifest.inputShape));
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      return _capability = SuperResolutionCapability(status: SuperResolutionStatus.ready, model: manifest, inferenceMs: elapsed);
    } catch (error) {
      await close();
      return _capability = SuperResolutionCapability(status: SuperResolutionStatus.unavailable, model: manifest, message: 'Neural runtime unavailable: $error');
    }
  }

  Future<Interpreter> _load() async {
    return _interpreter ??= await Interpreter.fromAsset(manifest.asset, options: InterpreterOptions()..threads = 2);
  }

  /// Runs one RGB NCHW tile. Values must be normalized to [0,1].
  List<dynamic> run(List<dynamic> input) {
    final interpreter = _interpreter;
    if (interpreter == null) throw StateError('Super-resolution interpreter is not initialized.');
    final output = _zeroTensor(manifest.outputShape);
    interpreter.run(input, output);
    return output;
  }

  Future<void> close() async {
    _interpreter?.close();
    _interpreter = null;
  }

  static bool _sameShape(List<int> actual, List<int> expected) => actual.length == expected.length && List.generate(actual.length, (i) => actual[i] == expected[i]).every((value) => value);

  static List<dynamic> _zeroTensor(List<int> shape) {
    if (shape.length == 1) return List<dynamic>.filled(shape.first, 0.0);
    return List<dynamic>.generate(shape.first, (_) => _zeroTensor(shape.sublist(1)));
  }

  static Map<String, dynamic> manifestJson(Uint8List bytes) => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}
