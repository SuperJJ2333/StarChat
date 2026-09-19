import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/contact_tag_models.dart';
import 'package:liuhetong_mobile/features/contacts/contact_tag_pages.dart';
import 'package:liuhetong_mobile/features/contacts/contact_tag_snapshot_store.dart';
import 'package:liuhetong_mobile/features/contacts/contacts_page.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';

/// 微信级加载模型（2026-09-19 审计）：标签成员页与"选择朋友"页原先只有网络
/// `listContacts()`，加载中与失败都是同一颗整页加载圈 —— 断网时既看不到标签里的
/// 好友，也分不清"在加载"还是"已失败"。新契约：先用本地联系人投影
/// （`ProfileRepository.contacts`）渲染，失败保留，只有从未有过本地数据才报错。
final class _TagGateway implements ContactsGateway {
  bool fail = true;

  /// 标签接口单独可控：用于验证标签列表页"加载失败"不再伪装成空列表。
  bool tagsFail = false;

  /// 标签接口的成功负载（默认空列表）。
  Map<String, dynamic> tagsPayload = const {'items': []};

  /// 标签列表页的账号作用域（生产由 BusinessApiClient 提供）。
  String? scope;

  @override
  Future<List<ContactSummary>> listContacts() async {
    if (fail) throw StateError('offline');
    return const [];
  }

  @override
  Future<Map<String, dynamic>> contactTags() async {
    if (tagsFail) throw StateError('offline');
    return tagsPayload;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<dynamic>.value();
}

final class _SnapshotStore implements ProfileStore {
  _SnapshotStore(this.snapshot);
  final ProfileSnapshot? snapshot;

  @override
  Future<ProfileSnapshot?> read(String accountKey) async => snapshot;

  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {}
}

ProfileSnapshot _snapshotWithContacts(List<ContactSummary> contacts) =>
    ProfileSnapshot(
        profile: const ProfileData(
            username: 'alice',
            nickname: 'Alice',
            maskedEmail: 'a***@example.com',
            fallbackSeed: 'alice'),
        contacts: contacts);

Future<ProfileRepository> _repository(List<ContactSummary> contacts) async {
  final repository = ProfileRepository.forTesting(
      accountKey: 'matrix:@alice:example',
      store: _SnapshotStore(_snapshotWithContacts(contacts)));
  await repository.hydrate();
  return repository;
}

const _tag = ContactTagSummary(id: 't1', name: '同学', friendCount: 1);

const _member = ContactSummary(
    userId: 'u1',
    username: 'xiaohong',
    matrixUserId: '@x:example',
    nickname: '小鸿',
    tags: ['同学']);

void main() {
  testWidgets('标签成员页：断网时用本地联系人投影渲染，不显示加载圈/错误',
      (tester) async {
    final repository = await _repository(const [_member]);

    await tester.pumpWidget(CupertinoApp(
        home: ContactTagMembersPage(
            api: _TagGateway(), tag: _tag, identityCache: repository)));
    await tester.pumpAndSettle();

    expect(find.text('小鸿'), findsOneWidget, reason: '断网时必须展示标签里的本地好友');
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('联系人加载失败'), findsNothing,
        reason: '有本地联系人的刷新失败不显示错误页');
    repository.dispose();
  });

  testWidgets('选择朋友页：断网时同样先用本地联系人渲染', (tester) async {
    final repository = await _repository(const [_member]);

    await tester.pumpWidget(CupertinoApp(
        home: ContactTagFriendPickerPage(
            api: _TagGateway(),
            tag: const ContactTagSummary(id: 't2', name: '同事'),
            identityCache: repository)));
    await tester.pumpAndSettle();

    expect(find.text('小鸿'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('联系人加载失败'), findsNothing);
    repository.dispose();
  });

  testWidgets('没有本地联系人且加载失败：显示失败与重试，而不是永久加载圈',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: ContactTagMembersPage(api: _TagGateway(), tag: _tag)));
    await tester.pumpAndSettle();

