import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mobile_scanner/src/mobile_scanner_view_attributes.dart';
import 'package:mobile_scanner/src/objects/start_options.dart';
import 'package:liuhetong_mobile/features/contacts/scan_qr_page.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/features/profile/my_qr_code_page.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/discovery/discovery_page.dart';
import 'package:liuhetong_mobile/features/matrix/image_picker_page.dart';
import 'package:liuhetong_mobile/features/contacts/request_friend_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class TestPaths extends PathProviderPlatform {
  final Directory directory = Directory(
      '${Directory.current.path}/../../docs/verification/artifacts/2026-09-05/call-echo-scan/photo-cache-test');
  @override
  Future<String?> getTemporaryPath() async {
    await directory.create(recursive: true);
    return directory.absolute.path;
  }
}

class ScannerPlatformFake extends MobileScannerPlatform {
  int starts = 0;
  int stops = 0;
  Completer<void>? startBarrier;
  Completer<void>? stopBarrier;
  BarcodeCapture? imageResult;
  Uint8List? decodedBytes;
  String? decodedPath;
  @override
  Future<BarcodeCapture?> analyzeImage(String path) async {
    decodedPath = path;
    decodedBytes = await File(path).readAsBytes();
    return imageResult;
  }

  final captures = StreamController<BarcodeCapture?>.broadcast();
  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    await startBarrier?.future;
    return const MobileScannerViewAttributes(
        currentTorchMode: TorchState.off, size: Size(640, 480));
  }

  @override
  Widget buildCameraView() => const ColoredBox(color: CupertinoColors.black);
  @override
  Future<void> stop() async {
    stops++;
    await stopBarrier?.future;
  }

  @override
  Future<void> updateScanWindow(Rect? window) async {}
  @override
  Future<void> dispose() async {}
}

class ProfileFake implements AddFriendGateway, ProfileGateway {
  bool fail = false;
  int requests = 0;
  @override
  Future<Map<String, dynamic>> searchUsers(String query) async => {
        'items': [
          {'user_id': 'bob-id', 'username': 'bob', 'nickname': '鲍勃'}
        ]
      };
  @override
  Future<Map<String, dynamic>> contactTags() async => {'items': []};
  @override
  Future<Map<String, dynamic>> requestFriend(String id,
      {String message = '',
      String? remark,
      List<String> tags = const [],
      String momentsPermission = 'DEFAULT'}) async {
    requests++;
    return {};
  }

