import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/content_addressed_media.dart';

void main() {
  test(
      'chunked file verification preserves exact digest and rejects corruption',
      () async {
    final expected = sha256.convert([1, 2, 3, 4]).toString();
    await verifyMediaContentStream(
        Stream.fromIterable([
          [1],
          [2, 3],
          [4]
        ]),
        expected);
    await expectLater(
        verifyMediaContentStream(
            Stream.fromIterable([
              [1],
              [2, 0],
              [4]
            ]),
            expected),
        throwsFormatException);
    await expectLater(
        verifyMediaContentStream(
            Stream.fromIterable([
              [1],
              [2, 3]
            ]),
            expected),
        throwsFormatException);
  });
}
