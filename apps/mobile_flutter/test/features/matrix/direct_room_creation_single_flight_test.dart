import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/coordinated_direct_chat.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_entry.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';

DirectChatRoom _room(String id) => DirectChatRoom(
      roomId: id,
      encrypted: true,
      joinedMemberCount: 2,
      participantIds: {'@me:test', '@peer:test'},
    );

/// 建房授权 fake：服务端语义——同一 attempt 首次 claim 才发一次性建房授权。
class GrantingDirectory implements DirectRoomCoordinator {
  final claims = <String>[];
  String? owner;
  String? canonical;
  bool failLookup = false;
  var lookupCalls = 0;

  @override
  Future<String?> canonicalRoomId(String peer) async {
    lookupCalls++;
    if (failLookup) throw StateError('directory timeout');
    return canonical;
  }

  @override
  Future<DirectRoomClaim> claim(String peer, String attempt) async {
    claims.add(attempt);
    if (canonical != null) return DirectRoomClaim(roomId: canonical);
    final first = owner == null;
    owner ??= attempt;
    return DirectRoomClaim(mayCreate: first, canPublish: owner == attempt);
  }

  @override
  Future<String> publish(String peer, String attempt, String roomId) async {
    if (owner != attempt) throw StateError('wrong owner');
    return canonical ??= roomId;
  }
}

class SharedIntentStore implements DirectRoomIntentStore {
  SharedIntentStore(this.attempt);
  final String attempt;
  DirectRoomIntent? saved;

  @override
  Future<DirectRoomIntent> loadOrCreate(String peer) async =>
      saved ??= DirectRoomIntent(attemptId: attempt);

  @override
  Future<void> saveRoom(
      String peer, DirectRoomIntent intent, String roomId) async {
    saved = DirectRoomIntent(attemptId: intent.attemptId, roomId: roomId);
  }
}

CoordinatedDirectChatGateway _gateway(
  GrantingDirectory directory,
  SharedIntentStore intents, {
  required int Function() createCount,
  DirectChatRoom? Function()? existing,
}) =>
    CoordinatedDirectChatGateway(
      coordinator: directory,
      intents: intents,
      businessUserIdOf: (_) => 'peer-user',
      createOnce: (peer) async {
        createCount();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return _room('!created:test');
      },
      findExisting: (_) async => existing?.call(),
      openExisting: (roomId, peer) async => _room(roomId),
      // 轮询给真实事件循环节拍（2ms×20）：让持授权方的 createOnce 有机会
      // 完成 publish；零延迟 fake 会在微任务里瞬间耗尽 20 次轮询。
      wait: (_) => Future<void>.delayed(const Duration(milliseconds: 2)),
    );

void main() {
  test('测试1：同一好友「发消息」连点 10 次只创建一个房间（闸门合并）', () async {
    final gate = DirectMessageOpenGate();
    var resolutions = 0;
    final barrier = Completer<void>();
    DirectMessageTarget? target;
    final flights = List.generate(
        10,
        (_) => gate.run('peer-user', () async {
              resolutions++;
              await barrier.future;
              target ??= DirectMessageTarget(
                  roomId: '!created:test',
                  contact: const ContactDetails(
                      userId: 'peer-user',
                      username: 'Peer',
                      matrixUserId: '@peer:test'));
              return target;
            }));
    await Future<void>.delayed(Duration.zero);
    expect(resolutions, 1, reason: '同键的 10 次连点必须合并为同一次解析');
    barrier.complete();
    final results = await Future.wait(flights);
    expect(results.every((item) => identical(item, target)), isTrue);
  });

  test('测试1：10 个并发 open 走协调网关也只创建一个房间', () async {
    final directory = GrantingDirectory();
    final intents = SharedIntentStore('attempt-1');
    var creates = 0;
    final gateway = _gateway(directory, intents,
        createCount: () => creates++, existing: () => null);
    final controller = DirectChatController(gateway);
    final rooms = await Future.wait(
        List.generate(10, (_) => controller.open('@peer:test')));
    expect(creates, 1, reason: '同一 userPair 同时只能存在一个创建任务');
    expect(rooms.every((room) => room.roomId == '!created:test'), isTrue);
    expect(directory.canonical, '!created:test');
  });

  test('测试1：绕过控制器的原始并发也只授权一次建房', () async {
    final directory = GrantingDirectory();
    final intents = SharedIntentStore('attempt-1');
    var creates = 0;
    final gateway = _gateway(directory, intents,
        createCount: () => creates++, existing: () => null);
    final rooms = await Future.wait(
        List.generate(10, (_) => gateway.openOrCreateDirectChat('@peer:test')));
    expect(creates, lessThanOrEqualTo(1), reason: '建房授权由服务端一次性发放');
    expect(rooms.map((room) => room.roomId).toSet().length, 1,
        reason: '10 个调用方最终拿到同一个房间');
  });

  test('测试2：弱网下 canonical 目录超时后重试，仍不产生第二个房间', () async {
    final directory = GrantingDirectory()..failLookup = true;
    final intents = SharedIntentStore('attempt-1');
    var creates = 0;
    final gateway = _gateway(directory, intents,
        createCount: () => creates++, existing: () => null);

    // 第一次：目录不可达 → 断网降级只复用，本地没有则抛原始错误，绝不新建。
    await expectLater(
        gateway.openOrCreateDirectChat('@peer:test'), throwsStateError);
    expect(creates, 0);

    // 弱网恢复：同一 attempt 重试，第一次拿到授权，恰好建一个房间。
    directory.failLookup = false;
    final room = await gateway.openOrCreateDirectChat('@peer:test');
    expect(room.roomId, '!created:test');
    expect(creates, 1);
  });

  test('测试2：建房结果不确定（响应丢失）后重放同一 attempt，只复用不再建', () async {
    final directory = GrantingDirectory();
    final intents = SharedIntentStore('attempt-1');
    var creates = 0;
    var createFails = false;
    final gateway = CoordinatedDirectChatGateway(
      coordinator: directory,
      intents: intents,
      businessUserIdOf: (_) => 'peer-user',
      createOnce: (peer) async {
        creates++;
        if (createFails) {
          // Matrix 请求已发出但响应丢失：本地抛错，房间可能已创建。
          throw StateError('uncertain matrix result');
        }
        return _room('!created:test');
      },
      findExisting: (_) async => creates >= 1 ? _room('!created:test') : null,
      openExisting: (roomId, peer) async => _room(roomId),
      wait: (_) async {},
    );

    createFails = true;
    await expectLater(
        gateway.openOrCreateDirectChat('@peer:test'), throwsStateError);
    expect(creates, 1);

    // 重放：同一 attemptId，claim 不再授权建房，只能复用既有房间。
    createFails = false;
    final room = await gateway.openOrCreateDirectChat('@peer:test');
    expect(room.roomId, '!created:test');
    expect(creates, 1, reason: '重放绝不能第二次 create');
    expect(directory.canonical, '!created:test');
  });
}
