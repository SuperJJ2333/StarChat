import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_extractor.dart';
import 'package:liuhetong_mobile/features/moments/moment_publish_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File video;
  late Uint8List whiteFrame;
  late FlutterImageCompressPlatform previousCompressor;
  late _Compressor compressor;

  setUpAll(() async {
    root = await Directory(
            '../../docs/verification/artifacts/2026-09-29/android-2191-followup/poster-policy/unit')
        .create(recursive: true);
    video = File('${root.path}/source.mp4');
    await video.writeAsBytes([1, 2, 3]);
    whiteFrame = await _whitePng();
  });
  setUp(() {
    previousCompressor = FlutterImageCompressPlatform.instance;
    compressor = _Compressor();
    FlutterImageCompressPlatform.instance = compressor;
  });
  tearDown(() {
    FlutterImageCompressPlatform.instance = previousCompressor;
  });

  test('video first frame takes priority over a selected-source preview',
      () async {
    List<int>? positions;
    final output = await prepareMomentVideoPoster(video,
        source: Uint8List.fromList([1, 2, 3]),
        extract: (file, requested) async {
      expect(file.path, video.path);
      positions = requested;
      return whiteFrame;
    });

    expect(positions, [0, 200, 500, 1000, 2000]);
    expect(compressor.inputs.single, whiteFrame);
    expect(compressor.formats.single, CompressFormat.jpeg);
    expect(output, compressor.output);
  });

  test('extractor tries later positions when the first frames are absent',
      () async {
    final attempted = <int>[];
    final output = await prepareMomentVideoPoster(video,
        extract: (file, positions) => extractVideoPoster(file.path,
                positionsMs: positions, fetch: (_, position) async {
              attempted.add(position);
              return position == 2000 ? whiteFrame : null;
            }));

    expect(attempted, [0, 200, 500, 1000, 2000]);
    expect(output, compressor.output);
  });

  test('invalid nonempty zero-millisecond frame tries a later valid frame',
      () async {
    final attempted = <int>[];
    final output = await prepareMomentVideoPoster(video,
        extract: (file, positions) => extractVideoPoster(file.path,
                positionsMs: positions, fetch: (_, position) async {
              attempted.add(position);
              return position == 0 ? Uint8List.fromList([1, 2, 3]) : whiteFrame;
            }));

    expect(attempted, [0, 200]);
    expect(compressor.inputs.single, whiteFrame);
    expect(output, compressor.output);
  });

  test('oversized zero-millisecond frame tries a later valid frame', () async {
    final attempted = <int>[];
    final hugeFrame = _withPngDimensions(whiteFrame, 4097, 4097);
    final output = await prepareMomentVideoPoster(video,
        extract: (file, positions) => extractVideoPoster(file.path,
                positionsMs: positions, fetch: (_, position) async {
              attempted.add(position);
              return position == 0 ? hugeFrame : whiteFrame;
            }));

    expect(attempted, [0, 200]);
    expect(compressor.inputs.single, whiteFrame);
    expect(output, compressor.output);
  });

  test('unusable extracted first frame retries later frames before preview',
      () async {
    compressor.failFirst = true;
    final attempts = <List<int>>[];
    final output = await prepareMomentVideoPoster(video,
        source: Uint8List.fromList([1, 2, 3]), extract: (_, positions) async {
      attempts.add(positions);
      return whiteFrame;
    });

    expect(attempts, [
      [0, 200, 500, 1000, 2000],
      [200, 500, 1000, 2000]
    ]);
    expect(compressor.inputs, [whiteFrame, whiteFrame]);
    expect(output, compressor.output);
  });

  test('700 KiB encoded frame may compress below the poster limit', () async {
    final paddedFrame = _paddedPng(whiteFrame, 700 * 1024);
    expect(paddedFrame.length, greaterThan(512 * 1024));

    final output = await prepareMomentVideoPoster(video,
        extract: (_, __) async => paddedFrame);

    expect(compressor.inputs.single, paddedFrame);
    expect(output, compressor.output);
    expect(output!.length, lessThanOrEqualTo(512 * 1024));
  });

  test('image metadata over sixteen million pixels is rejected before decode',
      () async {
    final hugeFrame = _withPngDimensions(whiteFrame, 4097, 4097);
    final buffer = await ui.ImmutableBuffer.fromUint8List(hugeFrame);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    expect(descriptor.width * descriptor.height, greaterThan(16 * 1024 * 1024));
    descriptor.dispose();
    buffer.dispose();

    final output = await prepareMomentVideoPoster(video,
        extract: (_, __) async => hugeFrame);

    expect(output, isNull);
    expect(compressor.inputs, isEmpty);
  });

  test('selected video preview is used only when extraction has no frame',
      () async {
    final output = await prepareMomentVideoPoster(video,
        source: whiteFrame, extract: (_, __) async => null);

    expect(compressor.inputs.single, whiteFrame);
    expect(output, compressor.output);
    expect(
        await prepareMomentVideoPoster(video, extract: (_, __) async => null),
        isNull);
  });
}

Future<Uint8List> _whitePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      ui.Paint()
        ..color = const ui.Color(0xffffffff)
        ..style = ui.PaintingStyle.fill);
  final picture = recorder.endRecording();
  final image = await picture.toImage(1, 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Uint8List _paddedPng(Uint8List png, int padBytes) {
  final data = Uint8List(padBytes);
  data[0] = 107; // tEXt keyword: k
  data[1] = 0;
  final chunk = _pngChunk('tEXt', data);
  return Uint8List.fromList(
      [...png.sublist(0, 33), ...chunk, ...png.sublist(33)]);
}

Uint8List _withPngDimensions(Uint8List png, int width, int height) {
  final edited = Uint8List.fromList(png);
  final header = ByteData.sublistView(edited);
  header.setUint32(16, width);
  header.setUint32(20, height);
  header.setUint32(29, _crc32(edited.sublist(12, 29)));
  return edited;
}

Uint8List _pngChunk(String type, Uint8List data) {
  final typeBytes = ascii.encode(type);
  final chunk = Uint8List(12 + data.length);
  final header = ByteData.sublistView(chunk);
  header.setUint32(0, data.length);
  chunk.setRange(4, 8, typeBytes);
  chunk.setRange(8, 8 + data.length, data);
  header.setUint32(8 + data.length, _crc32(chunk.sublist(4, 8 + data.length)));
  return chunk;
}

int _crc32(List<int> bytes) {
  var value = 0xffffffff;
  for (final byte in bytes) {
    value ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) != 0 ? (value >> 1) ^ 0xedb88320 : value >> 1;
    }
  }
  return value ^ 0xffffffff;
}

final class _Compressor extends FlutterImageCompressPlatform {
  final inputs = <Uint8List>[];
  final formats = <CompressFormat>[];
  final output = Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]);
  bool failFirst = false;

  @override
  Future<Uint8List> compressWithList(Uint8List image,
      {int minWidth = 1920,
      int minHeight = 1080,
      int quality = 95,
      int rotate = 0,
      int inSampleSize = 1,
      bool autoCorrectionAngle = true,
      CompressFormat format = CompressFormat.jpeg,
      bool keepExif = false}) async {
    expect(minWidth, lessThanOrEqualTo(480));
    expect(minHeight, lessThanOrEqualTo(480));
    inputs.add(image);
    formats.add(format);
    if (failFirst && inputs.length == 1) throw const FormatException();
    return output;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected compressor operation');
}
