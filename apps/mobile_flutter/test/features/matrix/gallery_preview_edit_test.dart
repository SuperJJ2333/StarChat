import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_image_editor.dart';

/// 分页相册桩（与 image_picker_page_test 同构）。
final class FakePager extends DeviceGalleryPager {
  FakePager(this.pages);

  final List<List<GalleryPhoto>> pages;
  int served = 0;

  @override
  bool get hasMore => served < pages.length;

  @override
  Future<List<GalleryPhoto>> loadNextPage({int pageSize = 20}) async =>
      served >= pages.length ? const [] : pages[served++];
}

/// 真实可解码的 2×2 PNG（编辑器会真正解码，不能用占位字节）。
Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 2, 2),
      Paint()..color = const Color(0xFFFFFFFF));
  final picture = recorder.endRecording();
  final image = await picture.toImage(2, 2);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

GalleryPhoto _photo(String id, Uint8List bytes) => GalleryPhoto(
    id: id,
    thumbnail: bytes,
    compressedBytes: () async => bytes,
    originalBytes: () async => bytes);

Future<void> _waitForEditor(WidgetTester tester) async {
  for (var attempt = 0; attempt < 25; attempt++) {
    // 必须带上时长推进：编辑器是从底部滑入的路由，只 pump() 不推进动画
    // 会让导航栏停在屏幕外（按钮存在但点不到）。
    await tester.pump(const Duration(milliseconds: 40));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    if (find.byType(WeChatImageEditorPage).evaluate().isNotEmpty &&
        find.byKey(const Key('image-editor-done')).evaluate().isNotEmpty) {
      await _settleRoute(tester);
      return;
    }
  }
  expect(find.byKey(const Key('image-editor-done')), findsOneWidget);
}

/// 交替推进假时钟与真实异步：路由过渡、弹层收起、PNG 编码三者都要等。
Future<void> _drain(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 40));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)));
  }
}

/// Cupertino 全屏路由的进出场各约 500ms，且编码/解密需要真实异步时间，
/// 所以按「假时钟 + 真实异步」交替推进足够多轮。
Future<void> _settleRoute(WidgetTester tester) => _drain(tester, rounds: 25);

/// 竖屏手机尺寸：编辑器在 600pt 高的默认测试画布上会挤出底部操作栏。
Future<void> _phoneSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

