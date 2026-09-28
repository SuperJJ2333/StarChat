import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_performance_client.dart';
import 'package:liuhetong_mobile/core/diagnostic_time_anchor.dart';
import 'package:liuhetong_mobile/core/performance_metrics.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';

void main() {
  test('only authenticated Business API Date calibrates later UI span',
      () async {
    var nowUs = 1000000;
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      timeAnchor: DiagnosticTimeAnchor(),
    );
    final client = BusinessApiPerformanceClient(
      MockClient((request) async {
        nowUs = 1200000;
        return http.Response('', 200,
            request: request,
            headers: {'date': 'Mon, 28 Sep 2026 08:00:00 GMT'});
      }),
      recorder: recorder,
      trustedBaseUri: Uri.parse('https://api.example'),
    );
    final request =
        http.Request('GET', Uri.parse('https://api.example/api/v1/profile/me'));
    request.headers['Authorization'] = 'Bearer synthetic';
    await http.Response.fromStream(await client.send(request));
    final trace = recorder.start(PerformanceOperationType.keyboardTransition);
    trace.keyboardDirection = PerformanceKeyboardDirection.show;
    nowUs = 2200000;
    expect(
        trace.finish().toJson()['started_at_utc'], '2026-09-28T08:00:00.100Z');
  });

  test('anonymous and foreign responses cannot calibrate UTC', () async {
    var nowUs = 1000000;
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      timeAnchor: DiagnosticTimeAnchor(),
    );
    final client = BusinessApiPerformanceClient(
      MockClient((_) async {
        nowUs += 200000;
        return http.Response('', 200,
            headers: {'date': 'Mon, 28 Sep 2026 08:00:00 GMT'});
      }),
      recorder: recorder,
      trustedBaseUri: Uri.parse('https://api.example'),
    );
    await http.Response.fromStream(await client.send(
      http.Request('GET', Uri.parse('https://api.example/api/v1/auth/login')),
    ));
    final foreign = http.Request(
        'GET', Uri.parse('https://foreign.example/api/v1/profile/me'));
    foreign.headers['Authorization'] = 'Bearer synthetic';
    await http.Response.fromStream(await client.send(foreign));
    final trace = recorder.start(PerformanceOperationType.keyboardTransition);
    trace.keyboardDirection = PerformanceKeyboardDirection.hide;
    nowUs += 100000;
    expect(trace.finish().toJson(), isNot(contains('started_at_utc')));
  });

  test('rejected and redirect responses cannot calibrate UTC', () async {
    for (final status in [401, 302, 500]) {
      var nowUs = 1000000;
      final recorder = PerformanceTraceRecorder(
        metrics: PerformanceMetrics(enabled: true),
        clockUs: () => nowUs,
        timeAnchor: DiagnosticTimeAnchor(),
      );
      final client = BusinessApiPerformanceClient(
        MockClient((_) async {
          nowUs += 200000;
          return http.Response('', status,
              headers: {'date': 'Mon, 28 Sep 2026 08:00:00 GMT'});
        }),
        recorder: recorder,
        trustedBaseUri: Uri.parse('https://api.example'),
      );
      final request = http.Request(
          'GET', Uri.parse('https://api.example/api/v1/profile/me'));
      request.headers['Authorization'] = 'Bearer synthetic';
      await http.Response.fromStream(await client.send(request));
      final trace = recorder.start(PerformanceOperationType.keyboardTransition);
      trace.keyboardDirection = PerformanceKeyboardDirection.show;
      nowUs += 100000;
      expect(trace.finish().toJson(), isNot(contains('started_at_utc')),
          reason: 'HTTP $status cannot prove authenticated server time');
    }
  });

  test('a followed redirect to another origin cannot calibrate UTC', () async {
    var nowUs = 1000000;
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      timeAnchor: DiagnosticTimeAnchor(),
    );
    final client = BusinessApiPerformanceClient(
      MockClient((_) async {
        nowUs += 200000;
        return http.Response('', 200,
            request: http.Request('GET', Uri.parse('https://foreign.example/')),
            headers: {'date': 'Mon, 28 Sep 2026 08:00:00 GMT'});
      }),
      recorder: recorder,
      trustedBaseUri: Uri.parse('https://api.example'),
    );
    final request =
        http.Request('GET', Uri.parse('https://api.example/api/v1/profile/me'));
    request.headers['Authorization'] = 'Bearer synthetic';
    await http.Response.fromStream(await client.send(request));
    final trace = recorder.start(PerformanceOperationType.keyboardTransition);
    trace.keyboardDirection = PerformanceKeyboardDirection.show;
    nowUs += 100000;
    expect(trace.finish().toJson(), isNot(contains('started_at_utc')));
  });

  test('an invalid Date never changes a successful business response',
      () async {
    var nowUs = 1000000;
    final recorder = PerformanceTraceRecorder(
      metrics: PerformanceMetrics(enabled: true),
      clockUs: () => nowUs,
      timeAnchor: DiagnosticTimeAnchor(),
    );
    final client = BusinessApiPerformanceClient(
      MockClient((request) async {
        nowUs += 200000;
        return http.Response('OK', 200,
            request: request,
            headers: {'date': 'Mon, 28 Foo 2026 08:00:00 GMT'});
      }),
      recorder: recorder,
      trustedBaseUri: Uri.parse('https://api.example'),
    );
    final request =
        http.Request('GET', Uri.parse('https://api.example/api/v1/profile/me'));
    request.headers['Authorization'] = 'Bearer synthetic';
    final response = await http.Response.fromStream(await client.send(request));
    expect(response.statusCode, 200);
    expect(response.body, 'OK');
    final trace = recorder.start(PerformanceOperationType.keyboardTransition);
    trace.keyboardDirection = PerformanceKeyboardDirection.show;
    nowUs += 100000;
    expect(trace.finish().toJson(), isNot(contains('started_at_utc')));
  });
}