    expect(find.text('联系人加载失败'), findsOneWidget);
    expect(find.byKey(const Key('tag-members-retry')), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
  });

  testWidgets('标签列表页：加载失败显示失败与重试，而不是永久加载圈',
      (tester) async {
    final gateway = _TagGateway()..tagsFail = true;

    await tester.pumpWidget(CupertinoApp(home: ContactTagsPage(api: gateway)));
    await tester.pumpAndSettle();

    expect(find.text('标签加载失败'), findsOneWidget);
    expect(find.byKey(const Key('contact-tags-retry')), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsNothing,
        reason: '失败不能伪装成"一直在加载"');
  });

  testWidgets('标签列表页：断网冷启动直接渲染上次快照的标签（微信级 L1 本地优先）',
      (tester) async {
    final store = InMemoryContactTagSnapshotStore(ContactTagSnapshot(
        scope: 'matrix:@alice:example',
        payload: const {
          'items': [
            {'id': 't1', 'name': '同学', 'friend_count': 1},
          ],
        },
        savedAt: DateTime.fromMillisecondsSinceEpoch(0)));
    addTearDown(ContactTagSnapshotStores.reset);
    ContactTagSnapshotStores.shared = store;
    final gateway = _TagGateway()
      ..tagsFail = true
      ..scope = 'matrix:@alice:example';

    await tester.pumpWidget(CupertinoApp(
        home: ContactTagsPage(
            api: gateway, scopeResolver: () async => gateway.scope)));
    await tester.pumpAndSettle();

    expect(find.text('同学'), findsOneWidget,
        reason: '断网冷启动必须展示上次成功的标签列表，而不是空白/失败页');
    expect(find.text('标签加载失败'), findsNothing,
        reason: '有本地快照时刷新失败保留数据，只字不提失败');
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
  });

  testWidgets('标签列表页：快照属于其他账号时不展示（账号切换保护）', (tester) async {
    final store = InMemoryContactTagSnapshotStore(ContactTagSnapshot(
        scope: 'matrix:@bob:example',
        payload: const {
          'items': [
            {'id': 't1', 'name': '同学的标签', 'friend_count': 3},
          ],
        },
        savedAt: DateTime.fromMillisecondsSinceEpoch(0)));
    addTearDown(ContactTagSnapshotStores.reset);
    ContactTagSnapshotStores.shared = store;
    final gateway = _TagGateway()
      ..tagsFail = true
      ..scope = 'matrix:@alice:example';

    await tester.pumpWidget(CupertinoApp(
        home: ContactTagsPage(
            api: gateway, scopeResolver: () async => gateway.scope)));
    await tester.pumpAndSettle();

    expect(find.text('同学的标签'), findsNothing,
        reason: '绝不展示上一个账号的标签');
    expect(find.text('标签加载失败'), findsOneWidget);
  });

  testWidgets('标签列表页：刷新成功后把最新列表写入快照', (tester) async {
    final store = InMemoryContactTagSnapshotStore();
    addTearDown(ContactTagSnapshotStores.reset);
    ContactTagSnapshotStores.shared = store;
    final gateway = _TagGateway()
      ..fail = false
      ..tagsFail = false
      ..scope = 'matrix:@alice:example'
      ..tagsPayload = const {
        'items': [
          {'id': 't9', 'name': '家人', 'friend_count': 2},
        ],
      };

    await tester.pumpWidget(CupertinoApp(
        home: ContactTagsPage(
            api: gateway, scopeResolver: () async => gateway.scope)));
    await tester.pumpAndSettle();

    final saved = store.read();
    expect(saved, isNotNull, reason: '成功刷新必须落盘，供下次断网冷启动使用');
    expect(saved!.scope, 'matrix:@alice:example');
  });

  testWidgets('标签选择页：标签接口失败时提示失败与重试，而不是只显示"新建标签"',
      (tester) async {
    final gateway = _TagGateway()..tagsFail = true;

    await tester.pumpWidget(CupertinoApp(
        home: ContactTagPickerPage(
            api: gateway,
            contact: const ContactDetails(
                userId: 'u1',
                username: 'xiaohong',
                matrixUserId: '@x:example',
                nickname: '小鸿'))));
    await tester.pumpAndSettle();

    expect(find.text('标签加载失败'), findsOneWidget);
    expect(find.byKey(const Key('tag-picker-tags-retry')), findsOneWidget);
  });
}
