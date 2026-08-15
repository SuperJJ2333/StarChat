import 'dart:io';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'profile_controller.dart';

final class GalleryAvatarSource implements AvatarSource {
  GalleryAvatarSource({ImagePicker? picker, ImageCropper? cropper})
      : picker = picker ?? ImagePicker(),
        cropper = cropper ?? ImageCropper();
  final ImagePicker picker;
  final ImageCropper cropper;
  @override
  Future<AvatarCandidate?> selectCropAndCompress() async {
    final selected =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 92);
    if (selected == null) return null;
    final cropped = await cropper.cropImage(
        sourcePath: selected.path,
        aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
        compressFormat: ImageCompressFormat.jpg,
        compressQuality: 88,
        uiSettings: [
          AndroidUiSettings(lockAspectRatio: true, hideBottomControls: false),
          IOSUiSettings(
              aspectRatioLockEnabled: true, resetAspectRatioEnabled: false)
        ]);
    if (cropped == null) return null;
    return AvatarCandidate(
        bytes: await File(cropped.path).readAsBytes(), mimeType: 'image/jpeg');
  }
}
