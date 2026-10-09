import 'dart:async';

import 'package:matrix/matrix.dart';

/// Lets UI/timer events run during a chain of cached SDK persistence Futures.
///
/// The SDK still owns each write, cache, transaction, and commit. In particular,
/// yielding never resolves a write early or moves it outside its transaction
/// zone. This does not preempt one expensive event or reduce SDK serialization.
class CooperativeMatrixDatabase extends MatrixSdkDatabase {
  CooperativeMatrixDatabase(
    super.name, {
    super.database,
    super.sqfliteFactory,
    super.timelineMigrationReader,
    super.timelineMaintenanceWait,
    super.timelineMaintenanceLease,
    super.timelineLegacyPageReader,
    super.timelineSearchMigrationReader,
  });

  static const _workBudget = Duration(milliseconds: 8);
  static const _eventsPerSlice = 16;

  final _workClock = Stopwatch();
  int _completedEvents = 0;

  @override
  Future<void> storeEventUpdate(EventUpdate eventUpdate, Client client) async {
    if (!_workClock.isRunning) _workClock.start();
    await super.storeEventUpdate(eventUpdate, client);
    _completedEvents++;
    if (_completedEvents < _eventsPerSlice &&
        _workClock.elapsed < _workBudget) {
      return;
    }

    // A completed Future only drains microtasks. A zero-duration timer allows
    // platform input/frame callbacks to run and resumes in the original zone.
    await Future<void>.delayed(Duration.zero);
    _completedEvents = 0;
    _workClock
      ..reset()
      ..start();
  }
}
