import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/features/matrix/media_index.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('only an actual media index SQL query emits a database span', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('index-perf-');
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    final index = MediaIndex(
      databasePath: '${directory.path}/index.db',
      performanceRecorder: recorder,
    );
    try {
      await index.lookup('private-account', '!private-room', r'$private-event');
      final query = records.single;
      expect(query.databaseOperation, PerformanceDatabaseOperation.mediaIndexLookup);
      expect(query.rowCountBucket, PerformanceRowCountBucket.zero);
      expect(query.stagesUs.keys, [
        PerformanceStage.cacheLoadStarted, PerformanceStage.cacheLoadDone]);
      expect(query.toJson().toString(), isNot(contains('private')));
      expect(query.timingSummaryMs['database_ms'], isNotNull);
    } finally {
      await index.close();
      recorder.clear();
      await directory.delete(recursive: true);
    }
  });
}
