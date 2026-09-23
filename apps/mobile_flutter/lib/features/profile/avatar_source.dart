import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../../ui/chat/wechat_image_editor.dart';
import '../../ui/motion/motion_page_route.dart';
import '../matrix/image_picker_page.dart';
import '../matrix/gif_image_policy.dart';
import 'profile_controller.dart';

const avatarMaxDimension = 1024;

/// Uses the same gallery and safe-area Flutter editor on both mobile platforms.
final class GalleryAvatarSource implements AvatarSource {
  GalleryAvatarSource({required this.contextProvider});
  final BuildContext? Function() contextProvider;

  @override
  Future<AvatarCandidate?> selectCropAndCompress() async {
    final context = contextProvider();
    if (context == null || !context.mounted) return null;
    final navigator = Navigator.of(context, rootNavigator: true);
    final selected = await navigator
        .push<({List<GalleryPhoto> photos, bool original, bool flash})>(
      MotionPageRoute(
          fullscreenDialog: true,
          builder: (_) => const ImagePickerPage(
                photosOnly: true,
                staticImagesOnly: true,
                maxCount: 1,
                confirmLabel: '下一步',
                showOriginalToggle: false,
              )),
    );
    if (!context.mounted ||
        !navigator.mounted ||
        selected == null ||
        selected.photos.length != 1) {
      return null;
    }
    final photo = selected.photos.single;
    if (photo.isVideo || photo.mimeType.toLowerCase() == 'image/gif') {
      return null;
    }
    final bytes = await photo.originalBytes();
    if (!context.mounted ||
        !navigator.mounted ||
        bytes.isEmpty ||
        isGifBytes(bytes)) {
      return null;
    }
    final cropped = await navigator.push<Uint8List>(MotionPageRoute(
      fullscreenDialog: true,
      builder: (_) => WeChatImageEditorPage(bytes: bytes, avatarMode: true),
    ));
    if (!context.mounted || cropped == null) return null;
    return AvatarCandidate(bytes: cropped, mimeType: 'image/png');
  }
}
