import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/gallery_media_export.dart';
import 'package:liuhetong_mobile/core/gallery_save_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const gallery = MethodChannel('chatflow/gallery');
  const photos = MethodChannel('com.fluttercandies/photo_manager');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  final gif =
      base64Decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    for (final channel in [gallery, photos, permissions]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  test('denied gallery permission never loads decrypted original', () async {
    messenger.setMockMethodCallHandler(gallery, (_) async => 28);
    messenger.setMockMethodCallHandler(permissions,
        (call) async => {for (final id in call.arguments as List) id: 0});
    var loads = 0;
    await expectLater(
        GalleryMediaExport.saveImage(
          filename: 'photo.jpg',
          loadOriginal: () async {
            loads++;
            return gif;
          },
        ),
        throwsA(isA<GallerySavePermissionDenied>()));
    expect(loads, 0);
  });

  test('source revoked during original load never writes to gallery', () async {
    messenger.setMockMethodCallHandler(gallery, (_) async => 33);
    var writes = 0;
    messenger.setMockMethodCallHandler(photos, (call) async {
      if (call.method == 'saveImage') writes++;
      return null;
    });
    final started = Completer<void>();
    final release = Completer<void>();
    var current = true;
    final export = GalleryMediaExport.saveImage(
      filename: 'photo.jpg',
      ensureCurrent: () {
        if (!current) throw StateError('revoked');
      },
      loadOriginal: () async {
        started.complete();
        await release.future;
        return gif;
      },
    );
    final rejected = expectLater(export, throwsStateError);
    await started.future;
    current = false;
    release.complete();
    await rejected;
    expect(writes, 0);
  });
}
