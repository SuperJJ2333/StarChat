import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/components/message_unread_badge.dart';

void main() {
  test('message badge labels zero, ordinary counts and capped counts', () {
    expect(messageUnreadBadgeLabel(0), isNull);
    expect(messageUnreadBadgeLabel(12), '12');
    expect(messageUnreadBadgeLabel(99), '99');
    expect(messageUnreadBadgeLabel(100), '99+');
  });
}
