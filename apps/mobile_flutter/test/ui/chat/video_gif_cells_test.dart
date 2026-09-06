import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_session_cache.dart';
import 'package:liuhetong_mobile/ui/chat/video_gif_cells.dart';

/// 规格 #1/#9 UI 接线：视频封面会话缓存 + GIF 播放门控。
void main() {
  final poster = Uint8List.fromList(List.filled(64, 7));

  group('#1 VideoPosterCell', () {
    testWidgets('首次加载显示封面（含播放按钮）', (tester) async {
      final cache = VideoPosterSessionCache();
      await tester.pumpWidget(CupertinoApp(
        home: Center(
          child: VideoPosterCell(
            cache: cache,
            cacheKey: 'a|r|m|v1|grid',
            loadPoster: () async => poster,
            duration: const Duration(seconds: 65),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('video-poster-loaded')), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);
      expect(find.text('1:05'), findsOneWidget, reason: '时长角标');
    });

    testWidgets('滚动移出/移入 10 次：loadPoster 只执行 1 次', (tester) async {
      var loads = 0;
      final cache = VideoPosterSessionCache();
      await tester.pumpWidget(CupertinoApp(
        home: Center(
          child: VideoPosterCell(
            cache: cache,
            cacheKey: 'a|r|m2|v1|grid',
            loadPoster: () async {
              loads++;
              return poster;
            },
          ),
        ),
      ));
      await tester.pumpAndSettle();
      // 重建 cell 10 次（模拟移出/移入、退出/重进）。
      for (var i = 0; i < 10; i++) {
        await tester.pumpWidget(CupertinoApp(
          home: Center(
            child: VideoPosterCell(
              cache: cache,
              cacheKey: 'a|r|m2|v1|grid',
              loadPoster: () async {
                loads++;
                return poster;
              },
            ),
          ),
        ));
        await tester.pumpAndSettle();
      }
      expect(loads, 1,
          reason: '验收：连续移出/移入 10 次新增网络请求 0、首帧重提 0');
    });

    testWidgets('加载失败：显示重试入口（可点击重新加载）', (tester) async {
      final cache = VideoPosterSessionCache();
      var fail = true;
      Widget build() => CupertinoApp(
            home: Center(
              child: VideoPosterCell(
                cache: cache,
                cacheKey: 'a|r|m3|v1|grid',
                loadPoster: () async =>
                    fail ? throw StateError('network') : poster,
              ),
            ),
          );
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('video-poster-retry')), findsOneWidget);

      fail = false;
      await tester.tap(find.byKey(const Key('video-poster-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('video-poster-loaded')), findsOneWidget,
          reason: '手动重试后恢复');
    });
  });

  group('#9 AnimatedImageCell', () {
    final gifBytes = Uint8List.fromList(List.filled(32, 9));

    testWidgets('多帧 GIF 默认渲染（可见+前台）', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: Center(
          child: AnimatedImageCell(
            bytes: gifBytes,
            signatureIsGif: true,
            frameCount: 12,
          ),
        ),
      ));
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('gif-manual-play')), findsNothing,
          reason: '自动播放开启时不显示手动按钮');
    });

    testWidgets('自动播放关闭：显示手动播放按钮；点击后播放', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: Center(
          child: AnimatedImageCell(
            bytes: gifBytes,
            signatureIsGif: true,
            frameCount: 12,
            autoPlayEnabled: false,
          ),
        ),
      ));
      expect(find.byKey(const Key('gif-manual-play')), findsOneWidget);
      await tester.tap(find.byKey(const Key('gif-manual-play')));
      await tester.pump();
      expect(find.byKey(const Key('gif-manual-play')), findsNothing,
          reason: '手动启动后按钮消失');
    });

    testWidgets('未获准下载：显示"点击加载 GIF"', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: Center(
          child: AnimatedImageCell(
            bytes: gifBytes,
            signatureIsGif: true,
            frameCount: 12,
            mediaDownloadAllowed: false,
          ),
        ),
      ));
      expect(find.byKey(const Key('gif-tap-to-load')), findsOneWidget);
      expect(find.text('点击加载 GIF'), findsOneWidget);
    });

    testWidgets('单帧 GIF：无动画/无播放按钮（正常静态显示）', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: Center(
          child: AnimatedImageCell(
            bytes: gifBytes,
            signatureIsGif: true,
            frameCount: 1,
            autoPlayEnabled: false,
          ),
        ),
      ));
      expect(find.byKey(const Key('gif-manual-play')), findsNothing,
          reason: '单帧 GIF 不需要播放控制');
    });
  });

  group('#9 GifAutoPlaySetting', () {
    testWidgets('开关状态与回调', (tester) async {
      var value = true;
      await tester.pumpWidget(CupertinoApp(
        home: Center(
          child: GifAutoPlaySetting(
            enabled: value,
            onChanged: (v) => value = v,
          ),
        ),
      ));
      expect(find.byKey(const Key('gif-autoplay-switch')), findsOneWidget);
      await tester.tap(find.byKey(const Key('gif-autoplay-switch')));
      await tester.pump();
      expect(value, isFalse, reason: '切换关闭');
    });
  });
}
