import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/profile/invite_code_page.dart';
import 'package:liuhetong_mobile/features/profile/invite_controller.dart';
import 'package:liuhetong_mobile/features/profile/invite_snapshot_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假网关：可切换成功/失败，并暴露账号作用域（邀请码页生产环境由
/// `BusinessApiClient` 同时实现这两个接口）。
final class _Gateway
    implements
        PersonalInvitationGateway,
        InviteHistoryGateway,
        InviteCacheScopeProvider {
  _Gateway({
    this.invite,
    this.history,
    this.scope = 'origin:alice',
    this.inviteError,
    this.historyError,
  });

  PersonalInvitation? invite;
  InviteHistoryPage? history;
  String? scope;
  Object? inviteError;
  Object? historyError;
  int inviteCalls = 0;
  int historyCalls = 0;

  @override
  Future<PersonalInvitation> fetchPersonalInvitation() async {
    inviteCalls++;
    final error = inviteError;
    if (error != null) throw error;
    return invite!;
  }

  @override
  Future<InviteHistoryPage> fetchInviteHistory(
      {int limit = 20, int offset = 0}) async {
    historyCalls++;
    final error = historyError;
    if (error != null) throw error;
    return history ?? const InviteHistoryPage(items: []);
  }

  @override
  Future<String?> inviteCacheScope() async => scope;
}

InviteHistoryItem _row(String username) => InviteHistoryItem(
      boundAt: DateTime.utc(2026, 9, 10, 8),
      nickname: '昵称-$username',
      username: username,
    );

InviteSnapshot _snapshot({
  String scope = 'origin:alice',
  String code = 'CACHED42',
  List<String> rows = const [],
}) =>
    InviteSnapshot(
      scope: scope,
      code: code,
      maxUses: 10,
      useCount: 4,
      shareUrl: 'https://x/register?code=$code',
      history: [for (final row in rows) _row(row).toJson()],
      historyNextOffset: null,
      savedAt: DateTime.utc(2026, 9, 19, 6),
    );

