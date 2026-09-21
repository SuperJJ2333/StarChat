import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

final class _SendClient extends Client {
  _SendClient()
      : super('send-classification',
            sendTimelineEventTimeout: const Duration(microseconds: -1));
  @override
  String? get userID => '@me:test';
  final responses = <Future<String> Function()>[];
  final transactions = <String>[];
  bool failSettlement = false;
  @override
  Future<void> handleSync(SyncUpdate sync, {Direction? direction}) async {
    final status = sync.rooms!.join!.values.first.timeline!.events!.first
        .unsigned![messageSendingStatusKey];
    if (failSettlement && status != EventStatus.sending.intValue) {
      failSettlement = false;
      throw StateError('local settlement unavailable');
    }
  }

  @override
  Future<String> sendMessage(String roomId, String eventType, String txnId,
      Map<String, Object?> body) {
    transactions.add(txnId);
    return responses.removeAt(0)();
  }
}

void main() {
  test('failed local echo persistence does not replace the server rejection',
      () async {
    final client = _SendClient()..failSettlement = true;
    final rejected =
        MatrixException(http.Response('{"errcode":"M_FORBIDDEN"}', 403));
    client.responses
        .addAll([() => Future.error(rejected), () async => r'$next']);
    final room = Room(id: '!room:test', client: client);
    await expectLater(
        room.sendTextEvent('fixture', txid: 'first'), throwsA(same(rejected)));
    expect(await room.sendTextEvent('fixture', txid: 'second'), r'$next');
    await client.dispose();
  });
  for (final status in [403, 429, 503]) {
    test('SDK preserves HTTP $status and releases the room send queue',
        () async {
      final client = _SendClient();
      final error = MatrixException(
          http.Response('{"errcode":"M_FORBIDDEN","error":"denied"}', status));
      client.responses.addAll([
        () => Future.error(error),
        () async => r'$next',
      ]);
      final room = Room(id: '!room:test', client: client);
      await expectLater(
          room.sendTextEvent('fixture', txid: 'first'), throwsA(same(error)));
      expect(await room.sendTextEvent('fixture', txid: 'second'), r'$next');
      expect(client.transactions, ['first', 'second']);
      await client.dispose();
    });
  }

  test('settlement failure cannot permanently occupy the send queue', () async {
    final client = _SendClient()..failSettlement = true;
    client.responses.addAll([() async => r'$one', () async => r'$two']);
    final room = Room(id: '!room:test', client: client);
    await expectLater(
        room.sendTextEvent('fixture', txid: 'one'), throwsStateError);
    expect(
        await room
            .sendTextEvent('fixture', txid: 'two')
            .timeout(const Duration(milliseconds: 200)),
        r'$two');
    await client.dispose();
  });

  test('network exhaustion remains retryable with the same transaction',
      () async {
    final client = _SendClient();
    client.responses.addAll([
      () => Future.error(const SocketException('offline')),
      () async => r'$retried',
    ]);
    final room = Room(id: '!room:test', client: client);
    await expectLater(room.sendTextEvent('fixture', txid: 'stable'),
        throwsA(isA<SocketException>()));
    expect(await room.sendTextEvent('fixture', txid: 'stable'), r'$retried');
    expect(client.transactions, ['stable', 'stable']);
    await client.dispose();
  });
}
