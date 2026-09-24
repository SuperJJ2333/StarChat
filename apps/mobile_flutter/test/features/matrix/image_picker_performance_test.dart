import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';
import 'package:photo_manager/photo_manager.dart';

import 'image_picker_page_test.dart' show tinyPng;

final class _GatedPager extends DeviceGalleryPager {
  _GatedPager(this.page);

  final Future<List<GalleryPhoto>> page;

  @override
  bool get hasMore => false;

  @override
  Future<List<GalleryPhoto>> loadNextPage({int pageSize = 20}) => page;
}

final class _DeniedPager extends DeviceGalleryPager {
  @override
  Future<List<GalleryPhoto>> loadNextPage({int pageSize = 20}) async =>
      throw GalleryPermissionDenied();
}

GalleryPhoto _photo() => GalleryPhoto(
      id: 'PRIVATE_ASSET_ID',
      thumbnail: tinyPng,
      compressedBytes: () async => tinyPng,
      originalBytes: () async => tinyPng,
    );

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
        return PermissionState.authorized.index;
      }
      if (call.method == 'notify') return true;
      throw MissingPluginException();
    });
  });

  testWidgets('first frame precedes delayed gallery content', (tester) async {
    var nowUs = 0;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      onRecord: records.add,
    );
    final trace = recorder.start(PerformanceOperationType.recentPicturesLoad);
    final page = Completer<List<GalleryPhoto>>();
    nowUs = 20000;
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(
        performanceTrace: trace,
        albumsLoader: () async => [],
        pagerBuilder: () => _GatedPager(page.future),
      ),
    ));
    expect(records, isEmpty);
    expect(find.byType(CupertinoActivityIndicator), findsWidgets);

    nowUs = 250000;
    page.complete([_photo()]);
    await tester.pumpAndSettle();
    expect(records, hasLength(1));
    final record = records.single;
    expect(record.operation, PerformanceOperationType.recentPicturesLoad);
    expect(record.result, PerformanceResult.success);
    expect(record.stagesUs.keys, [
      PerformanceStage.routeEnter,
      PerformanceStage.firstFrameRendered,
      PerformanceStage.contentReady,
    ]);
    expect(
        record.betweenMs(
            PerformanceStage.firstFrameRendered, PerformanceStage.contentReady),
        230);
    expect(record.toJson().toString(), isNot(contains('PRIVATE_ASSET_ID')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cached preview is content-ready on the first frame',
      (tester) async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    GalleryAccessCache.shared.preview = [_photo()];
    final page = Completer<List<GalleryPhoto>>();
    final trace = recorder.start(PerformanceOperationType.recentPicturesLoad);
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(
        performanceTrace: trace,
        albumsLoader: () async => [],
        pagerBuilder: () => _GatedPager(page.future),
      ),
    ));
    expect(find.byKey(const Key('image-picker-item-PRIVATE_ASSET_ID')),
        findsOneWidget);
    expect(records, hasLength(1));
    expect(records.single.stagesUs.keys, [
      PerformanceStage.routeEnter,
      PerformanceStage.firstFrameRendered,
      PerformanceStage.contentReady,
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    page.complete(const []);
  });

  testWidgets('permission denial closes trace without content-ready',
      (tester) async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(
        performanceTrace:
            recorder.start(PerformanceOperationType.recentPicturesLoad),
        albumsLoader: () async => [],
        pagerBuilder: _DeniedPager.new,
      ),
    ));
    await tester.pumpAndSettle();
    expect(records, hasLength(1));
    expect(records.single.result, PerformanceResult.rejected);
    expect(records.single.stagesUs.keys,
        contains(PerformanceStage.firstFrameRendered));
    expect(records.single.stagesUs.keys,
        isNot(contains(PerformanceStage.contentReady)));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disposing before metadata arrives releases the trace',
      (tester) async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final page = Completer<List<GalleryPhoto>>();
    await tester.pumpWidget(CupertinoApp(
      home: ImagePickerPage(
        performanceTrace:
            recorder.start(PerformanceOperationType.recentPicturesLoad),
        albumsLoader: () async => [],
        pagerBuilder: () => _GatedPager(page.future),
      ),
    ));
    expect(recorder.activeCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(recorder.activeCount, 0);
    expect(records, isEmpty);
    page.complete(const []);
  });
}
