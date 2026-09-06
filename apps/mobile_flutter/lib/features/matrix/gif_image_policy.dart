import 'dart:typed_data';

const maxChatGifBytes = 20 * 1024 * 1024;
const maxChatGifPixels = 4 * 1024 * 1024;

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
