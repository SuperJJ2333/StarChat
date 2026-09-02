import 'dart:io';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import '../../ui/foundation/wechat_tokens.dart';
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
          // 面向全面屏（刘海/灵动岛/手势条）：给系统栏显式的不透明主题色，
          // 确认与退出控件落在工具栏/底部控制区内，不被状态栏或手势条遮挡；
          // 非全面屏设备无 insets，布局保持不变。
          AndroidUiSettings(
            lockAspectRatio: true,
            hideBottomControls: false,
            toolbarTitle: '裁剪头像',
            toolbarColor: WeChatColors.chatNavigationBackground,
            toolbarWidgetColor: WeChatColors.lightTextPrimary,
            // 9.x 在浅色系统栏下保证工具栏图标可见；insets 由插件处理，
            // 确认/退出控件不会被状态栏或手势条遮挡。
            statusBarLight: true,
            navBarLight: true,
            activeControlsWidgetColor: WeChatColors.brandPrimary,
          ),
          IOSUiSettings(
              aspectRatioLockEnabled: true, resetAspectRatioEnabled: false)
        ]);
    if (cropped == null) return null;
    return AvatarCandidate(
        bytes: await File(cropped.path).readAsBytes(), mimeType: 'image/jpeg');
  }
}
