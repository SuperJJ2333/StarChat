import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/search/global_search_index.dart';
import 'package:liuhetong_mobile/features/search/local_message_search_repository.dart';

/// 本机历史回填的**资源边界**（本轮收口项）。
///
/// AppHome 首屏 / Matrix 登录 / 打开聊天 / 发消息 / 通话都不得被回填阻塞。
/// 因此回填必须是：
/// - 有界（房间数 + 每房间条数 + 总记录预算）；
/// - 分批 yield（不长时间霸占事件循环）；
/// - 可取消 / 代次安全（账号切换后的迟到结果必须丢弃）；
/// - 未完成时不得把自己标记为「已回填」，否则历史被永久截断。
void main() {
  test('有界：perRoomLimit 与 maxRooms 都被真实遵守', () async {
    final source = CountingSource(rooms: 50, perRoom: 10);
    final repository = LocalMessageSearchRepository(source: source)
      ..attachAccount('matrix:@a:test');

    final indexed =
        await repository.backfillLocalHistory(perRoomLimit: 4, maxRooms: 3);

    expect(indexed, 12, reason: '3 个房间 × 每房间 4 条');
    expect(source.requestedLimits, everyElement(4),
        reason: '必须把 perRoomLimit 透传给本机读取');
    expect(source.readRoomIds, hasLength(3), reason: 'maxRooms 必须生效');
  });

  test('总记录预算：超出预算即停止，且不得标记为已完成回填', () async {
    final source = CountingSource(rooms: 100, perRoom: 1000);
    final repository = LocalMessageSearchRepository(
      source: source,
      maxRooms: 100,
      defaultPerRoomLimit: 1000,
    )..attachAccount('matrix:@a:test');

    await repository.backfillLocalHistory(totalRecordBudget: 2500);

    expect(source.readRoomIds.length, lessThan(100),
        reason: '命中总预算后必须提前停止，不能扫完所有房间');
    expect(repository.isBackfillComplete, isFalse,
        reason: '被预算截断时不得声称「已回填完成」，否则历史被永久截断');
    // 未完成时再次调用应当继续（而不是被 _backfilled 挡住）。
    expect(await repository.ensureBackfilled(), greaterThan(0),
        reason: '未完成的回填必须允许后续继续推进');
  });

  test('全部扫完才标记为已完成', () async {
    final source = CountingSource(rooms: 3, perRoom: 5);
    final repository = LocalMessageSearchRepository(source: source)
      ..attachAccount('matrix:@a:test');
    await repository.backfillLocalHistory(perRoomLimit: 5, maxRooms: 10);
    expect(repository.isBackfillComplete, isTrue);
    expect(await repository.ensureBackfilled(), 0, reason: '已完成的回填不再重复执行');
  });

  test('回填期间分批 yield：不长时间霸占事件循环', () async {
    final source = CountingSource(rooms: 60, perRoom: 200);
    final repository = LocalMessageSearchRepository(
      source: source,
      maxRooms: 60,
      defaultPerRoomLimit: 200,
    )..attachAccount('matrix:@a:test');

    // 心跳：只有事件循环被让出时才会被调度。
    var beats = 0;
    var running = true;
    Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (running) beats++;
    });

    await repository.backfillLocalHistory();
    running = false;

    // 60 个房间同步投影共 12000 条；如果完全不 yield，心跳基本没有机会运行。
    expect(beats, greaterThan(0), reason: '回填必须在批次之间让出事件循环（否则首屏/发送/通话会被阻塞）');
  });

  test('账号切换安全：切换后迟到的回填结果被丢弃', () async {
    final gate = Completer<void>();
    final source = _GatedSource(gate: gate);
    final repository = LocalMessageSearchRepository(source: source);
    repository.attachAccount('matrix:@a:test');

    final pending = repository.backfillLocalHistory();
    await Future<void>.delayed(Duration.zero);
    // 回填进行中切换账号。
    repository.attachAccount('matrix:@b:test');
    gate.complete();
    await pending;

    expect(repository.search('命中'), isEmpty,
        reason: '账号切换后，旧账号的迟到回填结果绝不能进入新账号索引');
  });

  test('显式取消：取消后不再继续索引', () async {
    final gate = Completer<void>();
    final source = _GatedSource(gate: gate);
    final repository = LocalMessageSearchRepository(source: source);
    repository.attachAccount('matrix:@a:test');

    final pending = repository.backfillLocalHistory();
    await Future<void>.delayed(Duration.zero);
    repository.cancelBackfill();
    gate.complete();
    await pending;

    expect(repository.isBackfillComplete, isFalse);
    expect(repository.search('命中'), isEmpty);
  });

  test('未绑定账号时回填是空操作', () async {
    final source = CountingSource(rooms: 5, perRoom: 5);
    final repository = LocalMessageSearchRepository(source: source);
    expect(await repository.backfillLocalHistory(), 0);
    expect(source.readRoomIds, isEmpty);
  });

  test('索引内容仍受闪照/媒体过滤（回填路径不能绕过）', () async {
    final repository = LocalMessageSearchRepository(
      source: InMemoryLocalHistorySource([
        LocalSearchMessage(
          eventId: r'!r:test-$e1',
          senderId: '@peer:test',
          senderName: 'peer',
          timestamp: DateTime.utc(2026, 9, 1),
          body: '正文命中',
          roomId: '!r:test',
          roomName: 'r',
        ),
        LocalSearchMessage(
          eventId: r'$flash',
          senderId: '@peer:test',
          senderName: 'peer',
          timestamp: DateTime.utc(2026, 9, 1),
          body: '闪照正文命中',
          roomId: '!r:test',
          roomName: 'r',
          isFlashPhoto: true,
        ),
        LocalSearchMessage(
          eventId: r'$image',
          senderId: '@peer:test',
          senderName: 'peer',
          timestamp: DateTime.utc(2026, 9, 1),
          body: '[图片]',
          roomId: '!r:test',
          roomName: 'r',
        ),
      ]),
    );
    repository.attachAccount('matrix:@a:test');
    await repository.backfillLocalHistory();
    final hits = repository.search('命中');
    expect([for (final hit in hits) hit.eventId], [r'!r:test-$e1']);
  });

  test('共享索引不会被未完成回填永久截断（可继续推进）', () async {
    final index = GlobalSearchIndex();
    final source = CountingSource(rooms: 40, perRoom: 50);
    final repository =
        LocalMessageSearchRepository(source: source, index: index);
    repository.attachAccount('matrix:@a:test');

    await repository.backfillLocalHistory(totalRecordBudget: 100);
    final firstPass = source.readRoomIds.length;
    await repository.backfillLocalHistory(totalRecordBudget: 100000);
    expect(source.readRoomIds.length, greaterThan(firstPass),
        reason: '预算提高后必须能继续扫描剩余房间');
    expect(repository.isBackfillComplete, isTrue);
  });
}

