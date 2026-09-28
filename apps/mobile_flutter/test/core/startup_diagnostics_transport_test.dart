import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/startup_diagnostics_transport.dart';
import 'startup_diagnostics_spool_test.dart' show report;

void main() {
  test('independent uploader sends no credentials and validates accepted UUID',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) async {
      requests++;
      expect(request.headers.value('authorization'), isNull);
      expect(request.headers.value('cookie'), isNull);
      expect(request.uri.path, '/api/v1/startup-diagnostics');
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      expect(body, report());
      request.response.statusCode = 202;
      request.response.write(jsonEncode({
        'accepted': true,
        'event_id': requests == 1
            ? body['event_id']
            : '00000000-0000-4000-8000-000000000099'
      }));
      await request.response.close();
    });
    final uploader = HttpStartupDiagnosticsTransport(
        Uri.parse('http://127.0.0.1:${server.port}/api/v1/startup-diagnostics'),
        allowInsecureLoopback: true);
    expect(await uploader.upload(report()),
        StartupDiagnosticsUploadResult.accepted);
    expect(
        await uploader.upload(report()), StartupDiagnosticsUploadResult.retry);
  });
  test('does not follow redirects and discards only permanent rejection',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var status = 302;
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = status;
      request.response.headers.set('location', '/redirected');
      await request.response.close();
    });
    final uploader = HttpStartupDiagnosticsTransport(
        Uri.parse('http://127.0.0.1:${server.port}/api/v1/startup-diagnostics'),
        allowInsecureLoopback: true);
    expect(
        await uploader.upload(report()), StartupDiagnosticsUploadResult.retry);
    expect(requests, 1);
    for (final code in [413, 422]) {
      status = code;
      expect(await uploader.upload(report()),
          StartupDiagnosticsUploadResult.permanentFailure);
    }
    for (final code in [404, 429, 503]) {
      status = code;
      expect(await uploader.upload(report()),
          StartupDiagnosticsUploadResult.retry);
    }
  });
  test('absolute deadline and cancellation close never-ending reply', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {});
    final uploader = HttpStartupDiagnosticsTransport(
        Uri.parse('http://127.0.0.1:${server.port}/api/v1/startup-diagnostics'),
        deadline: const Duration(milliseconds: 30),
        allowInsecureLoopback: true);
    expect(
        await uploader.upload(report()), StartupDiagnosticsUploadResult.retry);
    final abort = Completer<void>();
    final pending = uploader.upload(report(), abort: abort.future);
    abort.complete();
    expect(await pending, StartupDiagnosticsUploadResult.retry);
  });
  test('oversized or extended acceptance replies retain queued report',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var body = ' ' * 1025;
    server.listen((request) async {
      request.response.statusCode = 202;
      request.response.write(body);
      await request.response.close();
    });
    final uploader = HttpStartupDiagnosticsTransport(
        Uri.parse('http://127.0.0.1:${server.port}/api/v1/startup-diagnostics'),
        allowInsecureLoopback: true);
    expect(
        await uploader.upload(report()), StartupDiagnosticsUploadResult.retry);
    body = jsonEncode({
      'accepted': true,
      'event_id': report()['event_id'],
      'account_id': 'private'
    });
    expect(
        await uploader.upload(report()), StartupDiagnosticsUploadResult.retry);
    body = jsonEncode({'accepted': 1, 'event_id': report()['event_id']});
    expect(
        await uploader.upload(report()), StartupDiagnosticsUploadResult.retry);
  });
  test('production uploader rejects insecure or credential-bearing endpoint',
      () async {
    for (final endpoint in [
      'http://example.com/api/v1/startup-diagnostics',
      'https://token@example.com/api/v1/startup-diagnostics',
      'https://example.com/api/v1/startup-diagnostics?token=private'
    ]) {
      final uploader = HttpStartupDiagnosticsTransport(Uri.parse(endpoint));
      expect(await uploader.upload(report()),
          StartupDiagnosticsUploadResult.retry);
    }
  });
}
