import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/features/matrix/media_message_access_policy.dart';
import 'package:liuhetong_mobile/features/matrix/room_media_gallery_projection.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

RoomMessageViewModel _image(String id,
        {bool flash = false,
        RoomDeliveryState delivery = RoomDeliveryState.sent,
        bool recalled = false}) =>
    RoomMessageViewModel(
      id: id,
      senderId: '@peer:test',
      text: flash ? '' : 'photo',
      isOwn: false,
      deliveryState: delivery,
      timestamp: DateTime.utc(2026, 9, 15),
      kind: RoomMessageKind.image,
      mimeType: 'image/png',
      isFlashPhoto: flash,
      isRecalled: recalled,
    );

ChatSearchMessage _searchMessage(String id,
        {required bool flash, required ChatSearchMediaCategory? category}) =>
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

void main() {
  group('MediaMessageAccessPolicy', () {
    test('flash photo denies every ordinary media capability', () {
      const policy = MediaMessageAccessPolicy.flashPhoto;
      expect(policy.includeInSearchMedia, isFalse);
      expect(policy.includeInOrdinaryGallery, isFalse);
      expect(policy.canLoadOrdinaryOriginal, isFalse);
      expect(policy.canUseOrdinaryViewer, isFalse);
      expect(policy.canForward, isFalse);
      expect(policy.canSave, isFalse);
      expect(policy.canFavorite, isFalse);
      expect(policy.canEdit, isFalse);
      expect(policy.requiresDedicatedSecureViewer, isTrue);
      expect(() => policy.assertOrdinaryMediaAllowed('test'),
          throwsA(isA<StateError>()));
    });

    test('ordinary media allows the same capabilities', () {
      const policy = MediaMessageAccessPolicy.ordinary;
      expect(policy.includeInSearchMedia, isTrue);
      expect(policy.includeInOrdinaryGallery, isTrue);
      expect(policy.canLoadOrdinaryOriginal, isTrue);
      expect(policy.canForward, isTrue);
      expect(policy.requiresDedicatedSecureViewer, isFalse);
      expect(() => policy.assertOrdinaryMediaAllowed('test'), returnsNormally);
    });

    test('factory maps the message flag', () {
      expect(MediaMessageAccessPolicy.forMessage(isFlashPhoto: true),
          MediaMessageAccessPolicy.flashPhoto);
      expect(MediaMessageAccessPolicy.forMessage(isFlashPhoto: false),
          MediaMessageAccessPolicy.ordinary);
    });
  });

  group('普通大图 Gallery 数据集', () {
    test('normal → flash → normal: gallery contains only the normal images', () {
      final messages = [
        _image(r'$normal-before'),
        _image(r'$flash', flash: true),
        _image(r'$normal-after'),
      ];
      final gallery = ordinaryGalleryMessages(messages);
      expect([for (final message in gallery) message.id],
          [r'$normal-before', r'$normal-after']);
      expect(gallery.any((message) => message.isFlashPhoto), isFalse);
    });

    test('历史分页追加旧消息后闪照仍不被收录', () {
      // loadEarlier 之后数据集会重新计算：把更早的闪照加进来也不得收录。
      final older = [
        _image(r'$older-flash', flash: true),
        _image(r'$older-normal'),
        _image(r'$normal-before'),
        _image(r'$flash', flash: true),
        _image(r'$normal-after'),
      ];
      expect([for (final message in ordinaryGalleryMessages(older)) message.id],
          [r'$older-normal', r'$normal-before', r'$normal-after']);
    });

    test('撤回/未发送图片也不进入 Gallery（既有行为保持）', () {
      final messages = [
        _image(r'$recalled', recalled: true),
        _image(r'$sending', delivery: RoomDeliveryState.sending),
        _image(r'$sent'),
      ];
      expect([for (final message in ordinaryGalleryMessages(messages)) message.id],
          [r'$sent']);
    });

    test('数据集里每条都满足 canLoadOrdinaryOriginal（预取不可能接触闪照 loader）',
        () {
      final messages = [
        _image(r'$normal'),
        _image(r'$flash', flash: true),
      ];
      for (final message in ordinaryGalleryMessages(messages)) {
        final policy = MediaMessageAccessPolicy.forMessage(
            isFlashPhoto: message.isFlashPhoto);
        expect(policy.canLoadOrdinaryOriginal, isTrue);
        expect(policy.includeInOrdinaryGallery, isTrue);
      }
    });
  });

  group('「图片与视频」历史搜索排除闪照', () {
    test('imageVideo filter never matches a flash photo', () {
      const filters = ChatSearchFilters(
          mediaCategory: ChatSearchMediaCategory.imageVideo);
      final normal = _searchMessage(r'$normal',
          flash: false, category: ChatSearchMediaCategory.imageVideo);
      final flash = _searchMessage(r'$flash',
          flash: true, category: ChatSearchMediaCategory.imageVideo);
      expect(filters.matches(normal), isTrue);
      expect(filters.matches(flash), isFalse,
          reason: '闪照不属于普通图片与视频资产');
    });

    test('flash message carries no ordinary media classification', () {
      // 房间页投影规则：闪照的 mediaCategory/hasMedia 必须为空。
      final flash = _searchMessage(r'$flash', flash: true, category: null);
      expect(flash.hasMedia, isFalse);
      expect(flash.mediaCategory, isNull);
      const filters = ChatSearchFilters(keyword: null);
      expect(filters.matches(flash), isTrue,
          reason: '不设媒体筛选时仍可被关键词维度遍历（无正文则不命中关键词）');
    });

    test('keyword search still does not leak flash media into media results',
        () {
      final results = [
        _searchMessage(r'$normal',
            flash: false, category: ChatSearchMediaCategory.imageVideo),
        _searchMessage(r'$flash', flash: true, category: null),
      ];
      const filters = ChatSearchFilters(
          mediaCategory: ChatSearchMediaCategory.imageVideo);
      expect([for (final item in results.where(filters.matches)) item.eventId],
          [r'$normal']);
    });
  });
}
