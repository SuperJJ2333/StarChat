import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/friend_qr.dart';
import 'package:liuhetong_mobile/features/contacts/group_qr.dart';

/// BUG2：群二维码载荷编解码 + 扫码分流（与好友码互斥）。
void main() {
  group('群二维码载荷', () {
    test('构建与解析往返', () {
      const token = 'AbCdEfGh12345678_-XyZ0987654321';
      final payload = buildGroupQrPayload(token);
      expect(payload, 'changliao://g/$token');
      expect(parseGroupQrPayload(payload), token);
    });

    test('好友码不是群码（分流互斥）', () {
      expect(parseGroupQrPayload('changliao://u/alice'), isNull);
      expect(parseGroupQrPayload(buildFriendQrPayload('alice')), isNull);
    });

    test('短令牌与非法字符被拒绝（防伪造）', () {
      expect(parseGroupQrPayload('changliao://g/short'), isNull);
      expect(
        parseGroupQrPayload('changliao://g/has space and symbols!!'),
        isNull,
      );
      expect(parseGroupQrPayload('changliao://g/'), isNull);
    });

    test('非群码内容返回 null', () {
      expect(parseGroupQrPayload('https://example.com/g/xxx'), isNull);
      expect(parseGroupQrPayload(''), isNull);
      expect(parseGroupQrPayload('weixin://g/whatever'), isNull);
    });

    test('载荷不含房间 ID 特征（token 无 ! 与 #）', () {
      const token = 'safeToken_-1234567890abcdef';
      final payload = buildGroupQrPayload(token);
      expect(payload.contains('!'), isFalse, reason: '不含 Matrix 房间 ID');
    });
  });
}
