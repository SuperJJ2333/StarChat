import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/src/utils/send_timing.dart';

void main() {
  test('native encryption timer preserves synchronous execution without a gap',
      () {
    var calls = 0;
    final result = measureMatrixSendSync(MatrixSendTiming.encrypt, () {
      calls++;
      return 'ciphertext';
    }, (_, __) => throw StateError('diagnostic'));
    expect(calls, 1);
    expect(result, 'ciphertext');
    expect(measureMatrixSendSync(MatrixSendTiming.encrypt, () => ++calls, null),
        2);
  });
  test('send timing closes exactly once after asynchronous work settles',
      () async {
    final release = Completer<String>();
    final samples = <(MatrixSendTiming, int)>[];
    final result = measureMatrixSend(MatrixSendTiming.queueWait,
        () => release.future, (phase, us) => samples.add((phase, us)));
    expect(samples, isEmpty);
    release.complete('accepted');
    expect(await result, 'accepted');
    expect(samples, hasLength(1));
    expect(samples.single.$1, MatrixSendTiming.queueWait);
    expect(samples.single.$2, greaterThanOrEqualTo(0));
  });

  test('timing observer failure cannot replace a send failure or success',
      () async {
    final failure = StateError('synthetic send failure');
    void observer(MatrixSendTiming phase, int us) =>
        throw StateError('synthetic diagnostic failure');
    await expectLater(
        measureMatrixSend(MatrixSendTiming.http,
            () => Future<String>.error(failure), observer),
        throwsA(same(failure)));
    expect(
        await measureMatrixSend(
            MatrixSendTiming.http, () => 'accepted', observer),
        'accepted');
  });

  test('failed work still records its closed category once', () async {
    final samples = <MatrixSendTiming>[];
    await expectLater(
        measureMatrixSend(
            MatrixSendTiming.sessionPersist,
            () => throw StateError('synthetic persistence failure'),
            (phase, us) => samples.add(phase)),
        throwsStateError);
    expect(samples, [MatrixSendTiming.sessionPersist]);
  });
}
