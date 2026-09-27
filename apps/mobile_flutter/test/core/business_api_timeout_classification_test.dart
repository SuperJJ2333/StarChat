import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_performance_client.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  test('generic request deadline keeps timeout without guessing network phase',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    final client = BusinessApiPerformanceClient(
      MockClient((_) async => throw TimeoutException('private endpoint')),
      recorder: recorder,
    );
    await expectLater(
        client.get(Uri.parse('https://example.test/api/v1/friends')),
        throwsA(isA<TimeoutException>()));
    final json = records.single.toJson();
    expect(json['network_error'], 'request_timeout');
    expect(json['network_error'], isNot('connect_timeout'));
    expect(json['network_error'], isNot('read_timeout'));
    expect(json.toString(), isNot(contains('private endpoint')));
    client.close();
    recorder.clear();
  });

  test('logical request timeout after HTTP headers retains actual status',
      () async {
    final records = <PerformanceRecord>[];
    final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true), onRecord: records.add);
    final client = BusinessApiPerformanceClient(
      MockClient((_) async => http.Response('{}', 200)),
      recorder: recorder,
    );
    final scope = client.beginLogicalRequest()!;
    await scope.run(
        () => client.get(Uri.parse('https://example.test/api/v1/contacts')));
    scope.finish(failure: TimeoutException('body deadline'));
    expect(records.single.statusCode, 200);
    expect(records.single.toJson()['network_error'], 'request_timeout');
    expect(records.single.transportAvailable, isTrue);
    expect(records.single.serviceReachable, isTrue);
    expect(records.single.result, PerformanceResult.failed);
    client.close();
    recorder.clear();
  });
}
