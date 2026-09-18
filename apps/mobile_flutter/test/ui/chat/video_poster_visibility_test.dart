import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_video_message.dart';

/// 可见性门控验收（Phase 1）。
///
/// 验收标准：
/// - 视频列表首屏不触发全部视频处理；
/// - 只有「可见区域 + 即将进入区域（±[kVideoPosterWarmRows] 行）」才生成封面。

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 4, 4),
      Paint()..color = const Color(0xFF00FF66));
  final picture = recorder.endRecording();
  final image = await picture.toImage(4, 4);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// 两帧：第一帧完成布局，第二帧跑完可见性判定的帧后回调。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  late Uint8List poster;
  setUp(() async {
    poster = Uint8List(0);
  });

  testWidgets('Test 1：有 poster 时进入聊天立即显示封面（加载一次）',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bytes = (await tester.runAsync(_png))!;
    var loads = 0;

    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child: VideoMessageCard(
          duration: const Duration(seconds: 12),
          onOpen: () {},
          posterLoader: () async {
            loads++;
            return bytes;
          },
        ),
      ),
    ));
    await _settle(tester);

    expect(loads, 1);
    expect(find.byType(Image), findsOneWidget, reason: '封面已渲染');
    expect(find.byIcon(CupertinoIcons.play_arrow_solid), findsOneWidget);
    expect(find.text('0:12'), findsOneWidget);
  });

  testWidgets('Test 2：无 poster 先显示占位，生成完成后更新为封面',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bytes = (await tester.runAsync(_png))!;
    final gate = Completer<Uint8List?>();

    await tester.pumpWidget(CupertinoApp(
      home: Center(
        child: VideoMessageCard(
          duration: null,
          onOpen: () {},
          posterLoader: () => gate.future,
        ),
      ),
    ));
    await _settle(tester);

    expect(find.byIcon(CupertinoIcons.videocam_fill), findsOneWidget,
        reason: '生成完成前显示占位底');
    expect(find.byType(Image), findsNothing);

    gate.complete(bytes);
    await _settle(tester);

    expect(find.byType(Image), findsOneWidget, reason: '生成完成后更新为封面');
    expect(poster, isEmpty);
  });

  testWidgets('窗口外（±5 行以外）不加载封面；滚入窗口后才加载', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final loads = <String>{};
    final controller = ScrollController();
    addTearDown(controller.dispose);

    Widget card(String id) => SizedBox(
          height: kVideoPosterRowExtent,
          child: VideoMessageCard(
            duration: null,
            onOpen: () {},
            posterIdentity: id,
            posterLoader: () async {
              loads.add(id);
              return null;
            },
          ),
        );

    // cacheExtent 放大到「全部子项都被构建」：这样才能证明过滤是由
    // 可见性门控完成，而不是靠 Flutter 的懒构建。
    await tester.pumpWidget(CupertinoApp(
      home: ListView(
        controller: controller,
        scrollCacheExtent: const ScrollCacheExtent.pixels(100000),
        children: [
          const SizedBox(height: 3000),
          card('A'),
          const SizedBox(height: 3000),
        ],
      ),
    ));
    await _settle(tester);
    expect(loads, isEmpty,
        reason: '卡片已构建但在窗口外（视口 600 + 前瞻 790 远不及 3000），不得加载');

    controller.jumpTo(3000 - 200);
    await _settle(tester);
    expect(loads, contains('A'), reason: '滚入可见区域后加载');
  });

  testWidgets('前瞻缓冲边界：缓冲内加载、缓冲外不加载', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final loads = <String>{};

    Widget card(String id) => SizedBox(
          height: kVideoPosterRowExtent,
          child: VideoMessageCard(
            duration: null,
            onOpen: () {},
            posterIdentity: id,
            posterLoader: () async {
              loads.add(id);
              return null;
            },
          ),
        );

    // 视口 = 0..600；前瞻下界 = 600 + 790 = 1390。
    // 卡片 A：内容 y=1000（缓冲内）；卡片 B：内容 y=1800（缓冲外）。
    final gap = 1800 - (1000 + kVideoPosterRowExtent);
    await tester.pumpWidget(CupertinoApp(
      home: ListView(
        scrollCacheExtent: const ScrollCacheExtent.pixels(100000),
        children: [
          const SizedBox(height: 1000),
          card('A'),
          SizedBox(height: gap),
          card('B'),
          const SizedBox(height: 1000),
        ],
      ),
    ));
    await _settle(tester);

    expect(loads, contains('A'),
        reason: '视口下方 400pt（±5 行缓冲内）应当预热');
    expect(loads, isNot(contains('B')),
        reason: '视口下方 1200pt（缓冲外）不得生成封面');
  });

  testWidgets('Test 4：100 个视频消息 + 快速滚动，不会全部生成封面',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final loads = <String>{};
    final controller = ScrollController();
    addTearDown(controller.dispose);

    Widget list({double? cacheExtent}) => CupertinoApp(
          home: ListView.builder(
            controller: controller,
            scrollCacheExtent: cacheExtent == null
                ? null
                : ScrollCacheExtent.pixels(cacheExtent),
            itemCount: 100,
            itemBuilder: (_, index) => SizedBox(
              height: kVideoPosterRowExtent,
              child: VideoMessageCard(
                duration: null,
                onOpen: () {},
                posterIdentity: 'v$index',
                posterLoader: () async {
                  loads.add('v$index');
                  return null;
                },
              ),
            ),
          ),
        );

    // ① 极端情形：把 cacheExtent 放大到能构建全部 100 行，
    //    证明「过滤」确实由可见性门控完成，而不是靠懒构建。
    await tester.pumpWidget(list(cacheExtent: 100000));
    await _settle(tester);
    expect(loads, contains('v0'));
    expect(loads, isNot(contains('v20')),
        reason: '缓冲外的第 20 行不得生成封面');
    expect(loads.length, lessThan(20),
        reason: '首屏只处理「可见 + ±5 行」，而不是 100 行');
    final firstScreen = loads.length;

    // ② 快速滚动到底部（一次跳到底，等价于快速滑动）：只有新进入窗口的行
    //    才被处理；累计仍远少于全量。
    controller.jumpTo(controller.position.maxScrollExtent);
    await _settle(tester);
    expect(loads.length, greaterThan(firstScreen),
        reason: '滚动后新进入窗口的行应当被处理');
    expect(loads.contains('v99'), isTrue,
        reason: '滚到末尾后最后一行可见并处理');
    expect(loads.length, lessThan(40),
        reason: '100 条视频消息快速滚动后仍远少于全量处理');
  });
}
