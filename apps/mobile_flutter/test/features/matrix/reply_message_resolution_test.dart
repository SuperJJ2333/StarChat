import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/message_timeline_cache.dart';
import 'package:liuhetong_mobile/features/matrix/reply_message_resolution.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/ui/chat/quote_preview_card.dart';

RoomMessageViewModel messageOf(
  String id,
  String text, {
  String? replyTo,
  String? excerpt,
  bool own = false,
  RoomMessageKind kind = RoomMessageKind.text,
}) =>
    RoomMessageViewModel(
      id: id,
      senderId: own ? 'me' : '@peer:test',
      text: text,
      isOwn: own,
      deliveryState: RoomDeliveryState.sent,
      timestamp: DateTime.utc(2026, 9, 17),
      kind: kind,
      replyToEventId: replyTo,
      replyExcerpt: excerpt,
    );

/// Window-visible rows are [items]; anything else must be resolved through
/// [lookupMessage], which stands in for 「本地加密库 → 服务器单事件查询」.
final class LookupTimelineAdapter
    implements RoomTimelineAdapter, RoomMessageLookupSource {
  LookupTimelineAdapter(this.items, {this.supportsLookup = true});

  final List<RoomMessageViewModel> items;
  final bool supportsLookup;

  /// event_id → 权威结果（null = 不存在）。
  final remote = <String, RoomMessageViewModel?>{};

  /// event_id → 解析时抛出的异常。
  final failures = <String, Object>{};

  final lookups = <String>[];
  int historyCalls = 0;

  /// 阻塞解析（模拟网络挂起）。
  Completer<void>? gate;

  @override
  bool get supportsMessageLookup => supportsLookup;

  @override
  Future<RoomMessageViewModel?> lookupMessage(String eventId) async {
    lookups.add(eventId);
    final pending = gate;
    final failure = failures[eventId];
    if (failure != null) throw failure;
    if (pending != null) await pending.future;
    return remote[eventId];
  }

  @override
  List<RoomMessageViewModel> snapshot() => List.of(items);

  @override
  Future<void> loadHistory() async {
    historyCalls++;
  }

  @override
  Future<Uint8List> loadAttachment(String eventId) async =>
      Uint8List.fromList(const [1]);

  @override
  Future<Uint8List?> loadThumbnail(String eventId) async => null;

  @override
  Future<void> markRead() async {}

  @override
  Future<void> retry(String transactionId) async {}

  @override
  Future<String> sendText(String text) async => 'event-sent';

  @override
  Future<String> sendRedPacketReference(
    String packetId,
    String greeting, {
    String? mode,
    String? recipientId,
    String? recipientMatrixId,
  }) async =>
      'event-red-packet';

  @override
  Future<String> sendTransferReference(
    String transferId,
    String amount,
    String? note, {
    String? receiverId,
    String? receiverMatrixId,
  }) async =>
      'event-transfer';

  @override
  void dispose() {}
}

Widget _card({
  required ReplyMessageResolution resolution,
  RoomMessageViewModel? message,
  String? excerpt,
  VoidCallback? onTap,
  VoidCallback? onRetry,
}) =>
    CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(
          child: QuotePreviewCard(
            targetEventId: 'event-target',
            resolution: resolution,
            message: message,
            excerpt: excerpt,
            displayName: '张三',
            onTap: onTap ?? () {},
            onRetry: onRetry,
          ),
        ),
      ),
    );