/// 可被外部闸门卡住的假数据源（用于测试取消/切号竞态）。
final class _GatedSource implements LocalHistorySearchSource {
  _GatedSource({required this.gate});

  final Completer<void> gate;

  @override
  Future<List<String>> localRoomIds() async => ['!room-0:test', '!room-1:test'];

  @override
  Future<List<LocalSearchMessage>> readRecentMessages(
      {required String roomId, required int limit}) async {
    await gate.future;
    return [
      LocalSearchMessage(
        eventId: '$roomId-\$e0',
        senderId: '@peer:test',
        senderName: 'peer',
        timestamp: DateTime.utc(2026, 9, 1),
        body: '正文命中',
        roomId: roomId,
        roomName: roomId,
      ),
    ];
  }
}

/// 记录每次读取请求的假数据源（同步段故意做一点工作，模拟解码/投影）。
final class CountingSource implements LocalHistorySearchSource {
  CountingSource({required this.rooms, required this.perRoom});

  final int rooms;
  final int perRoom;
  final requestedLimits = <int>[];
  final readRoomIds = <String>[];
  int synchronousChunks = 0;

  @override
  Future<List<String>> localRoomIds() async =>
      [for (var i = 0; i < rooms; i++) '!room-$i:test'];

  @override
  Future<List<LocalSearchMessage>> readRecentMessages(
      {required String roomId, required int limit}) async {
    requestedLimits.add(limit);
    readRoomIds.add(roomId);
    final result = <LocalSearchMessage>[];
    // 忠实于接口契约：最多返回 limit 条（真实实现也是「最多 limit 条」）。
    final count = perRoom > limit ? limit : perRoom;
    for (var i = 0; i < count; i++) {
      // 同步投影：真实实现里这里要对每条事件做类型过滤与正文提取。
      result.add(LocalSearchMessage(
        eventId: '$roomId-\$e$i',
        senderId: '@peer:test',
        senderName: 'peer',
        timestamp: DateTime.utc(2026, 9, 1).add(Duration(minutes: i)),
        body: '正文 $i 命中',
        roomId: roomId,
        roomName: roomId,
      ));
      synchronousChunks++;
    }
    return result;
  }
}
