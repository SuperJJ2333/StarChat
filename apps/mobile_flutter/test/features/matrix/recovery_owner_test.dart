import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/src/utils/recovery_operation_owner.dart';

void main() {
  for (final boundary in [
    'secure-store',
    'session-import',
    'receipt',
    'history',
    'index',
    'outbound'
  ]) {
    test('$boundary actual write drains after response deadline and revoke',
        () async {
      var current = true;
      final owner =
          RecoveryOperationOwner(identity: Object(), isCurrent: () => current);
      final held = Completer<void>();
      var invoked = false;
      final write = owner.write(() {
        expect(owner.pendingWrites, 1);
        invoked = true;
        return held.future;
      });
      expect(invoked, isTrue);
      await expectLater(
          write.timeout(Duration.zero), throwsA(isA<TimeoutException>()));
      current = false;
      owner.revoke();
      var drained = false;
      final drain = owner.drain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      expect(() => owner.write(() async => fail('late invocation')),
          throwsStateError);
      held.complete();
      await write;
      await drain;
      expect(owner.pendingWrites, 0);
    });
  }
  test('late readonly completion cannot enter revoked owner', () async {
    final owner =
        RecoveryOperationOwner(identity: Object(), isCurrent: () => true);
    final result = Completer<int>();
    final read = owner.read(() => result.future);
    owner.revoke();
    final expectation = expectLater(read, throwsStateError);
    result.complete(1);
    await expectation;
    expect(owner.pendingWrites, 0);
  });
}