void main() {
  setUp(() => MessageTimelineCache.shared.clear());
  tearDown(() => MessageTimelineCache.shared.clear());

  group('ReplyMessageResolver 状态机', () {
    test('默认超时为 3 秒（绝不允许无限 loading）', () {
      final resolver = ReplyMessageResolver(lookup: (_) async => null);
      addTearDown(resolver.dispose);
      expect(resolver.timeout, const Duration(seconds: 3));
    });

    test('Test 1：引用当前窗口内的消息直接命中，不产生任何解析请求', () async {
      final adapter = LookupTimelineAdapter([
        messageOf('event-a', '你好'),
        messageOf('event-b', '回复正文', replyTo: 'event-a'),
      ]);
      final controller = RoomTimelineController(adapter);
      final resolver = ReplyMessageResolver(lookup: controller.lookupReplyMessage);
      addTearDown(() {
        resolver.dispose();
        controller.dispose();
      });

      final state = await resolver.resolve('event-a',
          local: controller.findMessage('event-a'));

      expect(state.status, ReplyMessageStatus.loaded);
      expect(state.message!.text, '你好');
      expect(adapter.lookups, isEmpty,
          reason: '本机 timeline 已命中时不得触发任何网络解析');
      expect(adapter.historyCalls, 0);
    });

    test('Test 2：引用 1000 条以前的消息仍可加载（不走 1000 次历史分页）', () async {
      final window = [
        for (var i = 0; i < 1000; i++)
          messageOf('event-$i', '窗口内消息 $i',
              replyTo: i == 999 ? 'event-old' : null),
      ];
      final adapter = LookupTimelineAdapter(window)
        ..remote['event-old'] = messageOf('event-old', '一千条以前的你好');
      final controller = RoomTimelineController(adapter);
      final resolver = ReplyMessageResolver(lookup: controller.lookupReplyMessage);
      addTearDown(() {
        resolver.dispose();
        controller.dispose();
      });

      expect(controller.findMessage('event-old'), isNull,
          reason: '目标确实在窗口之外');

      final state = await resolver.resolve('event-old');

      expect(state.status, ReplyMessageStatus.loaded);
      expect(state.message!.text, '一千条以前的你好');
      expect(adapter.lookups, ['event-old'],
          reason: '单事件查询一次即可恢复，不得按窗口逐页翻历史');
      expect(adapter.historyCalls, 0);
      expect(controller.findMessage('event-old')!.text, '一千条以前的你好',
          reason: '解析结果必须并入 timeline，引用卡片才能渲染');
    });

    test('Test 3：重新进入会话（进程内旧状态全部丢弃）后仍可显示', () async {
      final adapter = LookupTimelineAdapter([
        messageOf('event-b', '回复正文', replyTo: 'event-past'),
      ])
        ..remote['event-past'] = messageOf('event-past', '历史原消息');
      final first = RoomTimelineController(adapter);
      final firstResolver =
          ReplyMessageResolver(lookup: first.lookupReplyMessage);
      await firstResolver.resolve('event-past');
      expect(MessageTimelineCache.shared
              .lookup('@peer:test', 'room', messageOf('event-past', 'x').id)
              ?.text,
          isNull,
          reason: '缓存按账号 + 房间隔离，未写入时不得命中');

      // 模拟重启：全新的 controller / resolver，不共享任何进程内状态。
      final restarted = LookupTimelineAdapter([
        messageOf('event-b', '回复正文', replyTo: 'event-past'),
      ])
        ..remote['event-past'] = messageOf('event-past', '历史原消息');
      final second = RoomTimelineController(restarted);
      final secondResolver =
          ReplyMessageResolver(lookup: second.lookupReplyMessage);
      addTearDown(() {
        firstResolver.dispose();
        first.dispose();
        secondResolver.dispose();
        second.dispose();
      });

      final state = await secondResolver.resolve('event-past');

      expect(state.status, ReplyMessageStatus.loaded);
      expect(state.message!.text, '历史原消息',
          reason: '重启后仍要能从本地库/服务器恢复引用原消息');
      expect(restarted.lookups, ['event-past']);
    });

    test('Test 4：网络断开在超时后落到可重试失败态，绝不永久 loading', () async {
      final adapter = LookupTimelineAdapter(const [])
        ..gate = Completer<void>()
        ..remote['event-offline'] = messageOf('event-offline', '恢复后的原消息');
      final resolver = ReplyMessageResolver(
        lookup: adapter.lookupMessage,
        timeout: const Duration(milliseconds: 40),
      );
      addTearDown(resolver.dispose);

      final pending = resolver.resolve('event-offline');
      expect(resolver.stateOf('event-offline')!.isLoading, isTrue);

      final failed = await pending;

      expect(failed.status, ReplyMessageStatus.networkError);
      expect(failed.label, '原消息加载失败，点击重试');
      expect(failed.canRetry, isTrue);
      expect(resolver.stateOf('event-offline')!.isLoading, isFalse,
          reason: '超时后不得停留在 loading');

      // 网络恢复 → 点击重试成功。
      adapter.gate = null;
      final retried = await resolver.retry('event-offline');
      expect(retried.status, ReplyMessageStatus.loaded);
      expect(retried.message!.text, '恢复后的原消息');
      expect(adapter.lookups, ['event-offline', 'event-offline']);
    });

    test('服务端确认不存在 → notFound（可重试，不伪装成网络失败）', () async {
      final adapter = LookupTimelineAdapter(const []);
      final resolver = ReplyMessageResolver(lookup: adapter.lookupMessage);
      addTearDown(resolver.dispose);

      final state = await resolver.resolve('event-gone');

      expect(state.status, ReplyMessageStatus.notFound);
      expect(state.label, '原消息不存在或已被删除');
      expect(state.message, isNull);
    });

    test('无权限 → permissionDenied 且不提供重试', () async {
      final adapter = LookupTimelineAdapter(const [])
        ..failures['event-secret'] = const ReplyMessageLookupDenied('M_FORBIDDEN');
      final resolver = ReplyMessageResolver(lookup: adapter.lookupMessage);
      addTearDown(resolver.dispose);

      final state = await resolver.resolve('event-secret');

      expect(state.status, ReplyMessageStatus.permissionDenied);
      expect(state.label, '无权查看原消息');
      expect(state.canRetry, isFalse, reason: '权限是权威结论，重试没有意义');
    });

    test('并发解析同一 event_id 只发起一次请求（单飞）', () async {
      final adapter = LookupTimelineAdapter(const [])
        ..gate = Completer<void>()
        ..remote['event-x'] = messageOf('event-x', '原消息');
      final resolver = ReplyMessageResolver(lookup: adapter.lookupMessage);
      addTearDown(resolver.dispose);

      final first = resolver.resolve('event-x');
      final second = resolver.resolve('event-x');
      adapter.gate!.complete();
      await Future.wait([first, second]);

      expect(adapter.lookups.length, 1);
    });

    test('终局结果被缓存：重复解析不再请求', () async {
      final adapter = LookupTimelineAdapter(const [])
        ..remote['event-x'] = messageOf('event-x', '原消息');
      final resolver = ReplyMessageResolver(lookup: adapter.lookupMessage);
      addTearDown(resolver.dispose);

      await resolver.resolve('event-x');
      await resolver.resolve('event-x');
      await resolver.resolve('event-x');

      expect(adapter.lookups.length, 1);
      expect(resolver.stateOf('event-x')!.isLoaded, isTrue);
    });

    test('未知异常归类为可重试失败而不是被吞掉', () async {
      final adapter = LookupTimelineAdapter(const [])
        ..failures['event-boom'] = StateError('socket closed');
      final resolver = ReplyMessageResolver(lookup: adapter.lookupMessage);
      addTearDown(resolver.dispose);

      final state = await resolver.resolve('event-boom');

      expect(state.status, ReplyMessageStatus.networkError);
      expect(state.isSettled, isTrue,
          reason: '失败必须被发布成终局状态，不能静默丢弃');
    });

    test('编程错误（Error）不被归类为用户可见失败', () async {
      final adapter = LookupTimelineAdapter(const [])
        ..failures['event-bug'] = ArgumentError('bad adapter');
      final resolver = ReplyMessageResolver(
        lookup: (eventId) async {
          final failure = adapter.failures[eventId];
          if (failure is Error) throw failure;
          return null;
        },
      );
      addTearDown(resolver.dispose);

      await expectLater(
          resolver.resolve('event-bug'), throwsA(isA<ArgumentError>()));
    });

    test('dispose 后的解析不再回调 UI', () async {
      final adapter = LookupTimelineAdapter(const [])
        ..remote['event-x'] = messageOf('event-x', '原消息');
      var changes = 0;
      final resolver = ReplyMessageResolver(
        lookup: adapter.lookupMessage,
        onChanged: () => changes++,
      );
      resolver.dispose();
      await resolver.resolve('event-x');
      expect(changes, 0);
    });
  });

  group('RoomTimelineController 集成', () {
    test('不支持单事件解析的适配器回退到有界历史分页', () async {
      final adapter = LookupTimelineAdapter(const [], supportsLookup: false);
      final controller = RoomTimelineController(adapter);
      addTearDown(controller.dispose);

      final found = await controller.lookupReplyMessage('event-nowhere');

      expect(found, isNull);
      expect(adapter.historyCalls,
          lessThanOrEqualTo(RoomTimelineController.replyHistoryPageBudget),
          reason: '旧适配器的回退必须是有界的，绝不无限拉取历史');
    });

    test('解析结果有界缓存并可在清空后丢弃', () async {
      final adapter = LookupTimelineAdapter(const [])
        ..remote['event-x'] = messageOf('event-x', '原消息');
      final controller = RoomTimelineController(adapter);
      addTearDown(controller.dispose);

      await controller.lookupReplyMessage('event-x');

      expect(controller.findMessage('event-x')!.text, '原消息');
      controller.forgetResolvedReplyTarget('event-x');
      expect(controller.findMessage('event-x'), isNull);
    });
  });

  group('MessageTimelineCache', () {
    test('按账号 + 房间隔离，超出容量淘汰最久未使用项', () {
      final cache = MessageTimelineCache.shared;
      cache.remember('@a:test', 'room-1', messageOf('event-1', '甲的消息'));
      expect(cache.lookup('@a:test', 'room-1', 'event-1')!.text, '甲的消息');
      expect(cache.lookup('@b:test', 'room-1', 'event-1'), isNull,
          reason: '切换账号不得读到上一账号的消息投影');
      expect(cache.lookup('@a:test', 'room-2', 'event-1'), isNull,
          reason: '不同房间不得互相命中');
      for (var i = 0; i < MessageTimelineCache.defaultCapacity + 8; i++) {
        cache.remember('@a:test', 'room-1', messageOf('bulk-$i', '消息 $i'));
      }
      expect(cache.length, lessThanOrEqualTo(MessageTimelineCache.defaultCapacity));
      expect(cache.lookup('@a:test', 'room-1', 'event-1'), isNull,
          reason: '最早的投影被淘汰');
    });
  });

  group('QuotePreviewCard 五种状态', () {
    testWidgets('loading → 原消息加载中…', (tester) async {
      await tester.pumpWidget(
          _card(resolution: const ReplyMessageResolution.loading()));
      expect(find.text('原消息加载中…'), findsOneWidget);
      expect(find.byKey(const Key('reply-preview-event-target')), findsOneWidget);
    });

    testWidgets('loaded → 显示名 + 摘要（超过 10 字加省略号）', (tester) async {
      final target = messageOf('event-target', '你好，这是一条很长的原消息内容');
      await tester.pumpWidget(_card(
        resolution: ReplyMessageResolution.resolved(target),
        message: target,
      ));
      expect(truncateQuoteText('你好，这是一条很长的原消息内容'), '你好，这是一条很长的...');
      expect(find.text('张三：你好，这是一条很长的...'), findsOneWidget);
    });

    testWidgets('选中片段引用优先于原消息摘要', (tester) async {
      await tester.pumpWidget(_card(
        resolution: const ReplyMessageResolution.loading(),
        excerpt: '选中的十个字以内',
      ));
      expect(find.text('张三：选中的十个字以内'), findsOneWidget);
    });

    testWidgets('notFound / permissionDenied / networkError 各有明确文案',
        (tester) async {
      await tester.pumpWidget(
          _card(resolution: const ReplyMessageResolution.notFound()));
      expect(find.text('原消息不存在或已被删除'), findsOneWidget);

      await tester.pumpWidget(
          _card(resolution: const ReplyMessageResolution.permissionDenied()));
      expect(find.text('无权查看原消息'), findsOneWidget);

      await tester.pumpWidget(
          _card(resolution: const ReplyMessageResolution.networkError()));
      expect(find.text('原消息加载失败，点击重试'), findsOneWidget);
    });

    testWidgets('网络失败：点击触发重试而不是跳转；成功后回到跳转', (tester) async {
      var retries = 0;
      var jumps = 0;
      await tester.pumpWidget(_card(
        resolution: const ReplyMessageResolution.networkError(),
        onTap: () => jumps++,
        onRetry: () => retries++,
      ));
      await tester.tap(find.byKey(const Key('reply-preview-event-target')));
      await tester.pump();
      expect(retries, 1);
      expect(jumps, 0, reason: '失败态点击必须先重试，不能假装能跳转');

      final target = messageOf('event-target', '原消息');
      await tester.pumpWidget(_card(
        resolution: ReplyMessageResolution.resolved(target),
        message: target,
        onTap: () => jumps++,
        onRetry: () => retries++,
      ));
      await tester.tap(find.byKey(const Key('reply-preview-event-target')));
      await tester.pump();
      expect(jumps, 1);
      expect(retries, 1, reason: '成功态点击跳转到原消息');
    });

    testWidgets('无权限不可重试：点击保持跳转语义且无重试图标', (tester) async {
      var retries = 0;
      await tester.pumpWidget(_card(
        resolution: const ReplyMessageResolution.permissionDenied(),
        onRetry: () => retries++,
      ));
      await tester.tap(find.byKey(const Key('reply-preview-event-target')));
      await tester.pump();
      expect(retries, 0);
    });
  });
}
