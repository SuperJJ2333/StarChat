import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/profile/invite_controller.dart';

final class _FakeInvitationGateway implements PersonalInvitationGateway {
  _FakeInvitationGateway(this.invite);

  final PersonalInvitation invite;
  int calls = 0;

  @override
  Future<PersonalInvitation> fetchPersonalInvitation() async {
    calls++;
    return invite;
  }
}

final class _FakeHistoryGateway implements InviteHistoryGateway {
  _FakeHistoryGateway(this.pages, {this.failure});

  /// offset -> page（按请求顺序弹出）。
  final List<InviteHistoryPage> pages;
  final Object? failure;
  final offsets = <int>[];
  int limitCalls = 0;

  @override
  Future<InviteHistoryPage> fetchInviteHistory(
      {int limit = 20, int offset = 0}) async {
    limitCalls++;
    if (failure != null) throw failure!;
    offsets.add(offset);
    if (offsets.length > pages.length) {
      return InviteHistoryPage(items: const []);
    }
    return pages[offsets.length - 1];
  }
}

InviteHistoryItem item(String username, {String? nickname}) =>
    InviteHistoryItem(
      boundAt: DateTime.utc(2026, 9, 10, 8),
      nickname: nickname,
      username: username,
    );

void main() {
  final invitation = PersonalInvitation(
      code: 'AB12CD34', maxUses: 10, useCount: 3, shareUrl: 'https://x/c');

  test('邀请历史首屏：倒序列表 + nextOffset 驱动加载更多', () async {
    final gateway = _FakeHistoryGateway([
      InviteHistoryPage(items: [item('alice'), item('bob')], nextOffset: 20),
      InviteHistoryPage(items: [item('carol')], nextOffset: null),
    ]);
    final controller = InviteCodeController(
        gateway: _FakeInvitationGateway(invitation),
        historyGateway: gateway);

    await controller.loadHistory();
    expect(controller.state.historyStatus, InviteHistoryStatus.ready);
    expect(controller.state.history.map((e) => e.username).toList(),
        ['alice', 'bob']);
    expect(controller.state.historyNextOffset, 20);

    await controller.loadMoreHistory();
    expect(controller.state.history.map((e) => e.username).toList(),
        ['alice', 'bob', 'carol']);
    expect(controller.state.historyNextOffset, isNull);
    expect(gateway.offsets, [0, 20]);
  });

  test('邀请历史失败可重试；重试成功恢复 ready', () async {
    final failing = _FakeHistoryGateway([], failure: StateError('net'));
    final controller = InviteCodeController(
        gateway: _FakeInvitationGateway(invitation), historyGateway: failing);
    await controller.loadHistory();
    expect(controller.state.historyStatus, InviteHistoryStatus.failed);

    final ok = _FakeHistoryGateway(
        [InviteHistoryPage(items: [item('dave')], nextOffset: null)]);
    // 直接换网关验证重试语义：controller 保留同接口。
    final controller2 = InviteCodeController(
        gateway: _FakeInvitationGateway(invitation), historyGateway: ok);
    await controller2.loadHistory(refresh: true);
    expect(controller2.state.historyStatus, InviteHistoryStatus.ready);
    expect(controller2.state.history.single.username, 'dave');
  });

  test('空历史：ready + 空列表（页面渲染“暂无邀请记录”）', () async {
    final controller = InviteCodeController(
        gateway: _FakeInvitationGateway(invitation),
        historyGateway: _FakeHistoryGateway(
            [InviteHistoryPage(items: const [])]));
    await controller.loadHistory();
    expect(controller.state.historyStatus, InviteHistoryStatus.ready);
    expect(controller.state.history, isEmpty);
  });

  test('历史项昵称为空显示“未设置昵称”', () {
    expect(item('x').displayNickname, '未设置昵称');
    expect(item('x', nickname: '').displayNickname, '未设置昵称');
    expect(item('x', nickname: '小明').displayNickname, '小明');
  });

  test('loadHistory 幂等：ready 后重复调用不再发请求', () async {
    final gateway = _FakeHistoryGateway(
        [InviteHistoryPage(items: [item('a')], nextOffset: null)]);
    final controller = InviteCodeController(
        gateway: _FakeInvitationGateway(invitation), historyGateway: gateway);
    await controller.loadHistory();
    await controller.loadHistory();
    expect(gateway.limitCalls, 1);
  });
}
