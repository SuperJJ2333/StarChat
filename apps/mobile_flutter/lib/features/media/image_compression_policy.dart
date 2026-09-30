import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import '../matrix/gif_image_policy.dart';

const maxUnifiedImageBytes = 500 * 1024;
const maxUnifiedImageEdge = 1080;
const maxUnifiedGifFrames = 256;
const maxUnifiedGifCollectedRgbaBytes = 8 * 1024 * 1024;
// Conservative accounted RGBA allocation bound, not a process RSS promise.
// Native codec internals, input/output container bytes and runtime overhead
// remain additional to this estimate and the independent container limits.
const maxUnifiedGifWorkingBytes = 64 * 1024 * 1024;

const _tooLarge = FormatException('图片无法压缩到 500KB，请选择尺寸更小或帧数更少的图片');
const _broken = FormatException('图片文件已损坏，请重新选择');

/// Initial intake only. Compliant output is reused byte-for-byte on forwarding,
/// collection and retry. No session, image or completed Future is cached here.
abstract final class ImageCompressionPolicy {
  static Future<(int, int)> dimensions(Uint8List bytes) async {
    final gif = gifDimensions(bytes);
    if (gif != null) return gif;
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return (descriptor.width, descriptor.height);
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  static Future<Uint8List> prepare(Uint8List bytes,
      {Future<Uint8List> Function(Uint8List)? transform}) async {
    if (bytes.length >= 3 &&
        bytes[0] == 71 &&
        bytes[1] == 73 &&
        bytes[2] == 70) {
      if (!isGifBytes(bytes)) throw _broken;
      final metadata = await compute(_gifMetadata, bytes);
      if (bytes.length <= maxUnifiedImageBytes) return bytes;
      return _compressGif(bytes, metadata);
    }
    if (transform != null) {
      final result = await transform(bytes);
      if (result.length > maxUnifiedImageBytes) throw _tooLarge;
      return result;
    }
    if (bytes.length > maxChatGifBytes) throw _tooLarge;
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > 16 * 1024 * 1024) {
        throw _tooLarge;
      }
      if (bytes.length <= maxUnifiedImageBytes &&
          math.max(descriptor.width, descriptor.height) <=
              maxUnifiedImageEdge) {
        return bytes;
      }
      final dimensions =
          _fit(descriptor.width, descriptor.height, maxUnifiedImageEdge);
      final codec = await descriptor.instantiateCodec(
          targetWidth: dimensions.$1, targetHeight: dimensions.$2);
      try {
        if (codec.frameCount != 1) {
          throw const FormatException('请使用 GIF 格式发送动画图片');
        }
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image
              .toByteData(format: ui.ImageByteFormat.rawStraightRgba);
          if (data == null) throw _broken;
          return compute(_encodeStatic, (
            data.buffer.asUint8List(),
            frame.image.width,
            frame.image.height
          ));
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw _broken;
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}

(int, int) _fit(int width, int height, int edge) {
  final ratio = math.min(1.0, edge / math.max(width, height));
  return (
    math.max(1, (width * ratio).floor()),
    math.max(1, (height * ratio).floor())
  );
}

/// Container metadata only, after the authoritative structural/budget scan.
/// Delays use the original centisecond values (native codecs may clamp them).
({List<int> delays, int? loops}) _gifMetadata(Uint8List bytes) {
  validateGifStructureForSend(bytes);
  var offset = 13;
  if (bytes[10] & 128 != 0) offset += 3 * (1 << ((bytes[10] & 7) + 1));
  final delays = <int>[];
  int? loops;
  var delay = 0;
  while (bytes[offset] != 59) {
    final marker = bytes[offset++];
    if (marker == 33) {
      final label = bytes[offset++];
      final start = offset;
      if (label == 249 && bytes[offset] == 4) {
        delay = bytes[offset + 2] | (bytes[offset + 3] << 8);
      }
      if (label == 255 &&
          bytes[offset] == 11 &&
          ['NETSCAPE2.0', 'ANIMEXTS1.0'].contains(
              String.fromCharCodes(bytes.sublist(offset + 1, offset + 12))) &&
          bytes.length > offset + 17 &&
          bytes[offset + 12] == 3 &&
          bytes[offset + 13] == 1) {
        loops = bytes[offset + 14] | (bytes[offset + 15] << 8);
      }
      offset = start;
    } else {
      final packed = bytes[offset + 8];
      offset += 9;
      if (packed & 128 != 0) offset += 3 * (1 << ((packed & 7) + 1));
      offset++; // LZW minimum code size; never decode it in Dart.
      delays.add(delay);
      delay = 0;
      if (delays.length > maxUnifiedGifFrames) {
        throw const FormatException('GIF 超过 256 帧，请选择较短的动图');
      }
    }
    while (bytes[offset] != 0) {
      offset += bytes[offset] + 1;
    }
    offset++;
  }
  return (delays: delays, loops: loops);
}

Future<Uint8List> _compressGif(
    Uint8List bytes, ({List<int> delays, int? loops}) metadata) async {
  final canvas = gifDimensions(bytes)!;
  var dimensions = _fit(canvas.$1, canvas.$2, 640);
  // Conservative RGBA bound: three original native canvases, two copies of
  // collected scaled frames across compute, plus two current scaled canvases.
  int workingBytes() =>
      canvas.$1 * canvas.$2 * 12 +
      dimensions.$1 * dimensions.$2 * 8 * (metadata.delays.length + 1);
  while (workingBytes() > maxUnifiedGifWorkingBytes ||
      dimensions.$1 * dimensions.$2 * 4 * metadata.delays.length >
          maxUnifiedGifCollectedRgbaBytes) {
    if (dimensions == (1, 1)) throw _tooLarge;
    dimensions =
        (math.max(1, dimensions.$1 ~/ 2), math.max(1, dimensions.$2 ~/ 2));
  }
  for (var attempt = 0; attempt < 8; attempt++) {
    ui.Codec? codec;
    final frames = <Uint8List>[];
    try {
      codec = await ui.instantiateImageCodec(bytes,
          targetWidth: dimensions.$1,
          targetHeight: dimensions.$2,
          allowUpscaling: false);
      if (codec.frameCount != metadata.delays.length) throw _broken;
      for (var index = 0; index < codec.frameCount; index++) {
        final frame = await codec.getNextFrame();
        ui.Image? scaled;
        try {
          // Some native GIF codecs ignore target dimensions. Resize the
          // composited native frame before requesting a Dart RGBA buffer.
          var image = frame.image;
          if (image.width != dimensions.$1 || image.height != dimensions.$2) {
            final recorder = ui.PictureRecorder();
            final canvas = ui.Canvas(recorder);
            canvas.drawImageRect(
                image,
                ui.Rect.fromLTWH(
                    0, 0, image.width.toDouble(), image.height.toDouble()),
                ui.Rect.fromLTWH(
                    0, 0, dimensions.$1.toDouble(), dimensions.$2.toDouble()),
                ui.Paint()..filterQuality = ui.FilterQuality.medium);
            final picture = recorder.endRecording();
            try {
              scaled = await picture.toImage(dimensions.$1, dimensions.$2);
            } finally {
              picture.dispose();
            }
            image = scaled;
          }
          final data = await image.toByteData(
              format: ui.ImageByteFormat.rawStraightRgba);
          if (data == null) throw _broken;
          frames.add(data.buffer.asUint8List());
        } finally {
          scaled?.dispose();
          frame.image.dispose();
        }
      }
      final result = await compute(_encodeGif, (
        frames,
        dimensions.$1,
        dimensions.$2,
        metadata.delays,
        metadata.loops
      ));
      if (result != null) return result;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw _broken;
    } finally {
      frames.clear();
      codec?.dispose();
    }
    if (dimensions == (1, 1)) break;
    dimensions =
        (math.max(1, dimensions.$1 ~/ 2), math.max(1, dimensions.$2 ~/ 2));
  }
  throw _tooLarge;
}

Uint8List? _encodeGif((List<Uint8List>, int, int, List<int>, int?) input) {
  for (final levels in [6, 5, 4, 3]) {
    final encoder = img.GifEncoder(repeat: input.$5 ?? 0, dispose: 2);
    for (var index = 0; index < input.$1.length; index++) {
      // Native frames are already disposal-composited full canvases. Explicit
      // indexed RGBA avoids RGB-only quantizers destroying transparency.
      final image = img.Image(
          width: input.$2, height: input.$3, numChannels: 4, withPalette: true);
      image.palette!.setRgba(0, 0, 0, 0, 0);
      for (var r = 0; r < levels; r++) {
        for (var g = 0; g < levels; g++) {
          for (var b = 0; b < levels; b++) {
            image.palette!.setRgba(
                1 + (r * levels + g) * levels + b,
                r * 255 ~/ (levels - 1),
                g * 255 ~/ (levels - 1),
                b * 255 ~/ (levels - 1),
                255);
          }
        }
      }
      final rgba = input.$1[index];
      for (final pixel in image) {
        final offset = (pixel.y * input.$2 + pixel.x) * 4;
        pixel.index = rgba[offset + 3] < 128
            ? 0
            : 1 +
                ((rgba[offset] * (levels - 1) + 127) ~/ 255 * levels +
                        (rgba[offset + 1] * (levels - 1) + 127) ~/ 255) *
                    levels +
                (rgba[offset + 2] * (levels - 1) + 127) ~/ 255;
      }
      encoder.addFrame(image, duration: input.$4[index]);
      // Bound output growth as well as decoded working memory. Abandon the
      // attempt as soon as its already-encoded frames exceed the final cap.
      if ((encoder.output?.length ?? 0) > maxUnifiedImageBytes) break;
      if (index == input.$1.length - 1) {
        var result = encoder.finish()!;
        if (input.$5 == null) {
          result = Uint8List.fromList(
              [...result.sublist(0, 13), ...result.sublist(32)]);
        }
        if (result.length <= maxUnifiedImageBytes) return result;
      }
    }
  }
  return null;
}

Uint8List _encodeStatic((Uint8List, int, int) input) {
  var image = img.Image.fromBytes(
      width: input.$2,
      height: input.$3,
      bytes: input.$1.buffer,
      numChannels: 4);
  final alpha = image.any((pixel) => pixel.a < 255);
  for (var attempt = 0; attempt < 8; attempt++) {
    for (final quality in [85, 70, 50]) {
      final result =
          alpha ? img.encodePng(image) : img.encodeJpg(image, quality: quality);
      if (result.length <= maxUnifiedImageBytes) return result;
      if (alpha) break;
    }
    if (image.width == 1 && image.height == 1) break;
    image = img.copyResize(image,
        width: math.max(1, image.width ~/ 2),
        height: math.max(1, image.height ~/ 2));
  }
  throw _tooLarge;
}
