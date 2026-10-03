import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/media_message_service.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoUploadGateway extends Fake implements MatrixEncryptedMediaGateway {}

class _CameraClient extends Client {
  _CameraClient(super.name);
  @override
  String? get userID => '@self:test';
  late final testRoom = _CameraRoom(client: this);
  @override
  Room? getRoomById(String roomId) => testRoom;
}

class _CameraRoom extends Room {
  _CameraRoom({required super.client}) : super(id: '!camera:test');
  @override
  bool get isDirectChat => false;
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      _EmptyTimeline();
}

class _EmptyTimeline extends Fake implements Timeline {
  @override
  List<Event> get events => [];
  @override
  bool get canRequestHistory => false;
  @override
  bool get canRequestFuture => false;
  @override
  bool get isFragmentedTimeline => false;
  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {}
  @override
  void cancelSubscriptions() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const camera = MethodChannel('plugins.flutter.io/image_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MediaMessageService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.llfbandit.record/messages'),
        (_) async => null);
    service = MediaMessageService(_NoUploadGateway());
  });
  tearDown(() async {
    await service.dispose();
    messenger.setMockMethodCallHandler(camera, null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.llfbandit.record/messages'), null);
  });

  for (final video in [false, true]) {
    final kind = video ? 'video' : 'photo';
    Future<String?> capture() =>
        video ? service.captureVideoToFile() : service.captureToFile();

    test(
        '$kind invokes system camera and returns the local path without upload',
        () async {
      messenger.setMockMethodCallHandler(camera, (call) async {
        expect(call.method, video ? 'pickVideo' : 'pickImage');
        expect(call.arguments['source'], 0);
        if (!video) {
          expect(call.arguments['maxWidth'], 2160);
          expect(call.arguments['imageQuality'], 92);
        }
        return '/synthetic/camera.$kind';
      });
      expect(await capture(), '/synthetic/camera.$kind');
    });

    test('$kind cancellation returns null without a failure', () async {
      messenger.setMockMethodCallHandler(camera, (_) async => null);
      expect(await capture(), isNull);
    });

    for (final entry in const {
      'camera_access_denied': '相机权限未开启，请在系统设置中允许相机权限',
      'camera_access_restricted': '相机使用受系统限制，请检查系统设置',
      'no_available_camera': '未找到可用的系统相机',
      'already_active': '相机或相册正在使用，请完成后再试',
      'unknown_native_failure': '系统相机拍摄失败，请重试',
    }.entries) {
      test(
          '$kind ${entry.key} is a safe distinguishable failure, not cancellation',
          () async {
        messenger.setMockMethodCallHandler(camera, (_) async {
          throw PlatformException(
              code: entry.key,
              message: 'sensitive-native-path',
              details: {'token': 'sensitive-token'});
        });
        await expectLater(
            capture(),
            throwsA(isA<Exception>().having((error) => error.toString(),
                'safe user feedback', entry.value)));
      });
    }

    Future<void> mountRoom(WidgetTester tester, String account) async {
      final matrix = MatrixSdkE2eeClient(_CameraClient(account),
          homeserver: Uri.parse('https://matrix.test'));
      final lease = await matrix.openRoomLease('!camera:test');
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://business.test'),
          sessionStore: SecureSessionStore(),
          client: MockClient((_) async => http.Response('{}', 404)));
      await tester.pumpWidget(CupertinoApp(
          home: RoomPage(
              api: api,
              roomLease: lease,
              roomName: 'Camera room',
              onCreateGroup: () {})));
      await tester.pump();
    }

    Future<void> openCamera(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('composer-more')));
      await tester.pump();
      if (video) {
        await tester.longPress(find.text('拍摄'));
      } else {
        await tester.tap(find.text('拍摄'));
      }
      await tester.pump();
      await tester.pump();
    }

    testWidgets('$kind permission failure reaches truthful room feedback',
        (tester) async {
      messenger.setMockMethodCallHandler(camera, (_) async {
        throw PlatformException(code: 'camera_access_denied');
      });
      await mountRoom(tester, 'camera-a');
      await openCamera(tester);
      expect(find.text('相机权限未开启，请在系统设置中允许相机权限'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$kind cancelled capture does not show failure feedback',
        (tester) async {
      messenger.setMockMethodCallHandler(camera, (_) async => null);
      await mountRoom(tester, 'camera-a');
      await openCamera(tester);
      expect(find.text('拍摄失败，请重试'), findsNothing);
      expect(find.text('视频准备失败，请重试'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        '$kind late failure after lease replacement cannot enter new room',
        (tester) async {
      final pending = Completer<String?>();
      messenger.setMockMethodCallHandler(camera, (_) => pending.future);
      await mountRoom(tester, 'camera-a');
      await openCamera(tester);
      await mountRoom(tester, 'camera-b');
      pending.completeError(PlatformException(code: 'camera_access_denied'));
      await tester.pump();
      await tester.pump();
      expect(find.text('相机权限未开启，请在系统设置中允许相机权限'), findsNothing);
      expect(find.text('拍摄失败，请重试'), findsNothing);
      expect(find.text('视频准备失败，请重试'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
