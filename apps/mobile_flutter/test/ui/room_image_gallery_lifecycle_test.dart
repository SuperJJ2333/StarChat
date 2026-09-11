import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:liuhetong_mobile/ui/chat/room_image_gallery.dart';

void main() {
  testWidgets('initial gallery loads only the current image and two neighbors',
      (tester) async {
    const initialIndex = 25000;
    final heldPreview = Completer<Uint8List>();
    final loads = <String, _LoadObservation>{};
    var loadEarlierCalls = 0;
    Future<Uint8List> preview(String id) {
      loads[id] = _LoadObservation(
          MediaConsumerScope.current, currentMediaLoadPriority);
      return heldPreview.future;
    }

    final images = List<RoomGalleryImage>.generate(
        50000,
        (index) => RoomGalleryImage(
            id: 'image-$index',
            loadPreview: () => preview('image-$index'),
            loadOriginal: () async => _png(),
            onForward: () async {}),
        growable: false);
    try {
      await tester.pumpWidget(CupertinoApp(
          home: RoomImageGalleryPage(
              images: images,
              initialId: 'image-$initialIndex',
              loadEarlier: () async {
                loadEarlierCalls++;
                return const <RoomGalleryImage>[];
              },
              onForwardEdited: (_) async => false,
              onFavorite: (_) async {})));
      await tester.pump();

      expect(loads.keys,
          unorderedEquals(['image-24999', 'image-25000', 'image-25001']));
      expect(loads['image-25000']!.scope, isNotNull);
      expect(loads['image-25000']!.priority, MediaLoadPriority.interactive);
      expect(loads['image-24999']!.scope, isNotNull);
      expect(loads['image-24999']!.priority, MediaLoadPriority.prefetch);
      expect(loads['image-25001']!.scope, isNotNull);
      expect(loads['image-25001']!.priority, MediaLoadPriority.prefetch);
      expect(loads.values.where((load) => load.scope!.isActive), hasLength(3));
      expect(loadEarlierCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!heldPreview.isCompleted) heldPreview.complete(Uint8List(1));
      await tester.pump();
    }
  });

  testWidgets('page change promotes its neighbor and cancels an outgoing load',
      (tester) async {
    final held = <String, Completer<Uint8List>>{
      for (var index = 0; index < 5; index++)
        'image-$index': Completer<Uint8List>(),
    };
    final loads = <String, _LoadObservation>{};
    Future<Uint8List> preview(String id) {
      loads[id] = _LoadObservation(
          MediaConsumerScope.current, currentMediaLoadPriority);
      return held[id]!.future;
    }

    try {
      await tester.pumpWidget(CupertinoApp(
          home: RoomImageGalleryPage(
              images: _images(5, preview),
              initialId: 'image-2',
              loadEarlier: () async => const <RoomGalleryImage>[],
              onForwardEdited: (_) async => false,
              onFavorite: (_) async {})));
      await tester.pump();
      final incoming = loads['image-3']!.scope!;
      final outgoing = loads['image-1']!.scope!;

      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await tester.pump(const Duration(milliseconds: 500));

      expect(identical(loads['image-3']!.scope, incoming), isTrue);
      expect(incoming.priority, MediaLoadPriority.interactive);
      expect(outgoing.isActive, isFalse);
      expect(loads['image-4']!.priority, MediaLoadPriority.prefetch);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final completer in held.values) {
        if (!completer.isCompleted) completer.complete(Uint8List(1));
      }
      await tester.pump();
    }
  });

  testWidgets(
      'dispose cancels every gallery scope and consumes immediate errors',
      (tester) async {
    final held = Completer<Uint8List>();
    final loads = <String, _LoadObservation>{};
    var currentAttempts = 0;
    Future<Uint8List> preview(String id) {
      loads[id] = _LoadObservation(
          MediaConsumerScope.current, currentMediaLoadPriority);
      if (id == 'image-1') return Future<Uint8List>.error(StateError('gone'));
      if (id == 'image-2' && currentAttempts++ == 0) {
        return Future<Uint8List>.error(StateError('gone'));
      }
      return held.future;
    }

    try {
      await tester.pumpWidget(CupertinoApp(
          home: RoomImageGalleryPage(
              images: _images(5, preview),
              initialId: 'image-2',
              loadEarlier: () async => const <RoomGalleryImage>[],
              onForwardEdited: (_) async => false,
              onFavorite: (_) async {})));
      await tester.pump();
      await tester.pump();
      expect(loads.keys, unorderedEquals(['image-1', 'image-2', 'image-3']));
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('图片加载失败，点击重试'));
      await tester.pump();
      expect(currentAttempts, 2);
      expect(loads['image-2']!.scope!.isActive, isTrue);
      held.complete(_png());
      await tester.pump();
      expect(find.byKey(const ValueKey('viewer-image-2')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(loads.values.every((load) => !load.scope!.isActive), isTrue);
    } finally {
      if (!held.isCompleted) held.complete(Uint8List(1));
      await tester.pump();
    }
  });

  testWidgets('didUpdate replaces a same-id preview when its source changes',
      (tester) async {
    final oldPreview = Completer<Uint8List>();
    final newPreview = Completer<Uint8List>();
    MediaConsumerScope? oldScope;
    MediaConsumerScope? newScope;
    var newCalls = 0;
    List<RoomGalleryImage> images(
            Object sourceIdentity, Future<Uint8List> Function() load) =>
        [
          RoomGalleryImage(
              id: 'before',
              loadPreview: () async => _png(),
              loadOriginal: () async => _png(),
              onForward: () async {}),
          RoomGalleryImage(
              id: 'same-event',
              sourceIdentity: sourceIdentity,
              loadPreview: load,
              loadOriginal: () async => _png(),
              onForward: () async {}),
          RoomGalleryImage(
              id: 'after',
              loadPreview: () async => _png(),
              loadOriginal: () async => _png(),
              onForward: () async {}),
        ];
    Future<Uint8List> oldLoad() {
      oldScope = MediaConsumerScope.current;
      return oldPreview.future;
    }

    Future<Uint8List> newLoad() {
      newCalls++;
      newScope = MediaConsumerScope.current;
      return newPreview.future;
    }

    try {
      await tester.pumpWidget(_gallery(
          images: images('preview-v1', oldLoad), initialId: 'same-event'));
      await tester.pump();
      expect(oldScope, isNotNull);

      await tester.pumpWidget(_gallery(
          images: images('preview-v2', newLoad), initialId: 'same-event'));
      await tester.pump();

      expect(oldScope!.isActive, isFalse);
      expect(newCalls, 1);
      expect(newScope, isNotNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!oldPreview.isCompleted) oldPreview.complete(Uint8List(1));
      if (!newPreview.isCompleted) newPreview.complete(Uint8List(2));
      await tester.pump();
    }
  });

  testWidgets('didUpdate retains a stable identity despite a new closure',
      (tester) async {
    final held = Completer<Uint8List>();
    MediaConsumerScope? firstScope;
    var replacementCalls = 0;
    List<RoomGalleryImage> images(Future<Uint8List> Function() load) => [
          RoomGalleryImage(
              id: 'before',
              loadPreview: () async => _png(),
              loadOriginal: () async => _png(),
              onForward: () async {}),
          RoomGalleryImage(
              id: 'same-event',
              sourceIdentity: 'stable-preview',
              loadPreview: load,
              loadOriginal: () async => _png(),
              onForward: () async {}),
          RoomGalleryImage(
              id: 'after',
              loadPreview: () async => _png(),
              loadOriginal: () async => _png(),
              onForward: () async {}),
        ];
    Future<Uint8List> firstLoad() {
      firstScope = MediaConsumerScope.current;
      return held.future;
    }

    try {
      await tester.pumpWidget(
          _gallery(images: images(firstLoad), initialId: 'same-event'));
      await tester.pump();
      await tester.pumpWidget(_gallery(
          images: images(() async {
            replacementCalls++;
            return _png();
          }),
          initialId: 'same-event'));
      await tester.pump();

      expect(firstScope, isNotNull);
      expect(firstScope!.isActive, isTrue);
      expect(replacementCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!held.isCompleted) held.complete(_png());
      await tester.pump();
    }
  });

  testWidgets('a current source replacement clears the gallery zoom lock',
      (tester) async {
    List<RoomGalleryImage> images(String sourceIdentity) => [
          RoomGalleryImage(
              id: 'before',
              loadPreview: () async => _png(),
              loadOriginal: () async => _png(),
              onForward: () async {}),
          RoomGalleryImage(
              id: 'current',
              sourceIdentity: sourceIdentity,
              loadPreview: () async => _png(),
              loadOriginal: () async => _png(),
              onForward: () async {}),
          RoomGalleryImage(
              id: 'after',
              loadPreview: () async => _png(),
              loadOriginal: () async => _png(),
              onForward: () async {}),
        ];
    try {
      await tester.pumpWidget(
          _gallery(images: images('preview-a'), initialId: 'current'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(InteractiveViewer));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(InteractiveViewer));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<PageView>(find.byType(PageView)).physics,
          isA<NeverScrollableScrollPhysics>());

      await tester.pumpWidget(
          _gallery(images: images('preview-b'), initialId: 'current'));
      await tester.pump();
      expect(tester.widget<PageView>(find.byType(PageView)).physics,
          isA<BouncingScrollPhysics>());
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('source scope replacement ignores an older held history result',
      (tester) async {
    final oldEarlier = Completer<List<RoomGalleryImage>>();
    var stalePreviewCalls = 0;
    final stale = RoomGalleryImage(
        id: 'stale',
        loadPreview: () async {
          stalePreviewCalls++;
          return _png();
        },
        loadOriginal: () async => _png(),
        onForward: () async {});
    List<RoomGalleryImage> images() => [
          RoomGalleryImage(
              id: 'current',
              loadPreview: () async => _png(),
              loadOriginal: () async => _png(),
              onForward: () async {}),
        ];
    try {
      await tester.pumpWidget(_gallery(
          images: images(),
          initialId: 'current',
          sourceScope: ('homeserver-a', 'user-a', 'room-a'),
          loadEarlier: () => oldEarlier.future));
      await tester.pump();

      await tester.pumpWidget(_gallery(
          images: images(),
          initialId: 'current',
          sourceScope: ('homeserver-b', 'user-b', 'room-b')));
      oldEarlier.complete([stale]);
      await tester.pump();
      await tester.pump();

      expect(stalePreviewCalls, 0);
      expect(find.byKey(const ValueKey('viewer-stale')), findsNothing);
      expect(find.text('1 / 1'), findsOneWidget);
    } finally {
      if (!oldEarlier.isCompleted) oldEarlier.complete(const []);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets(
      'prepending history retains the current id and a three-image window',
      (tester) async {
    final earlier = Completer<List<RoomGalleryImage>>();
    final held = Completer<Uint8List>();
    final loads = <String, _LoadObservation>{};
    Future<Uint8List> preview(String id) {
      loads[id] = _LoadObservation(
          MediaConsumerScope.current, currentMediaLoadPriority);
      return held.future;
    }

    try {
      await tester.pumpWidget(_gallery(
          images: _images(2, preview),
          initialId: 'image-0',
          loadEarlier: () => earlier.future));
      await tester.pump();
      earlier.complete([
        RoomGalleryImage(
            id: 'older-0',
            loadPreview: () => preview('older-0'),
            loadOriginal: () async => _png(),
            onForward: () async {}),
        RoomGalleryImage(
            id: 'older-1',
            loadPreview: () => preview('older-1'),
            loadOriginal: () async => _png(),
            onForward: () async {}),
      ]);
      await tester.pump();
      await tester.pump();

      expect(find.text('3 / 4'), findsOneWidget);
      expect(loads.values.where((load) => load.scope!.isActive), hasLength(3));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!held.isCompleted) held.complete(Uint8List(1));
      if (!earlier.isCompleted) earlier.complete(const []);
      await tester.pump();
    }
  });

  testWidgets('a same-scope parent rebuild retains gallery-loaded history',
      (tester) async {
    final earlier = Completer<List<RoomGalleryImage>>();
    final current = RoomGalleryImage(
        id: 'current',
        loadPreview: () async => _png(),
        loadOriginal: () async => _png(),
        onForward: () async {});
    final older = RoomGalleryImage(
        id: 'older',
        loadPreview: () async => _png(),
        loadOriginal: () async => _png(),
        onForward: () async {});
    try {
      await tester.pumpWidget(_gallery(
          images: [current],
          initialId: 'current',
          loadEarlier: () => earlier.future));
      await tester.pump();
      earlier.complete([older]);
      await tester.pump();
      await tester.pump();
      expect(find.text('2 / 2'), findsOneWidget);

      await tester.pumpWidget(_gallery(
          images: [current],
          initialId: 'current',
          loadEarlier: () async => []));
      await tester.pump();
      expect(find.text('2 / 2'), findsOneWidget);
    } finally {
      if (!earlier.isCompleted) earlier.complete(const []);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('didUpdate accepts an empty image list without stale loads',
      (tester) async {
    final held = Completer<Uint8List>();
    final loads = <String, _LoadObservation>{};
    Future<Uint8List> preview(String id) {
      loads[id] = _LoadObservation(
          MediaConsumerScope.current, currentMediaLoadPriority);
      return held.future;
    }

    try {
      await tester.pumpWidget(
          _gallery(images: _images(3, preview), initialId: 'image-1'));
      await tester.pump();
      await tester.pumpWidget(_gallery(images: const [], initialId: 'missing'));
      await tester.pump();
      expect(find.text('暂无可查看的图片'), findsOneWidget);
      expect(loads.values.every((load) => !load.scope!.isActive), isTrue);
      expect(tester.takeException(), isNull);
    } finally {
      if (!held.isCompleted) held.complete(_png());
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('a changed initial id reanchors the current page',
      (tester) async {
    final held = <String, Completer<Uint8List>>{
      for (var index = 0; index < 3; index++)
        'image-$index': Completer<Uint8List>(),
    };
    final loads = <String, _LoadObservation>{};
    Future<Uint8List> preview(String id) {
      loads[id] = _LoadObservation(
          MediaConsumerScope.current, currentMediaLoadPriority);
      return held[id]!.future;
    }

    try {
      await tester.pumpWidget(
          _gallery(images: _images(3, preview), initialId: 'image-0'));
      await tester.pump();
      await tester.pumpWidget(
          _gallery(images: _images(3, preview), initialId: 'image-2'));
      await tester.pump();
      await tester.pump();
      expect(find.text('3 / 3'), findsOneWidget);
      expect(loads['image-2']!.priority, MediaLoadPriority.interactive);
      expect(loads['image-0']!.scope!.isActive, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final completer in held.values) {
        if (!completer.isCompleted) completer.complete(_png());
      }
      await tester.pump();
    }
  });

  testWidgets(
      'parent deletion of the current id falls back to the new first page',
      (tester) async {
    final held = <String, Completer<Uint8List>>{
      for (var index = 0; index < 3; index++)
        'image-$index': Completer<Uint8List>(),
    };
    final loads = <String, _LoadObservation>{};
    Future<Uint8List> preview(String id) {
      loads[id] = _LoadObservation(
          MediaConsumerScope.current, currentMediaLoadPriority);
      return held[id]!.future;
    }

    try {
      await tester.pumpWidget(
          _gallery(images: _images(3, preview), initialId: 'image-2'));
      await tester.pump();
      await tester.pumpWidget(
          _gallery(images: _images(2, preview), initialId: 'image-2'));
      await tester.pump();
      await tester.pump();
      expect(find.text('1 / 2'), findsOneWidget);
      expect(loads['image-2']!.scope!.isActive, isFalse);
      expect(loads['image-0']!.scope!.isActive, isTrue);
      expect(loads['image-1']!.scope!.isActive, isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final completer in held.values) {
        if (!completer.isCompleted) completer.complete(_png());
      }
      await tester.pump();
    }
  });

  testWidgets('held history survives an initial-id reanchor and clears loading',
      (tester) async {
    final earlier = Completer<List<RoomGalleryImage>>();
    final images = [
      RoomGalleryImage(
          id: 'image-0',
          loadPreview: () async => _png(),
          loadOriginal: () async => _png(),
          onForward: () async {}),
      RoomGalleryImage(
          id: 'image-1',
          loadPreview: () async => _png(),
          loadOriginal: () async => _png(),
          onForward: () async {}),
    ];
    final older = RoomGalleryImage(
        id: 'older',
        loadPreview: () async => _png(),
        loadOriginal: () async => _png(),
        onForward: () async {});
    try {
      await tester.pumpWidget(_gallery(
          images: images,
          initialId: 'image-0',
          loadEarlier: () => earlier.future));
      await tester.pump();
      await tester.pumpWidget(_gallery(
          images: images,
          initialId: 'image-1',
          loadEarlier: () => earlier.future));
      earlier.complete([older]);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle(const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));

      expect(find.text('3 / 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-image-1')), findsOneWidget);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
    } finally {
      if (!earlier.isCompleted) earlier.complete(const []);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('edge selections never create an out-of-range neighbor',
      (tester) async {
    final firstLoads = <String, _LoadObservation>{};
    final lastLoads = <String, _LoadObservation>{};
    Future<Uint8List> firstPreview(String id) async {
      firstLoads[id] = _LoadObservation(
          MediaConsumerScope.current, currentMediaLoadPriority);
      return _png();
    }

    Future<Uint8List> lastPreview(String id) async {
      lastLoads[id] = _LoadObservation(
          MediaConsumerScope.current, currentMediaLoadPriority);
      return _png();
    }

    await tester.pumpWidget(
        _gallery(images: _images(3, firstPreview), initialId: 'image-0'));
    await tester.pump();
    expect(firstLoads.keys, unorderedEquals(['image-0', 'image-1']));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
        _gallery(images: _images(3, lastPreview), initialId: 'image-2'));
    await tester.pump();
    expect(lastLoads.keys, unorderedEquals(['image-1', 'image-2']));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

List<RoomGalleryImage> _images(
        int count, Future<Uint8List> Function(String) preview) =>
    List<RoomGalleryImage>.generate(
        count,
        (index) => RoomGalleryImage(
            id: 'image-$index',
            loadPreview: () => preview('image-$index'),
            loadOriginal: () async => _png(),
            onForward: () async {}),
        growable: false);

Widget _gallery({
  required List<RoomGalleryImage> images,
  required String initialId,
  (String, String, String)? sourceScope,
  Future<List<RoomGalleryImage>> Function()? loadEarlier,
}) =>
    CupertinoApp(
        home: RoomImageGalleryPage(
            images: images,
            initialId: initialId,
            sourceScope: sourceScope,
            loadEarlier: loadEarlier ?? () async => const <RoomGalleryImage>[],
            onForwardEdited: (_) async => false,
            onFavorite: (_) async {}));

final class _LoadObservation {
  const _LoadObservation(this.scope, this.priority);
  final MediaConsumerScope? scope;
  final MediaLoadPriority priority;
}

Uint8List _png() => Uint8List.fromList(const [
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
    ]);
