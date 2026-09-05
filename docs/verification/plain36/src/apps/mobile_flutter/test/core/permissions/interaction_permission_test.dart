import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/permissions/interaction_permission.dart';

void main() {
  test('好友：全部能力开放', () {
    final p = InteractionPermission.resolve(
        isFriend: true, isBlocked: false);
    expect(p.state, InteractionState.friend);
    expect(p.canSendMessage(), isTrue);
    expect(p.canSendImage(), isTrue);
    expect(p.canSendVoice(), isTrue);
    expect(p.canStartVoiceCall(), isTrue);
    expect(p.canStartVideoCall(), isTrue);
    expect(p.canViewMoments(), isTrue);
  });

  test('规格2：删除好友不能发送消息（服务层守卫）', () {
    final p = InteractionPermission.resolve(
        isFriend: false, isBlocked: false);
    expect(p.state, InteractionState.deleted);
    expect(p.canSendMessage(), isFalse, reason: '删除好友后禁止发送消息');
    expect(p.canSendImage(), isFalse);
    expect(p.canSendVoice(), isFalse);
    expect(p.canViewMoments(), isFalse, reason: '非好友不可见朋友圈');
  });

  test('规格3：拉黑不能发起通话（语音与视频都禁止）', () {
    final p = InteractionPermission.resolve(
        isFriend: true, isBlocked: true);
    expect(p.state, InteractionState.blocked);
    expect(p.canStartVoiceCall(), isFalse, reason: '拉黑后禁止语音通话');
    expect(p.canStartVideoCall(), isFalse, reason: '拉黑后禁止视频通话');
    expect(p.canSendMessage(), isFalse);
    expect(p.canViewMoments(), isFalse);
  });

  test('陌生人：全部禁止且提示友好', () {
    final p = InteractionPermission.of(InteractionState.stranger);
    expect(p.canSendMessage(), isFalse);
    expect(p.denialMessage(), contains('好友'));
  });

  test('提示文案按状态区分（微信语义）', () {
    expect(
      InteractionPermission.of(InteractionState.blocked).denialMessage(),
      contains('拉黑'),
    );
    expect(
      InteractionPermission.of(InteractionState.deleted).denialMessage(),
      contains('添加好友'),
    );
  });
}
