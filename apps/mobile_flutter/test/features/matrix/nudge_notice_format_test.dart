import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/message_interaction_service.dart';

void main() {
  test('viewer sees own pat as 我拍了拍 with remark-priority target', () {
    final text = formatNudgeNotice(
      viewerId: '@me:test',
      senderId: '@me:test',
      senderName: '我',
      targetUserId: '@alice:test',
      targetName: 'Alice',
      suffix: '的小肩膀',
      viewerRemarkForTarget: '项目小艾',
    );
    expect(text, '我拍了拍项目小艾的小肩膀');
  });

  test('own pat falls back to the live nickname when no remark is set', () {
    final text = formatNudgeNotice(
      viewerId: '@me:test',
      senderId: '@me:test',
      senderName: '我',
      targetUserId: '@alice:test',
      targetName: 'Alice',
      viewerRemarkForTarget: '',
      targetLiveName: '艾米',
    );
    expect(text, '我拍了拍艾米');
  });

  test("other member's pat shows plain nicknames and never the viewer's remark",
      () {
    final text = formatNudgeNotice(
      viewerId: '@me:test',
      senderId: '@bob:test',
      senderName: 'Bob',
      targetUserId: '@alice:test',
      targetName: 'Alice',
      suffix: '晒太阳',
      viewerRemarkForTarget: '项目小艾',
      senderLiveName: '波仔',
      targetLiveName: '艾米',
    );
    expect(text, '波仔拍了拍艾米晒太阳');
    expect(text.contains('项目小艾'), isFalse);
  });

  test('event snapshot names are the fallback when live names are missing',
      () {
    final text = formatNudgeNotice(
      viewerId: '@me:test',
      senderId: '@bob:test',
      senderName: '鲍勃',
      targetUserId: '@alice:test',
      targetName: '爱丽丝',
    );
    expect(text, '鲍勃拍了拍爱丽丝');
  });
}
