import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';
import 'package:liuhetong_mobile/features/moments/moment_comment_composer.dart';
import 'package:liuhetong_mobile/features/moments/moment_composer_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:photo_manager/photo_manager.dart';

class _Store implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _PickerObserver extends NavigatorObserver {
  final results = <Object?>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    route.popped.then(results.add);
    super.didPop(route, previousRoute);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PathProviderPlatform originalPaths;
  late Directory scratch;
  final bytes =
      base64Decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
  const channel = MethodChannel('com.fluttercandies/photo_manager');
  setUp(() async {
    GalleryAccessCache.invalidateAll();
    originalPaths = PathProviderPlatform.instance;
    scratch = await Directory(
            '../../docs/verification/artifacts/2026-10-09/android2209-moments-candidate/moments/widget-scratch')
        .absolute
        .create(recursive: true);
    scratch = await scratch.createTemp('case-');
    PathProviderPlatform.instance = _Paths(scratch.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getPermissionState':
        case 'requestPermissionExtend':
          return PermissionState.authorized.index;
        case 'notify':
          return true;
        case 'getAssetCountFromPath':
          return 1;
        case 'getAssetPathList':
          return {
            'data': [
              {'id': 'recent', 'name': 'Recent', 'isAll': true, 'assetCount': 1}
            ]
          };
        case 'getAssetListRange':
          return {
            'data': [
              {
                'id': 'photo',
                'type': 1,
                'width': 1,
                'height': 1,
                'mimeType': 'image/gif'
              }
            ]
          };
        case 'getThumb':
        case 'getOriginBytes':
          return bytes;
        case 'getFullFile':
          return null;
        default:
          throw MissingPluginException(call.method);
      }
    });
  });
  tearDown(() async {
    PathProviderPlatform.instance = originalPaths;
    GalleryAccessCache.invalidateAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await scratch.delete(recursive: true);
  });

  for (final entry in ['post', 'comment', 'chat']) {
    testWidgets('$entry gallery preview exposes only its supported send modes',
        (tester) async {
      final observer = _PickerObserver();
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://business.example'),
          sessionStore: SecureSessionStore(_Store()),
          client: MockClient((_) async => http.Response('{}', 200)));
      await tester.pumpWidget(CupertinoApp(
        navigatorObservers: [observer],
        home: entry == 'post'
            ? MomentComposerPage(api: api)
            : Builder(
                builder: (context) => CupertinoButton(
                    child: const Text('open'),
                    onPressed: () {
                      if (entry == 'comment') {
                        showMomentCommentComposer(context,
                            api: api, momentId: 'm1');
                      } else {
                        Navigator.of(context).push<MomentGallerySelection>(
                            CupertinoPageRoute(
                                builder: (_) => const ImagePickerPage()));
                      }
                    })),
      ));
      await tester.pumpAndSettle();
      if (entry != 'post') {
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }
      if (entry != 'chat') {
        await tester.tap(find.byKey(Key(entry == 'post'
            ? 'moment-pick-images'
            : 'moment-comment-gallery')));
        await tester.pumpAndSettle();
      }
      final photo = find.byKey(const Key('image-picker-item-photo'));
      expect(photo, findsOneWidget);
      await tester.tapAt(tester.getBottomRight(photo) - const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('gallery-preview-edit')), findsOneWidget);
      expect(find.byKey(const Key('gallery-preview-select')), findsOneWidget);
      expect(find.byKey(const Key('gallery-preview-flash')),
          entry == 'chat' ? findsOneWidget : findsNothing);
      if (entry == 'chat') {
        await tester.tap(find.byKey(const Key('gallery-preview-flash')));
      } else {
        await tester.tap(find.byKey(const Key('gallery-preview-select')));
        await tester.pump();
        expect(find.text('已选择'), findsOneWidget);
        await tester.tap(find.byKey(const Key('gallery-preview-back')));
        await tester.pumpAndSettle();
        if (entry == 'comment') {
          expect(find.byKey(const Key('image-picker-original-switch')),
              findsOneWidget);
          await tester
              .tap(find.byKey(const Key('image-picker-original-switch')));
        }
        await tester.tap(find.byKey(const Key('image-picker-send')));
      }
      await tester.pump();
      final result =
          observer.results.whereType<MomentGallerySelection>().single;
      expect(result.flash, entry == 'chat');
      expect(result.photos.single.id, 'photo');
      expect(result.original, entry != 'post');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
