import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'startup_diagnostics_spool.dart';

enum StartupDiagnosticsUploadResult { accepted, permanentFailure, retry }

abstract interface class StartupDiagnosticsTransport {
  Future<StartupDiagnosticsUploadResult> upload(Map<String, Object> report,
      {Future<void>? abort});
}

/// No business client, session store or authentication interceptor is used.
/// Each attempt owns a fresh connection, closed at its absolute deadline.
final class HttpStartupDiagnosticsTransport
    implements StartupDiagnosticsTransport {
  HttpStartupDiagnosticsTransport(this.endpoint,
      {this.deadline = const Duration(seconds: 5),
      this.allowInsecureLoopback = false});
  final Uri endpoint;
  final Duration deadline;
  final bool allowInsecureLoopback;
  @override
  Future<StartupDiagnosticsUploadResult> upload(Map<String, Object> report,
      {Future<void>? abort}) async {
    final loopback =
        const {'127.0.0.1', '::1', 'localhost'}.contains(endpoint.host);
    if ((endpoint.scheme != 'https' &&
            !(allowInsecureLoopback &&
                loopback &&
                endpoint.scheme == 'http')) ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.path != '/api/v1/startup-diagnostics') {
      return StartupDiagnosticsUploadResult.retry;
    }
    final client = HttpClient()..connectionTimeout = deadline;
    Future<StartupDiagnosticsUploadResult> send() async {
      try {
        final body = utf8.encode(jsonEncode(report));
        if (body.length > 4096) {
          return StartupDiagnosticsUploadResult.permanentFailure;
        }
        final request = await client.postUrl(endpoint);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.contentLength = body.length;
        request.add(body);
        final response = await request.close();
        if (response.statusCode == 413 || response.statusCode == 422) {
          return StartupDiagnosticsUploadResult.permanentFailure;
        }
        if (response.statusCode != 202) {
          return StartupDiagnosticsUploadResult.retry;
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 1024) {
            return StartupDiagnosticsUploadResult.retry;
          }
          bytes.addAll(chunk);
        }
        final decoded = jsonDecode(utf8.decode(bytes));
        return decoded is Map &&
                decoded.length == 2 &&
                decoded['accepted'] == true &&
                isStartupDiagnosticsUuid(decoded['event_id']) &&
                decoded['event_id'] == report['event_id']
            ? StartupDiagnosticsUploadResult.accepted
            : StartupDiagnosticsUploadResult.retry;
      } catch (_) {
        return StartupDiagnosticsUploadResult.retry;
      }
    }

    try {
      return await Future.any([
        send(),
        if (abort != null)
          abort.then((_) {
            client.close(force: true);
            return StartupDiagnosticsUploadResult.retry;
          }),
      ]).timeout(deadline, onTimeout: () {
        client.close(force: true);
        return StartupDiagnosticsUploadResult.retry;
      });
    } catch (_) {
      return StartupDiagnosticsUploadResult.retry;
    } finally {
      client.close(force: true);
    }
  }
}
