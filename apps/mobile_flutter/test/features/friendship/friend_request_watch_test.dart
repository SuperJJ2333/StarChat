import 'dart:convert';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/friendship/friend_request_watch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('friend alert reuses message category with sound and high priority',
      () async {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    Map? arguments;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'show') arguments = call.arguments as Map;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await FriendRequestNotifier()
        .show(nickname: 'Alice', message: 'hello', signature: 'request-1');
    final details = arguments!['platformSpecifics'] as Map;
    expect(details['channelId'], 'chatflow_messages_v2');
    expect(details['playSound'], isTrue);
    expect(details['priority'], 1);
    expect(arguments!['payload'], 'friend-requests');
  });

  test(
      'outgoing accepted greeting retries then completes once and excludes outgoing badge',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    var accepted = false;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: SecureSessionStore(),
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 'incoming',
                  'status': 'PENDING',
                  'direction': 'INCOMING'
                },
                {
                  'id': 'outgoing',
                  'status': 'PENDING',
                  'direction': 'OUTGOING'
                },
                {
                  'id': 'accepted',
                  'status': accepted ? 'ACCEPTED' : 'PENDING',
                  'direction': 'OUTGOING',
                  'message': '你好，我是Alice',
                  'matrix_user_id': '@bob:test'
                },
              ]
            }),
            200,
            headers: {'content-type': 'application/json'})));
    final prefs = await SharedPreferences.getInstance();
    var sends = 0;
    final watch = FriendRequestWatch(api, prefs, accountKey: '@alice:test',
        onOutgoingAccepted: (request) async {
      sends++;
      expect(request['message'], '你好，我是Alice');
      if (sends == 1) throw StateError('offline');
    });
    expect(await watch.poll(), 1);
    expect(sends, 0);
    accepted = true;
    expect(await watch.poll(), 1);
    expect(await watch.poll(), 1);
    expect(await watch.poll(), 1);
    expect(sends, 2);
    final restarted = FriendRequestWatch(api, prefs,
        accountKey: '@alice:test', onOutgoingAccepted: (_) async => sends++);
    await restarted.poll();
    expect(sends, 2);
    final freshDevice = FriendRequestWatch(api, prefs,
        accountKey: '@fresh:test', onOutgoingAccepted: (_) async => sends++);
    await freshDevice.poll();
    expect(sends, 2,
        reason:
            'historical accepted requests must not replay on a fresh device');
  });
}