/// 点击单元格进入大图预览。
///
/// 单元格左上角 56×80 是勾选圆圈的点击区（规格要求「点击预览 / 勾选分离」），
/// 窄屏下单元格中心会落在该区域内，所以这里点右半边。
Future<void> _openPreview(WidgetTester tester, String photoId) async {
  final rect =
      tester.getRect(find.byKey(Key('image-picker-item-$photoId')));
  await tester.tapAt(Offset(rect.right - 12, rect.center.dy));
  await _settleRoute(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GalleryAccessCache.invalidateAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.fluttercandies/photo_manager'),
            (call) async {
      if (call.method == 'getPermissionState' ||
          call.method == 'requestPermissionExtend') {
        return PermissionStateStub.authorized;
      }
      if (call.method == 'notify') return true;
      throw MissingPluginException();
    });
  });

  testWidgets('相册 → 查看大图 → 编辑：三枚操作按「编辑 选择 闪照」排列，编辑可进入编辑器',
      (tester) async {
    await _phoneSurface(tester);
    final png = (await tester.runAsync(_png))!;
    final photo = _photo('device-photo', png);
    await tester.pumpWidget(CupertinoApp(
        home: ImagePickerPage(
            albumsLoader: () async => [],
            pagerBuilder: () => FakePager([
                  [photo]
                ]))));
    await tester.pumpAndSettle();

    await _openPreview(tester, 'device-photo');

    final edit = find.byKey(const Key('gallery-preview-edit'));
    final select = find.byKey(const Key('gallery-preview-select'));
    final flash = find.byKey(const Key('gallery-preview-flash'));
    expect(edit, findsOneWidget);
    expect(select, findsOneWidget);
    expect(flash, findsOneWidget);
    expect(tester.getRect(edit).left, lessThan(tester.getRect(select).left));
    expect(tester.getRect(select).left, lessThan(tester.getRect(flash).left),
        reason: '底部操作顺序必须是 编辑 → 选择 → 闪照');

    await tester.tap(edit);
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await _waitForEditor(tester);

    expect(find.byType(WeChatImageEditorPage), findsOneWidget,
        reason: '相册大图点击「编辑」必须进入图片编辑器');
    expect(find.byKey(const Key('image-editor-crop')), findsOneWidget);
    // 原图字节未被编辑入口修改。
    expect(await photo.originalBytes(), png);
  });

  testWidgets('编辑 → 发送：以新的媒体对象结束选择器，原图不被覆盖', (tester) async {
    await _phoneSurface(tester);
    final png = (await tester.runAsync(_png))!;
    final photo = _photo('device-photo', png);
    ({List<GalleryPhoto> photos, bool original, bool flash})? result;
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoPageScaffold(
                child: Center(
                    child: CupertinoButton(
                        key: const Key('host-open-gallery'),
                        onPressed: () async {
                          result = await Navigator.of(context).push<
                              ({List<GalleryPhoto> photos, bool original, bool flash})>(
                            CupertinoPageRoute(
                                builder: (_) => ImagePickerPage(
                                    albumsLoader: () async => [],
                                    pagerBuilder: () => FakePager([
                                          [photo]
                                        ]))),
                          );
                        },
                        child: const Text('打开相册')))))));
    await tester.tap(find.byKey(const Key('host-open-gallery')));
    await _settleRoute(tester);
    expect(result, isNull);

    await _openPreview(tester, 'device-photo');
    await tester.tap(find.byKey(const Key('gallery-preview-edit')));
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await _waitForEditor(tester);

    await tester.tap(find.byKey(const Key('image-editor-done')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('发送'), findsOneWidget,
        reason: '相册编辑必须提供「发送」把结果作为新媒体对象交回');
    await tester.tap(find.text('发送'));
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)));
    await _settleRoute(tester);

    expect(find.byType(ImagePickerPage), findsNothing,
        reason: '发送编辑结果后选择器应当关闭');
    expect(result, isNotNull);
    final sent = result!.photos.single;
    expect(sent.id, startsWith('edited-'),
        reason: '编辑产生的是**新的**媒体对象，不是设备原照片');
    expect(sent.mimeType, 'image/png');
    expect(sent.isVideo, isFalse);
    expect(await sent.originalBytes(), isNotEmpty);
    expect(result!.original, isTrue);
    expect(result!.flash, isFalse);
    // 设备原照片保持原样（未被覆盖）。
    expect(await photo.compressedBytes(), png);
    expect(await photo.originalBytes(), png);
  });

  testWidgets('编辑页取消：回到相册预览且不产生任何媒体对象', (tester) async {
    await _phoneSurface(tester);
    final png = (await tester.runAsync(_png))!;
    final photo = _photo('device-photo', png);
    await tester.pumpWidget(CupertinoApp(
        home: ImagePickerPage(
            albumsLoader: () async => [],
            pagerBuilder: () => FakePager([
                  [photo]
                ]))));
    await tester.pumpAndSettle();
    await _openPreview(tester, 'device-photo');
    await tester.tap(find.byKey(const Key('gallery-preview-edit')));
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await _waitForEditor(tester);

    await tester.tap(find.byKey(const Key('image-editor-cancel')));
    await _settleRoute(tester);

    expect(find.byType(WeChatImageEditorPage), findsNothing);
    expect(find.byKey(const Key('gallery-preview-edit')), findsOneWidget,
        reason: '取消后回到相册大图预览');
    expect(find.byKey(const Key('gallery-preview-select')), findsOneWidget);
    expect(find.byKey(const Key('gallery-preview-flash')), findsOneWidget);
  });
}

/// photo_manager 权限枚举的最小映射（避免测试依赖插件内部常量）。
abstract final class PermissionStateStub {
  static const authorized = 3;
}