  @override
  Future<ProfileData> loadProfile() async {
    if (fail) throw StateError('offline');
    return const ProfileData(
        username: 'alice',
        nickname: '艾丽',
        maskedEmail: '',
        fallbackSeed: 'alice');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> advance(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

Future<void> completeFileWork(
    WidgetTester tester, bool Function() completed) async {
  // File IO completes outside the widget test clock. Drain each async boundary.
  for (var i = 0; i < 100 && !completed(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late ScannerPlatformFake camera;
  late MobileScannerPlatform original;
  late PathProviderPlatform originalPaths;
  setUp(() {
    original = MobileScannerPlatform.instance;
    camera = ScannerPlatformFake();
    MobileScannerPlatform.instance = camera;
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = TestPaths();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.fluttercandies/photo_manager'),
            (call) async =>
                call.method == 'getAssetPathList' ? {'data': []} : 1);
  });
  tearDown(() async {
    await camera.captures.close();
    MobileScannerPlatform.instance = original;
    PathProviderPlatform.instance = originalPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.fluttercandies/photo_manager'), null);
  });

  testWidgets('camera that finishes initializing behind own QR is stopped',
      (tester) async {
    final startup = Completer<void>();
    camera.startBarrier = startup;
    await tester.pumpWidget(CupertinoApp(home: ScanQrPage(api: ProfileFake())));
    await tester.pump();
    await tester.tap(find.byKey(const Key('scan-my-qr')));
    await advance(tester);
    expect(find.byType(MyQrCodePage), findsOneWidget);
    startup.complete();
    await advance(tester);
    expect(camera.stops, greaterThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'closing scanner during native stop does not resolve on a disposed page',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
        CupertinoApp(navigatorKey: navigator, home: const SizedBox()));
    unawaited(navigator.currentState!.push(
        CupertinoPageRoute(builder: (_) => ScanQrPage(api: ProfileFake()))));
    await advance(tester);
    final stopping = Completer<void>();
    camera.stopBarrier = stopping;
    camera.captures.add(const BarcodeCapture(
        barcodes: [Barcode(rawValue: 'changliao://u/bob')]));
    await tester.pump();
    navigator.currentState!.pop();
    await advance(tester);
    stopping.complete();
    await advance(tester);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'gallery uses photo-only picker; original QR opens request without sending and removes temporary copy',
      (tester) async {
    final api = ProfileFake();
    camera.imageResult = const BarcodeCapture(
        barcodes: [Barcode(rawValue: 'changliao://u/bob')]);
    await tester.pumpWidget(CupertinoApp(home: ScanQrPage(api: api)));
    await advance(tester);
    await tester.tap(find.byKey(const Key('scan-gallery')));
    await advance(tester);
    final picker = tester.widget<ImagePickerPage>(find.byType(ImagePickerPage));
    expect(picker.photosOnly, isTrue);
    expect(picker.maxCount, 1);
    expect(picker.confirmLabel, '识别');
    expect(picker.showOriginalToggle, isFalse);
    final photo = GalleryPhoto(
        id: 'qr',
        thumbnail: Uint8List(0),
        compressedBytes: () async => throw StateError('Must use original'),
        originalBytes: () async => Uint8List.fromList([1, 2, 3]));
    Navigator.of(tester.element(find.byType(ImagePickerPage)))
        .pop((photos: [photo], original: false));
    await tester.pump();
    await completeFileWork(
        tester, () => find.byType(RequestFriendPage).evaluate().isNotEmpty);
    await advance(tester);
    expect(camera.decodedBytes, [1, 2, 3],
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((e) => e.data)
            .join('|'));
    expect(File(camera.decodedPath!).existsSync(), isFalse);
    expect(find.byType(RequestFriendPage), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((e) => e.data)
            .join('|'));
    expect(api.requests, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'gallery with no QR returns visible retry message and resumes camera',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(home: ScanQrPage(api: ProfileFake())));
    await advance(tester);
    await tester.tap(find.byKey(const Key('scan-gallery')));
    await advance(tester);
    final photo = GalleryPhoto(
        id: 'not-qr',
        thumbnail: Uint8List(0),
        compressedBytes: () async => Uint8List(0),
        originalBytes: () async => Uint8List.fromList([4]));
    Navigator.of(tester.element(find.byType(ImagePickerPage)))
        .pop((photos: [photo], original: false));
    await tester.pump();
    await completeFileWork(
        tester, () => find.text('未在所选照片中识别到二维码，请更换照片').evaluate().isNotEmpty);
    await advance(tester);
    expect(find.text('未在所选照片中识别到二维码，请更换照片'), findsOneWidget);
    expect(camera.starts, greaterThanOrEqualTo(2));
    expect(File(camera.decodedPath!).existsSync(), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'scanner has gallery and own QR actions; own QR pauses and resumes camera',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(home: ScanQrPage(api: ProfileFake())));
    await advance(tester);
    expect(find.byKey(const Key('scan-gallery')), findsOneWidget);
    expect(find.byKey(const Key('scan-my-qr')), findsOneWidget);
    await tester.tap(find.byKey(const Key('scan-my-qr')));
    await advance(tester);
    expect(find.byType(MyQrCodePage), findsOneWidget);
    expect(
        tester.widget<MyQrCodePage>(find.byType(MyQrCodePage)).profile.username,
        'alice');
    expect(camera.stops, greaterThanOrEqualTo(1));
    Navigator.of(tester.element(find.byType(MyQrCodePage))).pop();
    await advance(tester);
    expect(camera.starts, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('own QR profile failure is visible and scanner recovers',
      (tester) async {
    await tester.pumpWidget(
        CupertinoApp(home: ScanQrPage(api: ProfileFake()..fail = true)));
    await advance(tester);
    await tester.tap(find.byKey(const Key('scan-my-qr')));
    await advance(tester);
    expect(find.text('个人二维码加载失败，请重试'), findsOneWidget);
    expect(
        tester
            .widget<CupertinoButton>(find.byKey(const Key('scan-gallery')))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('discovery opens scanner above the entire bottom tab scaffold',
      (tester) async {
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore());
    final rootNavigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(CupertinoApp(
        navigatorKey: rootNavigator,
        home: CupertinoTabScaffold(
          tabBar: CupertinoTabBar(items: const [
            BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.chat_bubble), label: '消息'),
            BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.compass), label: '发现')
          ]),
          tabBuilder: (_, index) =>
              CupertinoTabView(builder: (_) => DiscoveryPage(api: api)),
        )));
    await tester.tap(find.byKey(const Key('discovery-scan-entry')));
    await advance(tester);
    expect(find.byType(ScanQrPage), findsOneWidget);
    expect(Navigator.of(tester.element(find.byType(ScanQrPage))),
        same(rootNavigator.currentState));
    expect(find.byType(CupertinoTabBar).hitTestable(), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
