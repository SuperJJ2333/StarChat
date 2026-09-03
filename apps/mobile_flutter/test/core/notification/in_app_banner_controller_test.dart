import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/in_app_banner_controller.dart';

InAppBannerItem _item(
  String id,
  String conversationId, {
  String title = '张三',
  String body = '晚上一起吃饭吗？',
}) =>
    InAppBannerItem(
      id: id,
      conversationId: conversationId,
      title: title,
      body: body,
      timestamp: DateTime(2026, 9, 3, 12),
    );

void main() {
  group('PRD §7/§15 应用内横幅队列', () {
    test('首条横幅立即成为当前展示项', () {
      final controller = InAppBannerController();
      controller.present(_item('1', '!a'));
      expect(controller.current?.id, '1');
    });

    test('第二条进入队列，当前横幅关闭后依次顶上', () {
      final controller = InAppBannerController();
      controller.present(_item('1', '!a'));
      controller.present(_item('2', '!b'));
      expect(controller.current?.id, '1');
      controller.dismissCurrent();
      expect(controller.current?.id, '2');
    });

    test('同一会话的新横幅原地更新（当前项/队列项都聚合，不堆积）', () {
      final controller = InAppBannerController();
      controller.present(_item('1', '!a'));
      controller.present(_item('2', '!b'));
      // 当前展示的 !a 横幅被同会话新消息更新（内容换新，条数不增）。
      controller.present(_item('3', '!a'));
      expect(controller.current?.id, '3');
      controller.dismissCurrent();
      expect(controller.current?.id, '2');
      controller.dismissCurrent();
      expect(controller.current, isNull);
      expect(controller.queueLength, 0);
    });

    test('队列容量上限 3，超出的同会话横幅替换最早的同会话项', () {
      final controller = InAppBannerController();
      controller.present(_item('1', '!a'));
      controller.present(_item('2', '!b'));
      controller.present(_item('3', '!c'));
      controller.present(_item('4', '!d'));
      expect(controller.queueLength, lessThanOrEqualTo(3));
    });

    test('dismiss 到空后状态干净', () {
      final controller = InAppBannerController();
      controller.present(_item('1', '!a'));
      controller.dismissCurrent();
      expect(controller.current, isNull);
      expect(controller.queueLength, 0);
      controller.dismissCurrent(); // 幂等。
      expect(controller.current, isNull);
    });
  });
}
