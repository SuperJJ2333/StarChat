import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/search/global_search_index.dart';
import 'package:liuhetong_mobile/features/search/global_search_models.dart';
import 'package:liuhetong_mobile/features/search/local_message_search_repository.dart';

LocalSearchMessage _msg(
  String eventId,
  String body, {
  String roomId = '!group:test',
  String roomName = '数智经济中心',
  bool isGroup = true,
  String senderId = '@peer:test',
  String senderName = '张三',
  bool senderIsSelf = false,
  bool isFlashPhoto = false,
  DateTime? at,
}) =>
    LocalSearchMessage(
      eventId: eventId,
      senderId: senderId,
      senderName: senderName,
      timestamp: at ?? DateTime.utc(2026, 9, 15, 10),
      body: body,
      senderIsSelf: senderIsSelf,
      isFlashPhoto: isFlashPhoto,
      roomId: roomId,
      roomName: roomName,
      isGroup: isGroup,
      roomAvatarSeed: roomId,
    );

List<String> _ids(List<GlobalSearchMessageHit> hits) =>
    [for (final hit in hits) hit.eventId];

/// 本机历史只读视图的 fake：模拟「SQLCipher 加密本地库里已经存在的消息」。
final class _FakeLocalHistorySource implements LocalHistorySearchSource {
  _FakeLocalHistorySource(this.rooms);

  /// roomId → 新→旧排序的本地消息。
  final Map<String, List<LocalSearchMessage>> rooms;
  final List<({String roomId, int limit})> reads =
      <({String roomId, int limit})>[];
  int roomIdCalls = 0;

  int get totalCalls => roomIdCalls + reads.length;

  @override
  Future<List<String>> localRoomIds() async {
    roomIdCalls++;
    return rooms.keys.toList();
  }

  @override
  Future<List<LocalSearchMessage>> readRecentMessages(
      {required String roomId, required int limit}) async {
    reads.add((roomId: roomId, limit: limit));
    final all = rooms[roomId] ?? const <LocalSearchMessage>[];
    return all.length > limit ? all.sublist(0, limit) : all;
  }
}

/// 卡住的本地读取（用于验证账号切换时迟到的 backfill 不得写入新账号）。
final class _GatedLocalHistorySource implements LocalHistorySearchSource {
  _GatedLocalHistorySource({required this.gate, required this.messages});

  final Completer<void> gate;
  final List<LocalSearchMessage> messages;

  @override
  Future<List<String>> localRoomIds() async => ['!a:test'];

  @override
  Future<List<LocalSearchMessage>> readRecentMessages(
      {required String roomId, required int limit}) async {
    await gate.future;
    return messages;
  }
}

LocalMessageSearchRepository _repository(LocalHistorySearchSource source) =>
    LocalMessageSearchRepository(source: source, index: GlobalSearchIndex());

