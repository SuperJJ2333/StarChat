import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_comment_composer.dart';

/// 与生产 `moment_comment_composer.pick()` 完全相同的启动方式。
Future<({List<GalleryPhoto> photos, bool original, bool flash})?>
    _launchSharedGallery(BuildContext context, int maxCount) => Navigator.of(
            context,
            rootNavigator: true)
        .push<({List<GalleryPhoto> photos, bool original, bool flash})>(
            CupertinoPageRoute(
                builder: (_) =>
                    ImagePickerPage(photosOnly: true, maxCount: maxCount)));

void main() {
  test('朋友圈评论相册契约：ImagePickerPage 的结果必须匹配 MomentGalleryPicker', () {
    // 该赋值是编译期契约断言：相册页增减结果字段而不同步更新
    // MomentGalleryPicker/MomentCommentComposer 的泛型时，这里编译失败，
    // 而不是在真机上把「选择图片」变成无法退出的卡死。
    const MomentGalleryPicker contract = _launchSharedGallery;
    expect(contract, isNotNull);
  });
}
