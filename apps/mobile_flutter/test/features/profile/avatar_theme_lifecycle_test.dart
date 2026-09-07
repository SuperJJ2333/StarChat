import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:liuhetong_mobile/features/profile/avatar_source.dart';

class DeferredPicker extends ImagePicker {
  final result = Completer<XFile?>();
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) =>
      result.future;
}

void main() {
  test('avatar source reads page theme before native picker awaits', () async {
    final picker = DeferredPicker();
    var mounted = true;
    var reads = 0;
    final source = GalleryAvatarSource(
        picker: picker,
        brightnessProvider: () {
          expect(mounted, isTrue);
          reads++;
          return Brightness.dark;
        });
    final operation = source.selectCropAndCompress();
    expect(reads, 1);
    mounted = false;
    picker.result.complete(null);
    expect(await operation, isNull);
    expect(reads, 1);
  });
}