void main() {
  group('LocalMessageSearchRepository（本机加密库历史检索）', () {
    test('app restart still searches local history', () async {
      // 只存在一个「加密本地库」（fake source）——进程内索引会被丢弃。
      final source = _FakeLocalHistorySource({
        '!group:test': [
          _msg(r'$new', '项目文件已发送', at: DateTime.utc(2026, 9, 15, 11)),
          _msg(r'$old', '项目早期记录', at: DateTime.utc(2026, 9, 14, 9)),
        ],
      });

      final first = _repository(source);
      first.attachAccount('@alice:test');
      await first.backfillLocalHistory();
      expect(_ids(first.search('项目')), [r'$new', r'$old']);

      // 模拟重启：内存索引全新，只有本地库存活。
      final second = _repository(source);
      second.attachAccount('@alice:test');
      await second.backfillLocalHistory();
      expect(_ids(second.search('项目')), [r'$new', r'$old'],
          reason: '重启后必须能从本机加密库重建索引并命中');
      expect(_ids(second.search('早期')), [r'$old']);
    });

    test('a room that was never opened in this process is searchable',
        () async {
      final source = _FakeLocalHistorySource({
        '!never:test': [
          _msg(r'$never', '从未打开的会话里的历史消息',
              roomId: '!never:test', roomName: '从未打开', isGroup: false),
        ],
      });
      final repository = _repository(source);
      repository.attachAccount('@alice:test');
      await repository.backfillLocalHistory();

      expect(_ids(repository.search('从未打开')), [r'$never']);
    });

    test('more than 4000 records in one room: the oldest is still found',
        () async {
      final many = <LocalSearchMessage>[
        for (var i = 0; i < 4200; i++)
          _msg(
            '\$$i',
            i == 4199 ? '最早的本地历史' : '常规消息$i',
            at: DateTime.utc(2026, 1, 1).add(Duration(minutes: 4199 - i)),
          ),
      ];
      final source = _FakeLocalHistorySource({'!group:test': many});
      final repository = _repository(source);
      repository.attachAccount('@alice:test');
      final count = await repository.backfillLocalHistory();

      expect(count, 4200, reason: '本地回填不得在 4000 条处被静默截断');
      expect(kLocalSearchDefaultPerRoomLimit, greaterThan(4000),
          reason: '默认每房间回填上限必须高于旧的 4000 上限');
      expect(_ids(repository.search('最早的本地历史')), [r'$4199'],
          reason: '最旧的本机历史必须仍然可被检索');
      expect(repository.search('常规消息').length, 200, reason: '单次检索有界（hitLimit）');
    });

    test('account switching resets the index and never leaks across accounts',
        () async {
      final sourceA = _FakeLocalHistorySource({
        '!a:test': [
          _msg(r'$a1', 'A 账号机密', roomId: '!a:test', roomName: 'A 会话'),
        ],
      });
      final sourceB = _FakeLocalHistorySource({
        '!b:test': [
          _msg(r'$b1', 'B 账号机密', roomId: '!b:test', roomName: 'B 会话'),
        ],
      });
      final repository = _repository(sourceA);
      repository.attachAccount('@a:test');
      await repository.backfillLocalHistory();
      expect(_ids(repository.search('机密')), [r'$a1']);
      final epochA = repository.accountEpoch;

      repository.attachAccount('@b:test');
      repository.source = sourceB;
      expect(repository.accountEpoch, greaterThan(epochA),
          reason: '账号切换必须推进代次');
      expect(repository.search('机密'), isEmpty,
          reason: 'attachAccount 必须先清空上一账号的索引');

      await repository.backfillLocalHistory();
      expect(_ids(repository.search('机密')), [r'$b1'],
          reason: '只允许返回当前账号本机库中的命中');

      repository.clear();
      expect(repository.search('机密'), isEmpty);
      expect(repository.isAttached, isFalse);
      await repository.backfillLocalHistory();
      expect(repository.search('机密'), isEmpty, reason: '未绑定账号时不得索引任何内容');
    });

    test('a stale in-flight backfill never writes into the new account',
        () async {
      final gate = Completer<void>();
      final repository = _repository(
        _GatedLocalHistorySource(
          gate: gate,
          messages: [_msg(r'$a1', 'A 账号机密', roomId: '!a:test')],
        ),
      );
      repository.attachAccount('@a:test');
      final pending = repository.backfillLocalHistory();

      repository.attachAccount('@b:test');
      gate.complete();
      await pending;

      expect(repository.search('机密'), isEmpty, reason: '迟到的账号 A 回填结果必须被代次校验丢弃');
    });

    test('flash photos and media placeholders never enter the held state',
        () async {
      final source = _FakeLocalHistorySource({
        '!group:test': [
          _msg(r'$flash', '项目闪照正文', isFlashPhoto: true),
          _msg(r'$img', '[图片]'),
          _msg(r'$video', '[视频]'),
          _msg(r'$mime', 'image/png'),
          _msg(r'$data', 'data:image/png;base64,AAAA'),
          _msg(r'$text', '项目文件已发送'),
        ],
      });
      final repository = _repository(source);
      repository.attachAccount('@alice:test');
      await repository.backfillLocalHistory();

      expect(_ids(repository.search('项目')), [r'$text']);
      expect(repository.search('闪照'), isEmpty, reason: '阅后即焚内容永不可检索');
      expect(repository.search('图片'), isEmpty);
      expect(repository.search('视频'), isEmpty);
      expect(repository.search('base64'), isEmpty);
      for (final hit in repository.index.search('image')) {
        expect(hit.body.contains('image'), isFalse);
      }
      expect(
        repository.search(''),
        isEmpty,
        reason: '空查询不返回任何结果',
      );
    });

    test('an image-only room leaves no held records at all', () async {
      final source = _FakeLocalHistorySource({
        '!group:test': [
          _msg(r'$img', '[图片]'),
          _msg(r'$flash', '闪照', isFlashPhoto: true),
        ],
      });
      final repository = _repository(source);
      repository.attachAccount('@alice:test');
      final count = await repository.backfillLocalHistory();

      expect(count, 0);
      expect(repository.index.indexedRoomCount, 0,
          reason: '没有任何可索引文本时不得建立空房间条目');
    });

    test('backfill is bounded by perRoomLimit and maxRooms', () async {
      final source = _FakeLocalHistorySource({
        '!r1:test': [for (var i = 0; i < 10; i++) _msg('\$r1-$i', '命中$i')],
        '!r2:test': [for (var i = 0; i < 10; i++) _msg('\$r2-$i', '命中$i')],
        '!r3:test': [for (var i = 0; i < 10; i++) _msg('\$r3-$i', '命中$i')],
      });
      final repository = _repository(source);
      repository.attachAccount('@alice:test');
      final count =
          await repository.backfillLocalHistory(perRoomLimit: 3, maxRooms: 2);

      expect(source.reads, hasLength(2), reason: 'maxRooms 必须限制读取的房间数');
      for (final read in source.reads) {
        expect(read.limit, 3, reason: 'perRoomLimit 必须如实传给本机库');
      }
      expect(count, 6);
      expect(source.rooms['!r1:test']!.length, 10, reason: 'fake 本地库无副作用');
    });

    test('ensureBackfilled runs at most once per attached account', () async {
      final source = _FakeLocalHistorySource({
        '!group:test': [_msg(r'$a', '项目文件')],
      });
      final repository = _repository(source);
      repository.attachAccount('@alice:test');
      expect(await repository.ensureBackfilled(), 1);
      expect(await repository.ensureBackfilled(), 0);
      expect(source.roomIdCalls, 1);

      repository.attachAccount('@bob:test');
      expect(await repository.ensureBackfilled(), 1, reason: '切换账号后必须重建索引');
      expect(source.roomIdCalls, 2);
    });

    test('incremental room messages extend the index without re-reading it',
        () async {
      final source = _FakeLocalHistorySource({
        '!group:test': [_msg(r'$old', '项目早期记录')],
      });
      final repository = _repository(source);
      repository.attachAccount('@alice:test');
      await repository.backfillLocalHistory();
      final readsBefore = source.totalCalls;

      repository.recordRoomMessages([
        _msg(r'$live', '项目新消息', at: DateTime.utc(2026, 9, 16, 10)),
        _msg(r'$live-flash', '项目闪照', isFlashPhoto: true),
      ]);

      expect(source.totalCalls, readsBefore, reason: '增量投影不得触发任何本机库读取');
      expect(_ids(repository.search('项目')), [r'$live', r'$old'],
          reason: '新消息必须与回填的历史合并');
      expect(repository.search('闪照'), isEmpty);
    });

    test('repository notifications fire on backfill, projection and clear',
        () async {
      final source = _FakeLocalHistorySource({
        '!group:test': [_msg(r'$a', '项目文件')],
      });
      final repository = _repository(source);
      var notifications = 0;
      repository.addListener(() => notifications++);
      repository.attachAccount('@alice:test');
      expect(notifications, 1);
      await repository.backfillLocalHistory();
      expect(notifications, 2);
      repository.recordRoomMessages([_msg(r'$b', '项目新消息')]);
      expect(notifications, 3);
      repository.clear();
      expect(notifications, 4);
    });

    test(
        'zero network: search performs no I/O and no network library is linked',
        () async {
      final source = _FakeLocalHistorySource({
        '!group:test': [_msg(r'$a', '项目文件')],
      });
      final repository = _repository(source);
      repository.attachAccount('@alice:test');
      await repository.backfillLocalHistory();

      final callsBefore = source.totalCalls;
      expect(_ids(repository.search('项目')), [r'$a']);
      expect(source.totalCalls, callsBefore,
          reason: '检索必须完全走内存索引，不得触碰注入的本地读取依赖');

      // 构造性检查：仓库/索引层不得引用任何网络能力。
      for (final path in const [
        'lib/features/search/local_message_search_repository.dart',
        'lib/features/search/global_search_index.dart',
      ]) {
        final file = File(path);
        expect(file.existsSync(), isTrue,
            reason: '测试必须在 apps/mobile_flutter 包根目录运行：$path');
        final text = file.readAsStringSync();
        for (final banned in const [
          'package:http',
          'dart:io',
          'dart:html',
          'HttpClient',
          'WebSocket',
          'package:web_socket',
          'package:dio',
          'BusinessApiClient',
        ]) {
          expect(text.contains(banned), isFalse,
              reason: '$path 不得依赖网络能力：$banned');
        }
      }
    });

    test('shared repository reuses the device-side GlobalSearchIndex', () {
      expect(
          identical(LocalMessageSearchRepository.shared.index,
              GlobalSearchIndex.shared),
          isTrue,
          reason: '共享实例必须与 RoomPage 现有投影写入同一个索引');
    });

    test('InMemoryLocalHistorySource never hits the network and is read-only',
        () async {
      final source = InMemoryLocalHistorySource([
        _msg(r'$a', '项目文件', roomId: '!g:test'),
      ]);
      expect(await source.localRoomIds(), ['!g:test']);
      final recent =
          await source.readRecentMessages(roomId: '!g:test', limit: 1);
      expect(recent.single.eventId, r'$a');
      expect(await source.readRecentMessages(roomId: '!none:test', limit: 5),
          isEmpty);
    });

    test('media placeholder detection is exact, not substring based', () {
      expect(LocalMessageSearchRepository.isIndexableText('[图片]'), isFalse);
      expect(LocalMessageSearchRepository.isIndexableText(' [视频] '), isFalse);
      expect(
          LocalMessageSearchRepository.isIndexableText('image/png'), isFalse);
      expect(
          LocalMessageSearchRepository.isIndexableText('video/mp4'), isFalse);
      expect(
          LocalMessageSearchRepository.isIndexableText(
              'data:image/png;base64,AA'),
          isFalse);
      expect(LocalMessageSearchRepository.isIndexableText('[图片]已收到'), isTrue,
          reason: '纯文本里提到「图片」仍然必须可检索');
      expect(LocalMessageSearchRepository.isIndexableText('项目文件'), isTrue);
      expect(LocalMessageSearchRepository.isIndexableText('   '), isFalse);
    });
  });
}
