import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_entry.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';

/// 通话入口（语音/视频）必须与「发消息」使用同一身份规则：业务 userId 为主键，
/// 入口快照里可能过期的 matrixUserId 绝不用于开房或发起呼叫——否则会把通话
/// 拨给用户旧的 Matrix 身份。这里只验证 wiring（不涉及 WebRTC/媒体传输）。
const _self = ProfileData(
    username: 'self', nickname: 'self', maskedEmail: '', fallbackSeed: 'self');

/// 好友目录里的权威条目：业务 userId = A，Matrix 绑定 = NEW。
const _directoryContact = ContactSummary(
  userId: 'user-a',
  username: 'alice',
  matrixUserId: '@alice:new.test',
  nickname: '艾丽丝',
  remark: '我的备注',
  avatarUrl: 'https://cdn.test/new-avatar.png',
);

/// 入口快照：同一个人，但 Matrix 绑定是旧的（改绑/迁移前）。
const _staleEntry = ContactDetails(
  userId: 'user-a',
  username: 'alice',
  matrixUserId: '@alice:old.test',
  nickname: '旧昵称',
  avatarUrl: 'https://cdn.test/old-avatar.png',
);

final class _Gateway implements DirectChatGateway {
  final opened = <String>[];
  @override
  Future<DirectChatRoom> openOrCreateDirectChat(String matrixUserId) async {
    opened.add(matrixUserId);
    return DirectChatRoom(
      roomId: '!canonical:test',
      encrypted: true,
      joinedMemberCount: 2,
      participantIds: {'@me:test', matrixUserId},
    );
  }
}

final class _Store implements ProfileStore {
  ProfileSnapshot? _snapshot;
  @override
  Future<ProfileSnapshot?> read(String accountKey) async => _snapshot;
  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    _snapshot = snapshot;
  }
}

Future<
    ({
      ProfileRepository cache,
      DirectChatController directChats,
      _Gateway gateway
    })> _setUp() async {
  final store = _Store();
  await store.write('self',
      const ProfileSnapshot(profile: _self, contacts: [_directoryContact]));
  final cache = ProfileRepository.forTesting(
    accountKey: 'self',
    store: store,
    loadProfile: () async => _self,
    loadContacts: () async => const [_directoryContact],
  );
  await cache.preload();
  final gateway = _Gateway();
  return (
    cache: cache,
    directChats: DirectChatController(gateway),
    gateway: gateway
  );
}

void main() {
  test('Test A: 语音通话使用权威 matrixUserId（不是入口快照的旧值）', () async {
    final harness = await _setUp();
    addTearDown(harness.cache.dispose);
    addTearDown(harness.directChats.dispose);

    final target = await resolveCallTarget(
      cache: harness.cache,
      directChats: harness.directChats,
      entry: _staleEntry,
    );

    expect(harness.gateway.opened, ['@alice:new.test'],
        reason: '必须用目录里的当前 Matrix 绑定开房');
    expect(harness.gateway.opened, isNot(contains('@alice:old.test')));
    expect(target.contact.matrixUserId, '@alice:new.test');
    expect(target.roomId, '!canonical:test', reason: '仍走 canonical 私聊房间');
  });

  test('Test B: 视频通话共用同一解析（不存在按媒体类型分叉的旧身份路径）', () async {
    // `_openCall(contact, type)` 只解析一次身份，audio/video 由同一个
    // resolveCallTarget 提供目标；这里以视频入口再验一次，并断言源码里
    // 两个入口都指向同一个 _openCall 与同一个解析函数。
    final harness = await _setUp();
    addTearDown(harness.cache.dispose);
    addTearDown(harness.directChats.dispose);

    final target = await resolveCallTarget(
      cache: harness.cache,
      directChats: harness.directChats,
      entry: _staleEntry,
    );
    expect(harness.gateway.opened, ['@alice:new.test']);
    expect(target.contact.matrixUserId, '@alice:new.test');

    final home = File('lib/app_home.dart').readAsStringSync();
    expect(home.contains('CallMediaType.audio'), isTrue, reason: '语音入口存在');
    expect(home.contains('CallMediaType.video'), isTrue,
        reason: '视频入口存在且共用 _openCall');
    expect(_countOccurrences(home, 'resolveCallTarget('), 1,
        reason: '通话身份只解析一次，不允许按音频/视频各写一份');
  });

  test('Test C: 通话页展示使用权威联系人（备注/昵称/头像）', () async {
    final harness = await _setUp();
    addTearDown(harness.cache.dispose);
    addTearDown(harness.directChats.dispose);

    final target = await resolveCallTarget(
      cache: harness.cache,
      directChats: harness.directChats,
      entry: _staleEntry,
    );

    // CallPage 的 displayName/fallbackSeed/avatarUrl 直接取自该联系人，
    // 因此这里断言的就是通话页实际展示的数据。
    expect(target.contact.displayName, '我的备注', reason: '备注是本机展示名，优先于昵称');
    expect(target.contact.nickname, '艾丽丝', reason: '目录昵称，而非入口旧昵称');
    expect(target.contact.username, 'alice');
    expect(target.contact.avatarUrl, 'https://cdn.test/new-avatar.png',
        reason: '头像也必须是权威条目的，不能显示旧资料');

    final home = File('lib/app_home.dart').readAsStringSync();
    final callPage = home.substring(
        home.indexOf('builder: (pageContext) => CallPage('),
        home.indexOf(
            'unawaited(navigation.whenComplete(releasePresentation));'));
    expect(callPage, contains('displayName: authoritative.displayName'));
    expect(callPage, contains('fallbackSeed: authoritative.username'));
    expect(callPage, contains('avatarUrl: authoritative.avatarUrl'));
    expect(callPage, isNot(contains('contact.displayName')));
    expect(callPage, isNot(contains('contact.avatarUrl')));
    expect(home.contains('matrixUserId: authoritative.matrixUserId.trim()'),
        isTrue,
        reason: 'calls.start 必须使用权威 matrixUserId');
    expect(home.contains('matrixUserId: contact.matrixUserId'), isFalse,
        reason: '不得再直接把入口快照的 matrixUserId 交给通话');
  });
}

int _countOccurrences(String source, String needle) {
  var count = 0;
  var index = source.indexOf(needle);
  while (index != -1) {
    count++;
    index = source.indexOf(needle, index + needle.length);
  }
  return count;
}
