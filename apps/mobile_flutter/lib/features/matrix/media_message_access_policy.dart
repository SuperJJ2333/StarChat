import 'package:flutter/foundation.dart';

/// 媒体消息访问策略（安全域规则，集中定义，不在各处散落 `if (isFlashPhoto)`）。
///
/// 闪照（阅后即焚图片）**不属于**普通图片/视频资产：
/// - 不能进入普通「图片与视频」历史搜索；
/// - 不能成为普通大图 Gallery 的一员（连预取都不能接触其 loader）；
/// - 不能通过普通查看器/编辑器/收藏/转发/保存取得原始字节。
///
/// 唯一可以取得闪照原图的入口是 `FlashPhotoViewerPage`（专用安全能力：
/// 3 秒查看 + 屏幕捕获保护 + 查看即销毁）。
@immutable
final class MediaMessageAccessPolicy {
  const MediaMessageAccessPolicy._(this.isFlashPhoto);

  /// 闪照：只允许专用安全查看器。
  static const flashPhoto = MediaMessageAccessPolicy._(true);

  /// 普通媒体（含普通图片/视频/文件/文本）。
  static const ordinary = MediaMessageAccessPolicy._(false);

  factory MediaMessageAccessPolicy.forMessage(
          {required bool isFlashPhoto}) =>
      isFlashPhoto ? flashPhoto : ordinary;

  /// 是否为闪照（阅后即焚）。
  final bool isFlashPhoto;

  /// 是否可能出现在普通「图片与视频」历史搜索结果里。
  bool get includeInSearchMedia => !isFlashPhoto;

  /// 是否可能成为普通大图 Gallery 的成员（含左右滑动与预取）。
  bool get includeInOrdinaryGallery => !isFlashPhoto;

  /// 是否允许普通查看器加载原图字节。
  bool get canLoadOrdinaryOriginal => !isFlashPhoto;

  /// 是否允许进入普通图片查看器 / Gallery。
  bool get canUseOrdinaryViewer => !isFlashPhoto;

  bool get canForward => !isFlashPhoto;
  bool get canSave => !isFlashPhoto;
  bool get canFavorite => !isFlashPhoto;
  bool get canEdit => !isFlashPhoto;

  /// 是否必须走专用安全查看器（闪照）。
  bool get requiresDedicatedSecureViewer => isFlashPhoto;

  /// 普通媒体路径的不变量：闪照走到这里就是安全旁路，必须失败关闭。
  void assertOrdinaryMediaAllowed(String operation) {
    if (!isFlashPhoto) return;
    throw StateError(
        'Flash photo must not use ordinary media path: $operation');
  }

  @override
  bool operator ==(Object other) =>
      other is MediaMessageAccessPolicy && other.isFlashPhoto == isFlashPhoto;

  @override
  int get hashCode => isFlashPhoto.hashCode;

  @override
  String toString() =>
      'MediaMessageAccessPolicy(${isFlashPhoto ? 'flashPhoto' : 'ordinary'})';
}
