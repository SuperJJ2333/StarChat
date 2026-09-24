import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/search/global_search_index.dart';
import 'package:liuhetong_mobile/features/search/local_message_search_repository.dart';

final class _CountingSource implements LocalHistorySearchSource {
  int reads = 0;

  @override
  Future<List<String>> localRoomIds() async {
    reads++;
    return const [];
  }

  @override
  Future<List<LocalSearchMessage>> readRecentMessages(
      {required String roomId, required int limit}) async {
    reads++;
    return const [];
  }
}

void main() {
  test('in-memory message search records its own duration and result bucket',
      () {
    var nowUs = 0;
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs += 10000,
      onRecord: records.add,
    );
    final source = _CountingSource();
    final repository = LocalMessageSearchRepository(
      source: source,
      index: GlobalSearchIndex(),
    );
    repository.recordRoomMessages([
      LocalSearchMessage(
        eventId: r'$private-event',
        senderId: '@private-user:example.test',
        senderName: 'Private Name',
        timestamp: DateTime.utc(2026, 9, 25),
        body: 'private search plaintext',
        roomId: '!private-room:example.test',
        roomName: 'Private Room',
      ),
    ]);
    final trace = recorder.start(PerformanceOperationType.search);

    final hits = repository.search('private', trace: trace);
    trace.finish();

    expect(hits, hasLength(1));
    expect(source.reads, 0,
        reason: 'search only reads the existing memory index');
    expect(records, hasLength(1));
    final record = records.single;
    expect(
        record.betweenMs(PerformanceStage.localSearchStarted,
            PerformanceStage.localSearchDone),
        10);
    expect(record.resultCountBucket, PerformanceRowCountBucket.oneToTwenty);
    expect(record.databaseOperation, isNull);
    expect(record.rowCountBucket, isNull);
    final safeJson = record.toJson().toString();
    expect(safeJson, contains('one_to_twenty'));
    expect(safeJson, isNot(contains('private')));
  });

  test('empty search records zero results without a database claim', () {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      onRecord: records.add,
    );
    final repository = LocalMessageSearchRepository(index: GlobalSearchIndex());
    final trace = recorder.start(PerformanceOperationType.search);

    expect(repository.search('missing', trace: trace), isEmpty);
    trace.finish();

    expect(records.single.resultCountBucket, PerformanceRowCountBucket.zero);
    expect(records.single.databaseOperation, isNull);
  });
}
