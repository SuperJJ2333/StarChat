import 'room_timeline_controller.dart';
import 'media_message_access_policy.dart';

/// 普通大图 Gallery 的数据集投影（安全不变量）。
///
/// 只有「普通图片 + 未撤回 + 已发送 + 策略允许进入普通媒体」的消息才能成为
/// Gallery 成员。闪照（`isFlashPhoto`）**永远**不在此集合内——无论是首次
/// 构建、历史分页（loadEarlier）追加还是左右滑动预取，都不可能接触闪照
/// 的 preview/original loader（见 `MediaMessageAccessPolicy`）。
bool isOrdinaryGalleryImage(RoomMessageViewModel message) =>
    message.kind == RoomMessageKind.image &&
    !message.isRecalled &&
    message.deliveryState == RoomDeliveryState.sent &&
    MediaMessageAccessPolicy.forMessage(isFlashPhoto: message.isFlashPhoto)
        .includeInOrdinaryGallery;

List<RoomMessageViewModel> ordinaryGalleryMessages(
        Iterable<RoomMessageViewModel> messages) =>
    [
      for (final message in messages)
        if (isOrdinaryGalleryImage(message)) message,
    ];
