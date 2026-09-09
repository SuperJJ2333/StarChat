import 'dart:typed_data';

const maxChatGifBytes = 20 * 1024 * 1024;
const maxChatGifPixels = 4 * 1024 * 1024;
const maxChatGifDecodedPixels = 128 * 1024 * 1024;

bool isGifBytes(Uint8List bytes) =>
    bytes.length >= 6 &&
    bytes[0] == 71 &&
    bytes[1] == 73 &&
    bytes[2] == 70 &&
    bytes[3] == 56 &&
    (bytes[4] == 55 || bytes[4] == 57) &&
    bytes[5] == 97;

/// Read logical canvas dimensions without allocating a decoded animation.
(int, int)? gifDimensions(Uint8List bytes) {
  if (!isGifBytes(bytes) || bytes.length < 10) return null;
  final width = bytes[6] | (bytes[7] << 8);
  final height = bytes[8] | (bytes[9] << 8);
  return width > 0 && height > 0 ? (width, height) : null;
}

void validateGifForSend(Uint8List bytes) {
  if (!isGifBytes(bytes)) return;
  final dimensions = gifDimensions(bytes);
  if (dimensions == null ||
      bytes.length > maxChatGifBytes ||
      dimensions.$1 * dimensions.$2 > maxChatGifPixels) {
    throw const FormatException('GIF 过大，请选择不超过 20MB、400 万像素的动图');
  }
}

/// Scan the container without allocating frames. Decode work is measured on
/// the composited logical canvas, including optimized small frame rectangles.
/// Codec validation of compressed pixel data remains the decoder's job.
void validateGifStructureForSend(Uint8List bytes) {
  if (!isGifBytes(bytes)) return;
  validateGifForSend(bytes);
  const malformed = FormatException('GIF 文件已损坏，请重新选择');
  if (bytes.length < 13) throw malformed;
  final canvas = gifDimensions(bytes)!;
  var offset = 13;
  var frames = 0;
  void skip(int length) {
    if (length < 0 || offset + length > bytes.length) throw malformed;
    offset += length;
  }

  int byte() {
    if (offset >= bytes.length) throw malformed;
    return bytes[offset++];
  }

  int wordAt(int index) => bytes[index] | (bytes[index + 1] << 8);
  bool blocks() {
    var hasData = false;
    while (true) {
      final count = byte();
      if (count == 0) return hasData;
      hasData = true;
      skip(count);
    }
  }

  if ((bytes[10] & 128) != 0) skip(3 * (1 << ((bytes[10] & 7) + 1)));
  while (offset < bytes.length) {
    final marker = byte();
    if (marker == 59) {
      if (frames == 0 || offset != bytes.length) throw malformed;
      return;
    }
    if (marker == 33) {
      byte(); // Extension label; remaining payload is length-prefixed blocks.
      blocks();
      continue;
    }
    if (marker != 44 || offset + 9 > bytes.length) throw malformed;
    final left = wordAt(offset);
    final top = wordAt(offset + 2);
    final width = wordAt(offset + 4);
    final height = wordAt(offset + 6);
    final packed = bytes[offset + 8];
    if (width == 0 ||
        height == 0 ||
        left + width > canvas.$1 ||
        top + height > canvas.$2) {
      throw malformed;
    }
    frames++;
    if (canvas.$1 * canvas.$2 * frames > maxChatGifDecodedPixels) {
      throw const FormatException('GIF 动画过长或过大，请选择较小的动图');
    }
    skip(9);
    if ((packed & 128) != 0) skip(3 * (1 << ((packed & 7) + 1)));
    final codeSize = byte();
    if (codeSize < 2 || codeSize > 8 || !blocks()) throw malformed;
  }
  throw malformed; // Every complete GIF has a trailer after its frames.
}
