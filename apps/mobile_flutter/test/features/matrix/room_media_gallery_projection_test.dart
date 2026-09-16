import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/media_message_access_policy.dart';
import 'package:liuhetong_mobile/features/matrix/room_media_gallery_projection.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

/// Task C：闪照与普通媒体资产的隔离。
///
/// 端到端不变量：**普通 Gallery / 普通图片查看器 / 搜索媒体网格的数据集里
/// 永远没有闪照**，因此其邻居预取（±1）在构造上不可能触发闪照 loader。
/// 这里同时用投影、源码契约和 RoomPage 端到端三条证据覆盖。
void main() {
  RoomMessageViewModel image(String id,
          {bool flash = false,
          RoomDeliveryState delivery = RoomDeliveryState.sent,
          bool recalled = false,
          RoomMessageKind kind = RoomMessageKind.image}) =>
      RoomMessageViewModel(
        id: id,
        senderId: '@peer:test',
        text: flash ? '' : 'photo',
        isOwn: false,
        deliveryState: delivery,
        timestamp: DateTime.utc(2026, 9, 15),
        kind: kind,
        mimeType: 'image/png',
        isFlashPhoto: flash,
        isRecalled: recalled,
      );

  group('ordinaryGalleryMessages 数据集', () {
    test('normal → flash → normal：只有普通图片，且顺序不变', () {
      final gallery = ordinaryGalleryMessages([
        image(r'$normal-before'),
        image(r'$flash', flash: true),
        image(r'$normal-after'),
      ]);
      expect([for (final message in gallery) message.id],
          [r'$normal-before', r'$normal-after']);
      expect(gallery.every((message) => !message.isFlashPhoto), isTrue);
    });

    test('历史分页（loadEarlier）追加旧消息后闪照仍不被收录', () {
      final afterLoadEarlier = ordinaryGalleryMessages([
        image(r'$older-flash', flash: true),
        image(r'$older-normal'),
        image(r'$normal-before'),
        image(r'$flash', flash: true),
        image(r'$normal-after'),
      ]);
      expect([for (final message in afterLoadEarlier) message.id],
          [r'$older-normal', r'$normal-before', r'$normal-after']);
      expect(
          afterLoadEarlier.any((message) => message.isFlashPhoto), isFalse,
          reason: '预取边界只可能落在普通图片上');
    });

    test('撤回 / 未发送 / 非图片消息都不进入普通 Gallery', () {
      final gallery = ordinaryGalleryMessages([
        image(r'$recalled', recalled: true),
        image(r'$sending', delivery: RoomDeliveryState.sending),
        image(r'$failed', delivery: RoomDeliveryState.failed),
        image(r'$video', kind: RoomMessageKind.video),
        image(r'$sent'),
      ]);
      expect([for (final message in gallery) message.id], [r'$sent']);
    });

    test('isOrdinaryGalleryImage 与策略一致（单一判据）', () {
      for (final message in [image(r'$normal'), image(r'$flash', flash: true)]) {
        final policy = MediaMessageAccessPolicy.forMessage(
            isFlashPhoto: message.isFlashPhoto);
        expect(isOrdinaryGalleryImage(message), policy.includeInOrdinaryGallery);
      }
      expect(isOrdinaryGalleryImage(image(r'$flash', flash: true)), isFalse);
    });

    test('数据集里每条都允许普通原图 loader（不可能触碰闪照 loader）', () {
      for (final message in ordinaryGalleryMessages([
        image(r'$normal'),
        image(r'$flash', flash: true),
      ])) {
        MediaMessageAccessPolicy.forMessage(
                isFlashPhoto: message.isFlashPhoto)
            .assertOrdinaryMediaAllowed('gallery.original');
      }
    });
  });

  group('源码契约：RoomPage 的普通媒体入口都走策略', () {
    final source = File('lib/features/matrix/room_page.dart').readAsStringSync();

    test('普通 Gallery 数据集来自 ordinaryGalleryMessages', () {
      expect(source, contains('for (final message in ordinaryGalleryMessages('));
      expect(source, isNot(contains('isFlashPhoto: false')));
    });

    test('预览/原图/转发闭包逐个断言普通媒体权限', () {
      for (final operation in [
        'gallery.preview',
        'gallery.original',
        'gallery.forward',
        'imagePreview',
      ]) {
        expect(source, contains("assertOrdinaryMediaAllowed('$operation')"),
            reason: '$operation 必须先断言策略，闪照走到这里会抛 StateError');
      }
    });

    test('普通查看器与搜索媒体网格对闪照 fail-closed', () {
      expect(source, contains('canUseOrdinaryViewer'));
      expect(source, contains('闪照仅可在闪照查看器中打开'));
      expect(source, contains('Flash photo must not use ordinary search media grid'));
    });

    test('闪照只经专用安全查看器加载原图', () {
      expect(source, contains('FlashPhotoViewerPage('));
      expect(source, contains('FlashPhotoBubble('));
    });
  });

  group('「图片与视频」历史搜索', () {
    ChatSearchMessage search(String id,
            {required bool flash, ChatSearchMediaCategory? category}) =>
        ChatSearchMessage(
          eventId: id,
          senderId: '@peer:test',
          senderDisplayName: 'peer',
          timestamp: DateTime.utc(2026, 9, 15),
          timelineOrder: 1,
          visibleText: flash ? '' : 'photo',
          mediaCategory: category,
          hasMedia: category != null,
          isFlashPhoto: flash,
        );

    test('媒体筛选不命中闪照（即使它被错误地打上媒体分类）', () {
      const filters = ChatSearchFilters(
          mediaCategory: ChatSearchMediaCategory.imageVideo);
      expect(
          filters.matches(search(r'$normal',
              flash: false, category: ChatSearchMediaCategory.imageVideo)),
          isTrue);
      expect(
          filters.matches(search(r'$flash',
              flash: true, category: ChatSearchMediaCategory.imageVideo)),
          isFalse);
    });
  });
}
