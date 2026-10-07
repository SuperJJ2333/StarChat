import 'package:matrix/src/database/database_api.dart';

/// Web databases keep their existing compatibility implementation.
class TimelineIdStore {
  TimelineIdStore(Object collection, TimelineMigrationReader? reader);
  Future<void> open() async {}
  Future<void> prepare(String key) async {}
  Future<void> add(String key, String id,
      {bool tail = false, bool move = false}) async {}
  Future<void> remove(String key, String id) async {}
  Future<void> reset(String key) async {}
  Future<int> count(String key) async => 0;
  Future<Map<String, int>> positions(String key, Iterable<String> ids) async =>
      {};
  Future<TimelineIdSnapshot> snapshot(String key,
          {String? afterEventId,
          TimelineIdDirection direction = TimelineIdDirection.older}) async =>
      ListTimelineIdSnapshot([]);
  Future<List<String>> page(String key, {int start = 0, int? limit}) async =>
      [];
  Future<List<String>> preview(String key, int limit) async => [];
  Future<Map<String, List>> exportLegacy() async => {};
  void scheduleGarbage(String key) {}
  Future<void> collectGarbage(String key) async {}
  Future<void> clear() async {}
  Future<void> close() async {}
}