const _fresh = PersonalInvitation(
    code: 'FRESH999', maxUses: 20, useCount: 5, shareUrl: 'https://x/fresh');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('本地优先：进入即有上次成功的邀请码，刷新失败不清空（L1/L4）', () async {
    final store = InMemoryInviteSnapshotStore(
        _snapshot(rows: ['bob', 'carol']));
    final gateway = _Gateway(inviteError: Exception('offline'));
    final controller = InviteCodeController(
        gateway: gateway, historyGateway: gateway, snapshots: store);

    // 网络还没回来（且即将失败）时，本地快照已经可用。
    await controller.hydrationDone;
    expect(controller.state.status, InviteCodeStatus.ready);
    expect(controller.state.invite!.code, 'CACHED42');
    expect(controller.state.history.map((e) => e.username).toList(),
        ['bob', 'carol']);
    expect(controller.state.historyStatus, InviteHistoryStatus.ready);

    await controller.load();
    expect(controller.state.status, InviteCodeStatus.ready,
        reason: '刷新失败不能把页面打回 failed');
    expect(controller.state.invite!.code, 'CACHED42');
    expect(controller.state.message, contains('刷新失败'));
    controller.dispose();
  });

  testWidgets('断网进入页面：显示本地邀请码，没有加载圈也没有错误占位 (L2)',
      (tester) async {
    final store = InMemoryInviteSnapshotStore(
        _snapshot(rows: ['bob', 'carol']));
    final gateway = _Gateway(
        inviteError: Exception('offline'), historyError: Exception('offline'));
    final controller = InviteCodeController(
        gateway: gateway, historyGateway: gateway, snapshots: store);
    await controller.hydrationDone;

    await tester.pumpWidget(
      CupertinoApp(home: InviteCodePage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('CACHED42'), findsOneWidget,
        reason: '本地优先：断网也要先展示上次成功的邀请码');
    expect(find.byType(CupertinoActivityIndicator), findsNothing,
        reason: '有本地数据时不得把内容换成加载圈（闪烁）');
    expect(find.text('邀请码加载失败，请重试'), findsNothing);
    expect(find.byKey(const Key('invite-history-error')), findsNothing,
        reason: '历史行仍在屏幕上，不显示错误占位');
    expect(find.byKey(const Key('invite-history-bob')), findsOneWidget);
    controller.dispose();
  });

  test('后台刷新成功：码与历史都写成新快照，且刷新不清空邀请历史', () async {
    final store = InMemoryInviteSnapshotStore(_snapshot());
    final gateway = _Gateway(
        invite: _fresh,
        history: InviteHistoryPage(items: [_row('dave')], nextOffset: 20));
    final controller = InviteCodeController(
        gateway: gateway, historyGateway: gateway, snapshots: store);
    await controller.hydrationDone;

    await controller.load();
    await controller.loadHistory();
    await controller.load(); // 再次刷新邀请码：历史不能被清空

    expect(controller.state.invite!.code, 'FRESH999');
    expect(controller.state.history.map((e) => e.username).toList(), ['dave'],
        reason: 'load() 不得重置邀请历史');

    await pumpEventQueue();
    final written = store.read()!;
    expect(written.code, 'FRESH999');
    expect(written.scope, 'origin:alice');
    expect(written.useCount, 5);
    expect(written.history.single['username'], 'dave');
    expect(written.historyNextOffset, 20);
    controller.dispose();
  });

  test('跨账号快照：作用域不符立即丢弃，不展示别人的邀请码', () async {
    final store = InMemoryInviteSnapshotStore(
        _snapshot(scope: 'origin:alice', code: 'ALICE123'));
    final gateway = _Gateway(invite: _fresh, scope: 'origin:bob');
    final controller = InviteCodeController(
        gateway: gateway, historyGateway: gateway, snapshots: store);

    await controller.hydrationDone;
    expect(controller.state.invite, isNull);
    expect(store.read(), isNull, reason: '跨账号快照必须被清掉');

    await controller.load();
    expect(controller.state.invite!.code, 'FRESH999');
    // 落盘是后台任务（不阻塞界面），测试等事件队列排空后再断言。
    await pumpEventQueue();
    expect(store.read()!.scope, 'origin:bob');
    controller.dispose();
  });

  test('作用域不可解析（未登录）：既不信旧快照也不落盘', () async {
    final store = InMemoryInviteSnapshotStore(_snapshot());
    final gateway = _Gateway(invite: _fresh, scope: null);
    final controller = InviteCodeController(
        gateway: gateway, historyGateway: gateway, snapshots: store);

    await controller.hydrationDone;
    expect(controller.state.invite, isNull);
    await controller.load();
    expect(controller.state.status, InviteCodeStatus.ready);
    await pumpEventQueue();
    expect(store.read(), isNull, reason: '作用域不可知时宁可不落盘');
    controller.dispose();
  });

  test('首次进入（无本地数据）：失败仍是 failed，可重试', () async {
    final store = InMemoryInviteSnapshotStore();
    final gateway = _Gateway(inviteError: Exception('offline'));
    final controller = InviteCodeController(
        gateway: gateway, historyGateway: gateway, snapshots: store);
    await controller.hydrationDone;

    await controller.load();
    expect(controller.state.status, InviteCodeStatus.failed);
    expect(controller.state.message, contains('邀请码加载失败'));

    gateway.inviteError = null;
    gateway.invite = _fresh;
    await controller.load();
    expect(controller.state.status, InviteCodeStatus.ready);
    expect(controller.state.message, isNull);
    controller.dispose();
  });

  test('邀请历史刷新失败：旧记录保留，不显示错误占位（L4）', () async {
    final store = InMemoryInviteSnapshotStore(_snapshot(rows: ['bob']));
    final gateway = _Gateway(invite: _fresh);
    final controller = InviteCodeController(
        gateway: gateway, historyGateway: gateway, snapshots: store);
    await controller.hydrationDone;

    gateway.historyError = Exception('offline');
    await controller.loadHistory(refresh: true);

    expect(controller.state.historyStatus, InviteHistoryStatus.ready);
    expect(controller.state.history.single.username, 'bob');
    controller.dispose();
  });

  test('邀请历史从未成功过：失败仍是 failed（错误占位只在无数据时出现）',
      () async {
    final store = InMemoryInviteSnapshotStore();
    final gateway = _Gateway(
        invite: _fresh, historyError: Exception('offline'));
    final controller = InviteCodeController(
        gateway: gateway, historyGateway: gateway, snapshots: store);
    await controller.hydrationDone;

    await controller.loadHistory();
    expect(controller.state.historyStatus, InviteHistoryStatus.failed);
    controller.dispose();
  });

  test('本地快照落盘/读取往返：账号作用域与邀请历史都在 (SharedPreferences)',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = await SharedPreferencesInviteSnapshotStore.open();
    await store.write(_snapshot(rows: ['bob']));

    final reopened = await SharedPreferencesInviteSnapshotStore.open();
    final read = reopened.read()!;
    expect(read.scope, 'origin:alice');
    expect(read.code, 'CACHED42');
    expect(read.maxUses, 10);
    expect(read.useCount, 4);
    expect(read.shareUrl, 'https://x/register?code=CACHED42');
    expect(read.history.single['username'], 'bob');
    expect(read.savedAt, DateTime.utc(2026, 9, 19, 6));

    await reopened.clear();
    expect(
        (await SharedPreferencesInviteSnapshotStore.open()).read(), isNull);
  });

  test('损坏的快照按无本地数据处理并清掉，不影响正常加载', () async {
    SharedPreferences.setMockInitialValues(
        {SharedPreferencesInviteSnapshotStore.key: '{not-json'});
    final store = await SharedPreferencesInviteSnapshotStore.open();
    expect(store.read(), isNull);

    final gateway = _Gateway(invite: _fresh);
    final controller = InviteCodeController(
        gateway: gateway, historyGateway: gateway, snapshots: store);
    await controller.hydrationDone;
    expect(controller.state.invite, isNull);

    await controller.load();
    expect(controller.state.status, InviteCodeStatus.ready);
    expect(controller.state.invite!.code, 'FRESH999');
    controller.dispose();
  });
}
