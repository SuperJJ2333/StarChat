import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/content_addressed_media.dart';
import 'package:liuhetong_mobile/features/matrix/media_consumer_scope.dart';
import 'package:liuhetong_mobile/features/matrix/media_load_scheduler.dart';
import 'package:liuhetong_mobile/features/matrix/media_transfer_budget.dart';

class _Http extends http.BaseClient {
  _Http(this.chunks);
  final List<List<int>> chunks;
  Completer<void>? pending;
  int starts = 0, chunksRead = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    starts++;
    await pending?.future;
    Stream<List<int>> body() async* {
      for (final chunk in chunks) {
        chunksRead++;
        yield chunk;
      }
    }

    return http.StreamedResponse(body(), 200);
  }
}

class _Client extends Client {
  _Client(http.Client http) : super('synthetic-budget', httpClient: http);
  @override
  Uri get homeserver => Uri.parse('https://matrix.test');
  @override
  Future<bool> authenticatedMediaSupported() async => true;
  @override
  bool get encryptionEnabled => true;
}

Event eventFor(http.Client http, {EncryptedFile? encrypted}) => Event(
        room: Room(id: '!synthetic:test', client: _Client(http)),
        eventId: r'$synthetic',
        senderId: '@synthetic:test',
        originServerTs: DateTime.utc(2026),
        type: EventTypes.Message,
        content: {
          'body': 'synthetic.bin',
          'msgtype': MessageTypes.File,
          if (encrypted == null)
            'url': 'mxc://matrix.test/synthetic'
          else
            'file': {
              'url': 'mxc://matrix.test/synthetic',
              'v': 'v2',
              'iv': encrypted.iv,
              'hashes': {'sha256': encrypted.sha256},
              'key': {
                'k': encrypted.k,
                'key_ops': ['decrypt'],
                'alg': 'A256CTR',
                'kty': 'oct',
                'ext': true
              }
            },
        });

void main() {
  test('ordinary SDK download enforces actual stream cap with unknown length',
      () async {
    final http = _Http([
      [1, 2],
      [3, 4],
      [5, 6]
    ]);
    final budget = MediaTransferBudget(maxBytes: 12);
    await expectLater(
        budget.run(MediaTransferPlan.download(3),
            () => downloadMediaContent(eventFor(http))),
        throwsA(isA<MediaContentLimitException>()));
    expect(http.chunksRead, 2);
    expect(budget.activeBytes, 0);
  });

  test('uncancellable pending HTTP retains reservation until actual settle',
      () async {
    final http = _Http([
      [1, 2, 3]
    ])
      ..pending = Completer<void>();
    final scope = MediaConsumerScope();
    final budget = MediaTransferBudget(maxBytes: 12);
    final result = scope.run(() => budget.run(MediaTransferPlan.download(3),
        () => downloadMediaContent(eventFor(http))));
    final check = expectLater(result, throwsA(isA<MediaLoadCanceled>()));
    await Future<void>.delayed(Duration.zero);
    expect(http.starts, 1);
    scope.cancel();
    expect(budget.activeBytes, 12);
    http.pending!.complete();
    await check;
    expect(budget.activeBytes, 0);
  });

  test('real SDK still authenticates ciphertext before returning plaintext',
      () async {
    final envelope =
        await MediaEnvelope.forBytes(Uint8List.fromList([1, 2, 3]));
    final cipher = envelope.encrypted;
    final good = _Http([cipher.data]);
    expect(await downloadMediaContent(eventFor(good, encrypted: cipher)),
        [1, 2, 3]);
    final damaged = Uint8List.fromList(cipher.data)..[0] ^= 1;
    await expectLater(
        downloadMediaContent(eventFor(_Http([damaged]), encrypted: cipher)),
        throwsA(anything));
    expect(sharedMediaTransferBudget.activeBytes, 0);
  });
}
