import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/encryption/encryption.dart';
import 'package:matrix/matrix.dart';

class _Device extends Fake implements DeviceKeys {
  _Device(this.number, {this.isBlocked = false});
  final int number;
  final bool isBlocked;
  String publicSuffix = '';
  @override
  String get userId => '@peer$number:synthetic.test';
  @override
  String get deviceId => 'DEVICE$number';
  @override
  bool get blocked => isBlocked;
  @override
  bool get verified => false;
  @override
  String get curve25519Key => 'synthetic-curve-$number$publicSuffix';
  @override
  String get ed25519Key => 'synthetic-ed-$number$publicSuffix';
  @override
  DateTime get lastActive => DateTime.utc(2026);
}

class _Crypto extends Encryption {
  _Crypto(Client client) : super(client: client);
  Set<String> omitted = {};
  bool available = true;
  void Function()? beforeEncryption;
  @override
  bool get enabled => available;
  @override
  Future<Map<String, Map<String, Map<String, dynamic>>>> encryptToDeviceMessage(
      List<DeviceKeys> devices,
      String type,
      Map<String, dynamic> payload) async {
    beforeEncryption?.call();
    return {
      for (final device in devices)
        if (!omitted.contains(device.deviceId))
          device.userId: {
            device.deviceId!: {
              'algorithm': AlgorithmTypes.olmV1Curve25519AesSha2,
              'ciphertext': {
                device.curve25519Key!: {'type': 0, 'body': 'synthetic'}
              }
            }
          }
    };
  }
}

class _Client extends Client {
  factory _Client() {
    late _Client client;
    client = _Client._(MockClient((request) => client.respond(request)));
    client.homeserver = Uri.parse('https://synthetic.test');
    client.bearerToken = 'synthetic';
    return client;
  }
  _Client._(http.Client transport)
      : super('synthetic-room-key-share', httpClient: transport);
  late final crypto = _Crypto(this);
  final batches = <int>[];
  Completer<void>? secondEntered;
  Completer<void>? releaseSecond;
  bool failSecond = false;
  @override
  Encryption get encryption => crypto;
  @override
  String get userID => '@sender:synthetic.test';
  @override
  String get deviceID => 'SENDER';
  Future<http.Response> respond(http.Request request) async {
    final messages = jsonDecode(request.body)['messages'] as Map;
    batches.add(messages.values
        .fold<int>(0, (n, devices) => n + (devices as Map).length));
    if (batches.length == 2) {
      secondEntered?.complete();
      await releaseSecond?.future;
      if (failSecond) throw StateError('SYNTHETIC_SECOND_BATCH_FAILURE');
    }
    return http.Response('{}', 200);
  }
}

class _OverrideClient extends _Client {
  _OverrideClient()
      : super._(MockClient((_) async => http.Response('{}', 200))) {
    homeserver = Uri.parse('https://synthetic.test');
    bearerToken = 'synthetic';
  }
  int publicCalls = 0;
  @override
  Future<void> sendToDevice(String eventType, String txid,
      Map<String, Map<String, Map<String, dynamic>>> messages) async {
    publicCalls++;
  }
}

void main() {
  test('forwarded room key rejects a canonical device replacement before HTTP',
      () async {
    final client = _Client();
    final device = _Device(0);
    final list = DeviceKeysList(device.userId, client)
      ..deviceKeys = {device.deviceId: device};
    client.userDeviceKeys[device.userId] = list;
    client.crypto.beforeEncryption = () {
      list.deviceKeys[device.deviceId] = _Device(0)..publicSuffix = 'changed';
    };
    await expectLater(
        client.sendToDeviceEncrypted([device], EventTypes.ForwardedRoomKey, {}),
        throwsStateError);
    expect(client.batches, isEmpty);
    await client.dispose();
  });
  test(
      'ordinary encrypted control messages retain the public transport override',
      () async {
    final client = _OverrideClient();
    await client.sendToDeviceEncrypted([_Device(0)], EventTypes.Dummy, {});
    expect(client.publicCalls, 1);
    await client.dispose();
  });
  test('eligible room-key target requires encryption to be available',
      () async {
    final client = _Client();
    client.crypto.available = false;
    await expectLater(
        client.sendToDeviceEncrypted([_Device(0)], EventTypes.RoomKey, {}),
        throwsStateError);
    await client.sendToDeviceEncrypted(
        [_Device(0, isBlocked: true)], EventTypes.RoomKey, {});
    expect(client.batches, isEmpty);
    await client.dispose();
  });
  for (final type in [EventTypes.RoomKey, EventTypes.ForwardedRoomKey]) {
    test('$type cannot acknowledge an omitted eligible recipient', () async {
      final client = _Client();
      client.crypto.omitted.add('DEVICE1');
      await expectLater(
          client.sendToDeviceEncrypted([_Device(0), _Device(1)], type, {}),
          throwsStateError);
      expect(client.batches, isEmpty);
      await client.dispose();
    });
    test('$type waits for all chunks and surfaces the second failure',
        () async {
      final client = _Client()
        ..secondEntered = Completer<void>()
        ..releaseSecond = Completer<void>()
        ..failSecond = true;
      var settled = false;
      final send = client.sendToDeviceEncryptedChunked(
          List.generate(21, (i) => _Device(i)),
          type, {}).whenComplete(() => settled = true);
      final assertion = expectLater(send, throwsStateError);
      await client.secondEntered!.future.timeout(const Duration(seconds: 3));
      expect(settled, isFalse);
      client.releaseSecond!.complete();
      await assertion;
      expect(client.batches, [20, 1]);
      await client.dispose();
    });
  }
  test('blocked recipients remain excluded by the existing policy', () async {
    final client = _Client();
    client.crypto.omitted.add('DEVICE1');
    await client.sendToDeviceEncrypted(
        [_Device(0), _Device(1, isBlocked: true)], EventTypes.RoomKey, {});
    expect(client.batches, [1]);
    await client.dispose();
  });
  test('unrelated to-device message behavior stays unchanged', () async {
    final client = _Client();
    client.crypto.omitted.add('DEVICE1');
    await client.sendToDeviceEncrypted(
        [_Device(0), _Device(1)], EventTypes.Dummy, {});
    expect(client.batches, [1]);
    await client.dispose();
  });
}
