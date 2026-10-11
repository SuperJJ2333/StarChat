import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache_storage_policy.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chatflow/media_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
      'iOS policy is attempted once and retries only at foreground after failure',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final policy = MediaCacheStoragePolicy();
    addTearDown(policy.dispose);
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'documentsChatMediaPolicy');
      expect(call.arguments, isNull);
      if (++calls == 1) {
        throw PlatformException(code: 'MEDIA_STORAGE_UNAVAILABLE');
      }
      return {'protected': true, 'backupExcluded': true};
    });
    for (var i = 0; i < 10; i++) {
      policy.ensureScheduled();
    }
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    for (var i = 0; i < 10; i++) {
      policy.ensureScheduled();
    }
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    policy.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    policy.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
  });

  test('missing native readback remains retryable and in-flight calls coalesce',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final policy = MediaCacheStoragePolicy();
    addTearDown(policy.dispose);
    var calls = 0;
    final response = Completer<Map<String, bool>>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return response.future;
    });
    policy.ensureScheduled();
    policy.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    response.complete({'protected': true, 'backupExcluded': false});
    await Future<void>.delayed(Duration.zero);
    policy.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
  });

  test('Android does not call the iOS-only cache policy', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final policy = MediaCacheStoragePolicy();
    addTearDown(policy.dispose);
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      return null;
    });
    policy.ensureScheduled();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
  });

  test(
      'real cache store invokes fixed policy once and preserves files on native failure',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final parent = await Directory(
            '../../docs/verification/artifacts/2026-10-11/im-media-cache-index')
        .absolute
        .create(recursive: true);
    final root = await parent.createTemp('policy-');
    final oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) async {
      calls++;
      throw PlatformException(code: 'MEDIA_STORAGE_UNAVAILABLE');
    });
    try {
      final file = await MediaCache.store('r', 'e', Uint8List.fromList([1, 2]),
          accountId: 'a');
      await MediaCache.store('r', 'e2', Uint8List.fromList([3, 4]),
          accountId: 'a');
      expect(calls, 1);
      expect(await file.readAsBytes(), [1, 2]);
    } finally {
      await MediaCache.closeQuotaIndexes();
      MediaCacheStoragePolicy.shared.dispose();
      PathProviderPlatform.instance = oldPaths;
      await root.delete(recursive: true);
    }
  });
}
