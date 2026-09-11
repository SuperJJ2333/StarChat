import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/ui/chat/encrypted_media_view.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_image_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'late original from a replaced source cannot replace the new image',
      (tester) async {
    final old = Completer<Uint8List>();
    final fresh = Completer<Uint8List>();
    MediaConsumerScope? oldScope;
    try {
      await tester.pumpWidget(_viewer(
          identity: 'source-a',
          preview: _png(0x41),
          load: () {
            oldScope = MediaConsumerScope.current;
            return old.future;
          }));
      await tester.tap(find.byKey(const Key('viewer-view-original')));
      await tester.pump();
      expect(oldScope, isNotNull);

      await tester.pumpWidget(_viewer(
          identity: 'source-b', preview: _png(0x42), load: () => fresh.future));
      await tester.tap(find.byKey(const Key('viewer-view-original')));
      await tester.pump();
      expect(oldScope!.isActive, isFalse);
      await tester.runAsync(() async {
        fresh.complete(_png(0x43));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      await tester.pump();
      expect(_displayedBytes(tester), _png(0x43));

      await tester.runAsync(() async {
        old.complete(_png(0x41));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      await tester.pump();
      expect(_displayedBytes(tester), _png(0x43));
    } finally {
      if (!old.isCompleted) old.complete(_png(0x41));
      if (!fresh.isCompleted) fresh.complete(_png(0x42));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('inactive original work is cancelled and returns retry cleanly',
      (tester) async {
    final held = Completer<Uint8List>();
    MediaConsumerScope? firstScope;
    var calls = 0;
    Future<Uint8List> load() {
      calls++;
      firstScope ??= MediaConsumerScope.current;
      return calls == 1 ? held.future : Future.value(_png(0x42));
    }

    try {
      await tester.pumpWidget(
          _viewer(identity: 'source', preview: _png(0x41), load: load));
      await tester.tap(find.byKey(const Key('viewer-view-original')));
      await tester.pump();
      expect(firstScope, isNotNull);

      await tester.pumpWidget(_viewer(
          identity: 'source', preview: _png(0x41), load: load, active: false));
      await tester.pump();
      expect(firstScope!.isActive, isFalse);

      await tester.pumpWidget(
          _viewer(identity: 'source', preview: _png(0x41), load: load));
      await tester.tap(find.byKey(const Key('viewer-view-original')));
      await tester.pump();
      await tester.pump();
      expect(calls, 2);
      expect(find.text('原图加载失败，点击重试'), findsNothing);
      expect(_displayedBytes(tester), _png(0x42));
    } finally {
      if (!held.isCompleted) held.complete(_png(0x41));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('lifecycle and route cover cancel a held original owner',
      (tester) async {
    final held = Completer<Uint8List>();
    final scopes = <MediaConsumerScope?>[];
    try {
      await tester.pumpWidget(_viewer(
          identity: 'source',
          preview: _png(0x41),
          load: () {
            scopes.add(MediaConsumerScope.current);
            return held.future;
          }));
      await tester.tap(find.byKey(const Key('viewer-view-original')));
      await tester.pump();
      expect(scopes.single, isNotNull);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(scopes.single!.isActive, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      await tester.tap(find.byKey(const Key('viewer-view-original')));
      await tester.pump();
      expect(scopes, hasLength(2));
      expect(scopes.last, isNotNull);
      final routeContext = tester.element(find.byType(ImageViewerPage));
      Navigator.of(routeContext).push(CupertinoPageRoute<void>(
          builder: (_) => const CupertinoPageScaffold(child: SizedBox())));
      await tester.pumpAndSettle();
      expect(scopes.last!.isActive, isFalse);
      Navigator.of(routeContext).pop();
      await tester.pumpAndSettle();
    } finally {
      if (!held.isCompleted) held.complete(_png(0x41));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'disposing a held original cancels its owner without an exception',
      (tester) async {
    final held = Completer<Uint8List>();
    MediaConsumerScope? scope;
    try {
      await tester.pumpWidget(_viewer(
          identity: 'source',
          preview: _png(0x41),
          load: () {
            scope = MediaConsumerScope.current;
            return held.future;
          }));
      await tester.tap(find.byKey(const Key('viewer-view-original')));
      await tester.pump();
      expect(scope, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(scope!.isActive, isFalse);
      held.complete(_png(0x41));
      await tester.pump();
      expect(tester.takeException(), isNull);
    } finally {
      if (!held.isCompleted) held.complete(_png(0x41));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('inactive GIF has no image until it becomes eligible',
      (tester) async {
    try {
      await tester.pumpWidget(_viewer(
          identity: 'gif',
          preview: _gif(),
          active: false,
          load: () async => _gif()));
      await tester.pump();
      expect(find.byType(Image, skipOffstage: false), findsNothing);

      await tester.pumpWidget(
          _viewer(identity: 'gif', preview: _gif(), load: () async => _gif()));
      await tester.pump();
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('editing never opens with a cancelled or replaced original',
      (tester) async {
    final held = Completer<Uint8List>();
    try {
      await tester.pumpWidget(_viewer(
          identity: 'source-a', preview: _png(0x41), load: () => held.future));
      await tester.tap(find.byKey(const Key('viewer-edit')));
      await tester.pump();
      await tester.pumpWidget(_viewer(
          identity: 'source-b',
          preview: _png(0x42),
          load: () async => _png(0x42)));
      held.complete(_png(0x41));
      await tester.pump();
      await tester.pump();
      expect(find.byType(WeChatImageEditorPage), findsNothing);
    } finally {
      if (!held.isCompleted) held.complete(_png(0x41));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'background cancellation releases edit before its old loader finishes',
      (tester) async {
    final held = Completer<Uint8List>();
    try {
      await tester.pumpWidget(_viewer(
          identity: 'source', preview: _png(0x41), load: () => held.future));
      await tester.tap(find.byKey(const Key('viewer-edit')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
          tester
              .widget<ViewerRoundAction>(find.byKey(const Key('viewer-edit')))
              .onPressed,
          isNotNull);
      expect(find.byType(WeChatImageEditorPage), findsNothing);
      await tester.runAsync(() async {
        held.complete(_png(0x41));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(find.byType(WeChatImageEditorPage), findsNothing);
    } finally {
      if (!held.isCompleted) held.complete(_png(0x41));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('zoomed same-key source replacement resets without build errors',
      (tester) async {
    final zooms = <bool>[];
    Object identity = 'source';
    StateSetter? update;
    try {
      await tester.pumpWidget(StatefulBuilder(builder: (context, setState) {
        update = setState;
        return _viewer(
            identity: identity,
            preview: identity == 'source' ? _png(0x41) : _png(0x42),
            load: () async => _png(0x41),
            onZoomChanged: (value) => setState(() => zooms.add(value)));
      }));
      await tester.pump();
      await _doubleTapImage(tester);
      expect(zooms, [true]);
      expect(
          tester
              .widget<InteractiveViewer>(find.byType(InteractiveViewer))
              .transformationController!
              .value
              .getMaxScaleOnAxis(),
          3);
      await _doubleTapImage(tester);
      expect(zooms, [true, false]);
      await _doubleTapImage(tester);
      update!(() => identity = 'replacement');
      await tester.pump();
      final viewer =
          tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('save keeps a captured source through permission while inactive',
      (tester) async {
    final permission = Completer<int>();
    final saved = <Uint8List>[];
    MediaConsumerScope? saveScope;
    var wasActiveDuringLoad = false;
    final sourceBytes = _png(0x41);
    _setSaveChannels(permission, saved.add);
    try {
      await tester.pumpWidget(_viewer(
          identity: 'source-a',
          preview: sourceBytes,
          load: () {
            saveScope = MediaConsumerScope.current;
            wasActiveDuringLoad = saveScope?.isActive ?? false;
            return Future.value(sourceBytes);
          }));
      await tester.tap(find.byKey(const Key('viewer-download')));
      await tester.pump();
      await tester.pumpWidget(_viewer(
          identity: 'source-a',
          preview: sourceBytes,
          load: () {
            saveScope = MediaConsumerScope.current;
            wasActiveDuringLoad = saveScope?.isActive ?? false;
            return Future.value(sourceBytes);
          },
          active: false));
      permission.complete(33);
      await tester.pump();
      await tester.pump();
      expect(saveScope, isNotNull);
      expect(wasActiveDuringLoad, isTrue);
      expect(saveScope!.isActive, isFalse);
      expect(saved, [sourceBytes]);
      expect(find.text('已保存到相册'), findsOneWidget);
    } finally {
      if (!permission.isCompleted) permission.complete(33);
      _clearSaveChannels();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets(
      'source replacement during save permission never saves stale bytes',
      (tester) async {
    final permission = Completer<int>();
    final saved = <Uint8List>[];
    var oldLoads = 0;
    _setSaveChannels(permission, saved.add);
    try {
      await tester.pumpWidget(_viewer(
          identity: 'source-a',
          preview: _png(0x41),
          load: () async {
            oldLoads++;
            return _png(0x41);
          }));
      await tester.tap(find.byKey(const Key('viewer-download')));
      await tester.pump();
      await tester.pumpWidget(_viewer(
          identity: 'source-b',
          preview: _png(0x42),
          load: () async => _png(0x42)));
      permission.complete(33);
      await tester.pump();
      await tester.pump();
      expect(oldLoads, 0);
      expect(saved, isEmpty);
    } finally {
      if (!permission.isCompleted) permission.complete(33);
      _clearSaveChannels();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('held save loader is cancelled by source replacement',
      (tester) async {
    final permission = Completer<int>()..complete(33);
    final held = Completer<Uint8List>();
    final saved = <Uint8List>[];
    MediaConsumerScope? scope;
    _setSaveChannels(permission, saved.add);
    try {
      await tester.pumpWidget(_viewer(
          identity: 'a',
          preview: _png(0x41),
          load: () {
            scope = MediaConsumerScope.current;
            return held.future;
          }));
      await tester.tap(find.byKey(const Key('viewer-download')));
      await tester.pump();
      expect(scope, isNotNull);
      await tester.pumpWidget(_viewer(
          identity: 'b', preview: _png(0x42), load: () async => _png(0x42)));
      expect(scope!.isActive, isFalse);
      held.complete(_png(0x41));
      await tester.pump();
      expect(saved, isEmpty);
    } finally {
      if (!held.isCompleted) held.complete(_png(0x41));
      _clearSaveChannels();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}

Widget _viewer({
  required Object identity,
  required Uint8List preview,
  required Future<Uint8List> Function() load,
  bool active = true,
  ValueChanged<bool>? onZoomChanged,
}) =>
    CupertinoApp(
        home: ImageViewerPage(
            key: const ValueKey('viewer'),
            sourceIdentity: identity,
            active: active,
            onZoomChanged: onZoomChanged,
            previewBytes: preview,
            loadOriginal: load));

Uint8List _displayedBytes(WidgetTester tester) {
  final image = tester.widget<Image>(find.byType(Image));
  final resize = image.image as ResizeImage;
  return (resize.imageProvider as MemoryImage).bytes;
}

Future<void> _doubleTapImage(WidgetTester tester) async {
  await tester.tap(find.byType(InteractiveViewer));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.byType(InteractiveViewer));
  await tester.pump(const Duration(milliseconds: 400));
}

void _setSaveChannels(
    Completer<int> permission, void Function(Uint8List bytes) saved) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('chatflow/gallery'),
          (call) {
    if (call.method == 'androidSdk') return permission.future;
    return null;
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.fluttercandies/photo_manager'),
          (call) async {
    if (call.method == 'saveImage') {
      saved(Uint8List.fromList((call.arguments as Map)['image'] as Uint8List));
      return <String, dynamic>{
        'id': 'saved',
        'type': 1,
        'width': 1,
        'height': 1,
      };
    }
    return null;
  });
}

void _clearSaveChannels() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('chatflow/gallery'), null);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.fluttercandies/photo_manager'), null);
}

Uint8List _png(int tag) => Uint8List.fromList([..._pngBase, tag]);

const _pngBase = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x44,
  0x41,
  0x54,
  0x08,
  0xd7,
  0x63,
  0xf8,
  0xcf,
  0xc0,
  0xf0,
  0x1f,
  0x00,
  0x05,
  0x00,
  0x01,
  0xff,
  0x89,
  0x99,
  0x3d,
  0x1d,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];

Uint8List _gif() => Uint8List.fromList(const [
      71,
      73,
      70,
      56,
      57,
      97,
      1,
      0,
      1,
      0,
      128,
      0,
      0,
      0,
      0,
      0,
      255,
      255,
      255,
      33,
      249,
      4,
      1,
      0,
      0,
      0,
      0,
      44,
      0,
      0,
      0,
      0,
      1,
      0,
      1,
      0,
      0,
      2,
      2,
      68,
      1,
      0,
      59,
    ]);
