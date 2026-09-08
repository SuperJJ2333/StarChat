import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/matrix/media_message_service.dart';
import 'package:matrix/matrix.dart';

final class _RoomClient extends Client {
  _RoomClient() : super('media-ui');
  late final Room testRoom = _DirectTestRoom(client: this);

  @override
  Room? getRoomById(String roomId) =>
      roomId == testRoom.id ? testRoom : super.getRoomById(roomId);
}

final class _DirectTestRoom extends Room {
  _DirectTestRoom({required super.client}) : super(id: '!room:matrix.test');

  @override
  bool get isDirectChat => true;

  @override
  String? get directChatMatrixID => '@peer:matrix.test';
}

final class _RecordingMediaSender implements RoomPickedMediaSender {
  final calls = <String>[];
  Completer<void>? pendingSend;
  bool disposed = false;
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<String> sendFile(String roomId) async {
    calls.add('file:$roomId');
    return r'$event';
  }

  @override
  Future<String> sendImage(String roomId) async {
    calls.add('image:$roomId');
    await pendingSend?.future;
    return r'$event';
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('room image action sends through its owned Matrix room lease',
      (tester) async {
    final client = _RoomClient();
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
    );
    final lease = await matrix.openRoomLease(client.testRoom.id);
    final sender = _RecordingMediaSender();
    MatrixEncryptedMediaGateway? capturedGateway;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 404)),
    );

    await tester.pumpWidget(CupertinoApp(
      home: RoomPage(
        api: api,
        roomLease: lease,
        roomName: 'Encrypted room',
        onCreateGroup: () {},
        mediaSenderFactory: (gateway) {
          capturedGateway = gateway;
          return sender;
        },
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-more')));
    await tester.pump();
    await tester.tap(find.text('图片'));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(capturedGateway, same(lease));
    expect(sender.calls, ['image:!room:matrix.test']);

    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
  });
  testWidgets('room lease cancellation drains an in-flight picked media action',
      (tester) async {
    final client = _RoomClient();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.test'));
    final lease = await matrix.openRoomLease(client.testRoom.id);
    final pending = Completer<void>();
    final sender = _RecordingMediaSender()..pendingSend = pending;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://business.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((_) async => http.Response('{}', 404)),
    );
    await tester.pumpWidget(CupertinoApp(
        home: RoomPage(
      api: api,
      roomLease: lease,
      roomName: 'Encrypted room',
      onCreateGroup: () {},
      mediaSenderFactory: (_) => sender,
    )));
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-more')));
    await tester.pump();
    await tester.tap(find.text('图片'));
    await tester.pump();
    expect(sender.calls, ['image:!room:matrix.test']);
    var canceled = false;
    final cancellation = lease.cancel().then((_) => canceled = true);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(canceled, isFalse);
    expect(sender.disposed, isFalse);
    pending.complete();
    await tester.pump();
    await cancellation;
    expect(sender.disposed, isTrue);
    expect(canceled, isTrue);
    expect(tester.takeException(), isNull);
  });
}
