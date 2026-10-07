import 'package:matrix/src/database/database_api.dart';

class RetainedSearchStore {
  RetainedSearchStore(Object collection, TimelineSearchMigrationReader? reader);
  bool get ownsTransaction => false;
  Future<void> open() async {}
  Future<void> upsert(String room, TimelineSearchEntry entry,
      {bool deleted = false, bool migration = false}) async {}
  Future<void> remove(String room, String id) async {}
  Future<void> prepare(
      String room, Future<TimelineIdSnapshot> Function() current) async {}
  Future<TimelineIdSnapshot> snapshot(String room) async =>
      ListTimelineIdSnapshot([]);
  void scheduleGarbage(String room) {}
  Future<void> clear({String? room}) async {}
  Future<void> close() async {}
}
