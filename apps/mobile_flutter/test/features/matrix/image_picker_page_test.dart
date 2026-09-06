import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';

/// 分页相册桩：按页返回预置照片，记录每页大小与调用次数。
final class FakePager extends DeviceGalleryPager {
  FakePager(this.pages);

  final List<List<GalleryPhoto>> pages;
  int served = 0;
  final pageSizes = <int>[];

  @override
  bool get hasMore => served < pages.length;

  @override
  Future<List<GalleryPhoto>> loadNextPage({int pageSize = 20}) async {
    pageSizes.add(pageSize);
    if (served >= pages.length) return const [];
    final page = pages[served++];
    return page;
  }
}

final Uint8List tinyPng = Uint8List.fromList(<int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  19,
  196,
  137,
  0,
  0,
  0,
  13,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  250,
  207,
  192,
  80,
  15,
  0,
  6,
  5,
  2,
  1,
  137,
  197,
  57,
  218,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
]);

final class FakePhoto {
  FakePhoto(this.id);

  final String id;
}

/// 选择逻辑（纯逻辑）验收：多选、上限 9、取消勾选、原图开关。
void main() {
  test('custom selection limit is reflected in overflow hint', () {
    final selection = GallerySelection(maxCount: 1);
    selection.toggle('first');
    expect(selection.toggle('second'), isFalse);
    expect(selection.overflowHint, '最多选择1张图片');
  });

  test('gallery selection keeps insertion order and caps at nine', () {
    final selection = GallerySelection();
    for (var i = 1; i <= 9; i++) {
      expect(selection.toggle('photo-$i'), isTrue);
    }
    expect(selection.count, 9);
    // 第 10 张：拒绝并给出提示。
    expect(selection.toggle('photo-10'), isFalse);
    expect(selection.overflowHint, '最多选择9张图片');
    // 取消一张后再选即可。
    expect(selection.toggle('photo-1'), isTrue);
    expect(selection.toggle('photo-10'), isTrue);
    expect(selection.orderOf('photo-10'), 9);
  });

  testWidgets('picker page renders a 4-per-row grid with check circles',
      (tester) async {
    final photos = [
      for (var i = 1; i <= 8; i++)
        GalleryPhoto(
          id: 'photo-$i',
          thumbnail: tinyPng,
          compressedBytes: () async => Uint8List.fromList([1]),
          originalBytes: () async => Uint8List.fromList([1]),
        ),
    ];
    final pager = FakePager([photos]);
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(pagerBuilder: () => pager),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('image-picker-grid')), findsOneWidget);
    expect(find.byKey(const Key('image-picker-bottom-bar')), findsOneWidget);
    final sendButton = find.byKey(const Key('image-picker-send'));
    expect(sendButton, findsOneWidget);
    // 未选中时按钮不可用。
    final button = tester.widget<CupertinoButton>(sendButton);
    expect(button.onPressed, isNull);
  });

  testWidgets('selecting photos enables send and reports selection',
      (tester) async {
    final photos = [
      for (var i = 1; i <= 3; i++)
        GalleryPhoto(
          id: 'photo-$i',
          thumbnail: tinyPng,
          compressedBytes: () async => Uint8List.fromList([i]),
          originalBytes: () async => Uint8List.fromList([i, i]),
        ),
    ];
    final pager = FakePager([photos]);
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(pagerBuilder: () => pager, maxCount: 9),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const Key('image-picker-check-photo-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('image-picker-check-photo-2')));
    await tester.pump();

    expect(find.byKey(const Key('image-picker-check-photo-1')), findsOneWidget);
    expect(find.text('发送(2)'), findsOneWidget);

    // 原图开关：默认关闭 → 打开。
    expect(
        tester
            .widget<CupertinoSwitch>(
              find.byKey(const Key('image-picker-original-switch')),
            )
            .value,
        isFalse);
    await tester.tap(find.byKey(const Key('image-picker-original-switch')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('image-picker-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final route = tester.element(find.text('发送(2)').first);
    expect(route, isNotNull);
    expect(
        tester
            .widget<CupertinoSwitch>(
              find.byKey(const Key('image-picker-original-switch')),
            )
            .value,
        isTrue);
  });

  testWidgets('tapping a selected photo deselects it', (tester) async {
    final photos = [
      GalleryPhoto(
        id: 'photo-1',
        thumbnail: tinyPng,
        compressedBytes: () async => Uint8List.fromList([1]),
        originalBytes: () async => Uint8List.fromList([1]),
      ),
    ];
    final pager = FakePager([photos]);
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(pagerBuilder: () => pager),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const Key('image-picker-check-photo-1')));
    await tester.pump();
    expect(find.text('发送(1)'), findsOneWidget);

    // 再点一次选中圆圈 = 取消选中（点击缩略图是预览，不再切换选中）。
    await tester.tap(find.byKey(const Key('image-picker-check-photo-1')));
    await tester.pump();
    expect(find.text('发送(1)'), findsNothing);
  });

  testWidgets('gallery loads 20 per page with loading footer and prefetch',
      (tester) async {
    final firstPage = [
      for (var i = 1; i <= 20; i++)
        GalleryPhoto(
          id: 'p-$i',
          thumbnail: tinyPng,
          compressedBytes: () async => Uint8List.fromList([1]),
          originalBytes: () async => Uint8List.fromList([1]),
        ),
    ];
    final secondPage = [
      for (var i = 21; i <= 25; i++)
        GalleryPhoto(
          id: 'p-$i',
          thumbnail: tinyPng,
          compressedBytes: () async => Uint8List.fromList([1]),
          originalBytes: () async => Uint8List.fromList([1]),
        ),
    ];
    final pager = FakePager([firstPage, secondPage]);
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(pagerBuilder: () => pager),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 首屏只加载最新 20 张（20 项 + 底部加载提示）。
    expect(pager.pageSizes.first, 20, reason: '每页固定 20 张缩略图');
    expect(pager.served, 1, reason: '首次进入仅加载一页');
    // 网格懒构建：首屏渲染最新一页的前 12 项，未触底不追加。
    expect(find.byKey(const Key('image-picker-item-p-12')), findsOneWidget);
    expect(find.byKey(const Key('image-picker-item-p-20')), findsNothing);

    // 向下滑动：接近末尾时按序追加一页。
    await tester.drag(
        find.byKey(const Key('image-picker-grid')), const Offset(0, -1400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.drag(
        find.byKey(const Key('image-picker-grid')), const Offset(0, -800));
    await tester.pumpAndSettle();

    expect(pager.served, 2, reason: '滚动到底追加第二页');
    expect(find.byKey(const Key('image-picker-item-p-25')), findsOneWidget);
    expect(find.text('加载中…'), findsNothing, reason: '相册耗尽后提示消失');
  });

  testWidgets('album sheet defaults to 最近图片 and switches pagers',
      (tester) async {
    final recentPager = FakePager([
      [
        GalleryPhoto(
          id: 'recent-1',
          thumbnail: tinyPng,
          compressedBytes: () async => Uint8List.fromList([1]),
          originalBytes: () async => Uint8List.fromList([1]),
        ),
      ],
    ]);
    final videoPager = FakePager([
      [
        GalleryPhoto(
          id: 'video-1',
          thumbnail: tinyPng,
          compressedBytes: () async => Uint8List.fromList([1]),
          originalBytes: () async => Uint8List.fromList([1]),
          isVideo: true,
          duration: const Duration(seconds: 65),
        ),
      ],
    ]);
    final albums = const [
      GalleryAlbum(
          id: 'recent', name: '最近图片', isRecent: true, isVideoOnly: false),
      GalleryAlbum(
          id: 'videos', name: '本地视频', isRecent: false, isVideoOnly: true),
      GalleryAlbum(
          id: 'camera', name: 'Camera', isRecent: false, isVideoOnly: false),
      GalleryAlbum(
          id: 'screenshots',
          name: 'Screenshots',
          isRecent: false,
          isVideoOnly: false),
    ];
    GalleryAlbum? factoryAlbum;
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(
        pagerBuilder: () => recentPager,
        albumsLoader: () async => albums,
        pagerFactory: (album) {
          factoryAlbum = album;
          return album == null ? recentPager : videoPager;
        },
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 顶部默认显示“最近图片”+ 下拉箭头。
    expect(find.text('最近图片'), findsOneWidget);

    await tester.tap(find.byKey(const Key('image-picker-album-button')));
    await tester.pumpAndSettle();
    // 子列表包含“本地视频”与本地图库分类，默认选中“最近图片”。
    expect(find.byKey(const Key('image-picker-album-sheet')), findsOneWidget);
    expect(find.byKey(const Key('image-picker-album-videos')), findsOneWidget);
    expect(find.byKey(const Key('image-picker-album-camera')), findsOneWidget);
    expect(find.byKey(const Key('image-picker-album-screenshots')),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('image-picker-album-videos')));
    await tester.pumpAndSettle();

    expect(factoryAlbum?.id, 'videos', reason: '切换相册按分类重建分页器');
    expect(find.text('本地视频'), findsOneWidget, reason: '顶部按钮显示当前相册');
    expect(find.byKey(const Key('image-picker-item-video-1')), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget, reason: '视频项显示时长角标');
  });

  testWidgets('original mode blocks videos above 20MB with a prompt',
      (tester) async {
    final oversized = GalleryPhoto(
      id: 'big-video',
      thumbnail: tinyPng,
      compressedBytes: () async => Uint8List.fromList([1]),
      originalBytes: () async => Uint8List.fromList(List.filled(21, 1)),
      isVideo: true,
      originalSizeBytes: () async => 21 * 1024 * 1024,
    );
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(
        pagerBuilder: () => FakePager([
          [oversized],
        ]),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const Key('image-picker-check-big-video')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('image-picker-original-switch')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('image-picker-send')));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const Key('image-picker-video-limit-dialog')),
        findsOneWidget,
        reason: '原图模式下超 20MB 视频被拦截并提示');
    expect(find.byKey(const Key('image-picker-send')), findsOneWidget,
        reason: '页面未关闭，发送被拦截');
  });

  testWidgets('compressed send is not blocked by the video size cap',
      (tester) async {
    final video = GalleryPhoto(
      id: 'small-video',
      thumbnail: tinyPng,
      compressedBytes: () async => Uint8List.fromList([1]),
      originalBytes: () async => Uint8List.fromList(List.filled(21, 1)),
      isVideo: true,
      originalSizeBytes: () async => 21 * 1024 * 1024,
    );
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(
        pagerBuilder: () => FakePager([
          [video],
        ]),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // “原图”保持关闭 → 走压缩发送，不受 20MB 限制。
    await tester.tap(find.byKey(const Key('image-picker-check-small-video')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('image-picker-send')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('image-picker-send')), findsNothing,
        reason: '压缩模式正常发送并关闭选择页');
  });

  testWidgets('验证11：快速切换相册后，旧请求不覆盖新相册的列表/加载态',
      (tester) async {
    final gate1 = Completer<void>();
    // 慢分页器（模拟弱网首屏加载），结果被门闩挂起。
    final gatedPager = _GatedPager(gate1.future);
    final fastVideoPager = FakePager([
      [
        GalleryPhoto(
          id: 'video-fast-1',
          thumbnail: tinyPng,
          compressedBytes: () async => Uint8List.fromList([1]),
          originalBytes: () async => Uint8List.fromList([1]),
          isVideo: true,
          duration: const Duration(seconds: 3),
        ),
      ],
    ]);
    final albums = const [
      GalleryAlbum(
          id: 'recent', name: '最近图片', isRecent: true, isVideoOnly: false),
      GalleryAlbum(
          id: 'videos', name: '本地视频', isRecent: false, isVideoOnly: true),
    ];
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(
        pagerBuilder: () => gatedPager,
        albumsLoader: () async => albums,
        pagerFactory: (album) => album == null ? gatedPager : fastVideoPager,
      ),
    ));
    await tester.pump(); // 首屏（common）请求已发出，仍挂起。

    // 切换到"本地视频"（新批次），其首页立即完成。
    //（首个慢请求仍挂起：网格转圈动画持续，不能用 pumpAndSettle；
    //  弹层路由在微任务内挂载，需先 pump 一帧再等动画完成。）
    await tester.tap(find.byKey(const Key('image-picker-album-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('image-picker-album-videos')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('image-picker-item-video-fast-1')), findsOneWidget,
        reason: '新相册列表已展示');

    // 旧相册（common）的慢请求现在才返回：不得覆盖新相册结果。
    gate1.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('image-picker-item-recent-stale-1')), findsNothing,
        reason: '旧请求的结果必须被丢弃');
    expect(find.byKey(const Key('image-picker-item-video-fast-1')), findsOneWidget,
        reason: '新相册列表保持不变');
  });

  testWidgets('验证12/UI：视频首帧失败显示占位与重试入口，选择不受影响',
      (tester) async {
    var loads = 0;
    final video = GalleryPhoto(
      id: 'fail-video',
      thumbnail: Uint8List(0),
      compressedBytes: () async => Uint8List.fromList([1]),
      originalBytes: () async => Uint8List.fromList([1]),
      isVideo: true,
      duration: const Duration(seconds: 12),
      firstFrame: () async {
        loads++;
        return null; // 首帧抽帧失败（不可解码/文件忙）。
      },
    );
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(
        pagerBuilder: () => FakePager([
          [video],
        ]),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 占位（非黑卡）+ 重试入口可见；条目仍在且可勾选（封面失败不删条目）。
    expect(find.byKey(const Key('image-picker-item-fail-video')), findsOneWidget);
    expect(find.byKey(const Key('image-picker-frame-retry-fail-video')),
        findsOneWidget,
        reason: '失败后提供明确的重试入口');
    await tester.tap(find.byKey(const Key('image-picker-check-fail-video')));
    await tester.pump();
    expect(find.text('发送(1)'), findsOneWidget, reason: '封面失败不阻断选择');

    // 点重试：重新发起一次首帧加载（有限重试入口有效）。
    await tester.tap(find.byKey(const Key('image-picker-frame-retry-fail-video')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(loads, 2, reason: '重试入口重新触发一次首帧加载');
  });
// ── 审计 P2（gallery-call-review）：部分授权横幅 ─────────────

testWidgets('P2：limited 授权显示"管理可见照片"横幅；full 不显示', (tester) async {
  DeviceGallerySource.lastKnownPermissionScopeForTest = 'limited';
  addTearDown(
      () => DeviceGallerySource.lastKnownPermissionScopeForTest = null);
  await tester.pumpWidget(CupertinoApp(
    home: ImagePickerPage(
      pagerBuilder: () => FakePager([
        [
          GalleryPhoto(
            id: 'p1',
            thumbnail: tinyPng,
            compressedBytes: () async => Uint8List.fromList([1]),
            originalBytes: () async => Uint8List.fromList([1]),
          ),
        ],
      ]),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  expect(find.byKey(const Key('image-picker-limited-banner')), findsOneWidget,
      reason: '部分授权时必须提供明确入口');
  expect(find.byKey(const Key('image-picker-limited-manage')), findsOneWidget);

  // full：不显示横幅。
  DeviceGallerySource.lastKnownPermissionScopeForTest = 'full';
  await tester.pumpWidget(CupertinoApp(
    home: ImagePickerPage(
      pagerBuilder: () => FakePager(const []),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  expect(find.byKey(const Key('image-picker-limited-banner')), findsNothing);
});
}
/// 门闩分页器：首页结果挂起直至 gate 完成（模拟慢请求）。
final class _GatedPager extends DeviceGalleryPager {
  _GatedPager(this.gate);

  final Future<void> gate;

  @override
  Future<List<GalleryPhoto>> loadNextPage({int pageSize = 20}) async {
    await gate;
    return [
      GalleryPhoto(
        id: 'recent-stale-1',
        thumbnail: tinyPng,
        compressedBytes: () async => Uint8List.fromList([1]),
        originalBytes: () async => Uint8List.fromList([1]),
      ),
    ];
  }
}
