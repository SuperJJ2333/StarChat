import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:liuhetong_mobile/ui/chat/media_activity.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';

void main() {
  test('foreground reason blocks workers until all reasons end plus 500ms', () {
    fakeAsync((time) {
      final gate =
          MaintenanceActivity(clock: () => DateTime(2026).add(time.elapsed));
      gate.setInteractive('scroll', true);
      gate.setInteractive('keyboard', true);
      var done = false;
      gate.waitForIdle().then((_) => done = true);
      gate.setInteractive('scroll', false);
      time.elapse(const Duration(seconds: 1));
      expect(done, false);
      gate.setInteractive('keyboard', false);
      time.elapse(const Duration(milliseconds: 499));
      expect(done, false);
      time.elapse(const Duration(milliseconds: 1));
      time.flushMicrotasks();
      expect(done, true);
      gate.dispose();
    });
  });
  test('pressure changes cancellation epoch and adds a quiet interval', () {
    fakeAsync((time) {
      final gate =
          MaintenanceActivity(clock: () => DateTime(2026).add(time.elapsed));
      final epoch = gate.pressureEpoch;
      gate.pressure();
      expect(gate.pressureEpoch, epoch + 1);
      expect(gate.canMaintain, false);
      time.elapse(const Duration(milliseconds: 500));
      expect(gate.canMaintain, true);
      gate.dispose();
    });
  });
  test(
      'scroll and background revoke every animation; background still permits idle workers',
      () {
    fakeAsync((time) {
      final gate =
          MaintenanceActivity(clock: () => DateTime(2026).add(time.elapsed));
      final budget = MediaAnimationBudget(maintenance: gate);
      final tokens = List.generate(9, (_) => budget.register(priority: 1));
      time.elapse(const Duration(milliseconds: 500));
      expect(tokens.where((t) => t.granted.value), hasLength(4));
      gate.setInteractive('scroll', true);
      expect(tokens.every((t) => !t.granted.value), true);
      gate.setInteractive('scroll', false);
      time.elapse(const Duration(milliseconds: 499));
      expect(tokens.every((t) => !t.granted.value), true);
      time.elapse(const Duration(milliseconds: 1));
      expect(tokens.where((t) => t.granted.value), hasLength(4));
      gate.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(tokens.every((t) => !t.granted.value), true);
      expect(gate.canMaintain, true);
      gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
      gate.pressure();
      expect(tokens.every((t) => !t.granted.value), true);
      for (final token in tokens) {
        token.dispose();
      }
      expect(gate.registeredConsumers, 0);
      expect(time.nonPeriodicTimerCount, 0);
      gate.dispose();
    });
  });
  test('cancelled maintenance owner releases waiter and its idle timer', () {
    fakeAsync((time) {
      final gate =
          MaintenanceActivity(clock: () => DateTime(2026).add(time.elapsed));
      final cancel = Completer<void>();
      var completed = false;
      gate.waitForIdle(cancelled: cancel.future).then((_) => completed = true);
      expect(gate.pendingWaiters, 1);
      cancel.complete();
      time.flushMicrotasks();
      expect(completed, true);
      expect(gate.pendingWaiters, 0);
      expect(time.nonPeriodicTimerCount, 0);
      gate.dispose();
    });
  });
  test(
      'heavy leases are FIFO, release is idempotent and cancellation removes queue ownership',
      () {
    fakeAsync((time) {
      final gate =
          MaintenanceActivity(clock: () => DateTime(2026).add(time.elapsed));
      time.elapse(const Duration(milliseconds: 500));
      MaintenanceLease? first, second;
      gate.acquireHeavy().then((value) => first = value);
      time.flushMicrotasks();
      expect(first, isNotNull);
      expect(gate.canMaintain, true);
      expect(gate.heavyBusy, true);
      var waited = false;
      gate.waitForIdle().then((_) => waited = true);
      time.flushMicrotasks();
      expect(waited, false);
      final cancel = Completer<void>();
      var cancelledDone = false;
      gate.acquireHeavy(cancellation: cancel.future).then((value) {
        expect(value, isNull);
        cancelledDone = true;
      });
      gate.acquireHeavy().then((value) => second = value);
      cancel.complete();
      time.flushMicrotasks();
      expect(cancelledDone, true);
      expect(second, isNull);
      first!.release();
      first!.release();
      time.flushMicrotasks();
      expect(second, isNotNull);
      second!.dispose();
      time.flushMicrotasks();
      expect(waited, true);
      expect(gate.heavyBusy, false);
      expect(time.nonPeriodicTimerCount, 0);
      gate.dispose();
    });
  });
}
