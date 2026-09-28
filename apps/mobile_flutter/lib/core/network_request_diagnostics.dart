import 'network_diagnostics.dart' show DiagnosticNetwork, parseDiagnosticUtc;

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _version = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,8})?$');

/// Closed failure metadata. No transport text, URI or payload is retained.
final class NetworkRequestDiagnosticSnapshot {
  NetworkRequestDiagnosticSnapshot._(Map<String, Object> json)
      : _json = Map.unmodifiable(json);
  final Map<String, Object> _json;
  String get requestId => _json['request_id'] as String;
  Map<String, Object> toJson() => Map.of(_json);

  static NetworkRequestDiagnosticSnapshot? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    const required = {
      'request_id',
      'version',
      'platform',
      'target',
      'network',
      'method',
      'endpoint_category',
      'started_at',
      'elapsed_ms',
      'phase',
      'reason',
    };
    const optional = {
      'operation_id',
      'headers_ms',
      'http_status',
      'timeout_budget_ms',
      'timeout_lateness_ms',
    };
    if (!required.every(value.containsKey) ||
        !value.keys
            .every((key) => required.contains(key) || optional.contains(key))) {
      return null;
    }
    bool id(Object? n) => n is String && _uuid.hasMatch(n);
    bool ms(Object? n) => n is int && n >= 0 && n <= 3600000;
    if (!id(value['request_id']) ||
        value['version'] is! String ||
        !_version.hasMatch(value['version'] as String) ||
        !const ['android', 'ios', 'other'].contains(value['platform']) ||
        value['target'] != 'primary_api' ||
        !DiagnosticNetwork.values.any((n) => n.name == value['network']) ||
        !const [
          'GET',
          'POST',
          'PUT',
          'PATCH',
          'DELETE',
          'HEAD',
          'OPTIONS',
          'OTHER'
        ].contains(value['method']) ||
        !const [
          'auth',
          'profile',
          'contacts',
          'media',
          'finance',
          'settings',
          'support',
          'other'
        ].contains(value['endpoint_category']) ||
        parseDiagnosticUtc(value['started_at']) == null ||
        !ms(value['elapsed_ms']) ||
        !const [
          'awaiting_headers',
          'reading_body',
          'response_complete',
          'unknown'
        ].contains(value['phase']) ||
        !const [
          'timeout',
          'socket',
          'tls',
          'http_transport',
          'aborted',
          'unexpected',
          'http_5xx'
        ].contains(value['reason'])) {
      return null;
    }
    if (value.containsKey('operation_id') && !id(value['operation_id'])) {
      return null;
    }
    if (value.containsKey('headers_ms') &&
        (!ms(value['headers_ms']) ||
            (value['headers_ms'] as int) > (value['elapsed_ms'] as int))) {
      return null;
    }
    final status = value['http_status'];
    if (value.containsKey('http_status') &&
        (status is! int || status < 100 || status > 599)) {
      return null;
    }
    if (const ['reading_body', 'response_complete'].contains(value['phase']) &&
        (!value.containsKey('headers_ms') ||
            !value.containsKey('http_status'))) {
      return null;
    }
    if (value['phase'] == 'awaiting_headers' &&
        (value.containsKey('headers_ms') || value.containsKey('http_status'))) {
      return null;
    }
    if (value['reason'] == 'http_5xx' &&
        (status is! int || status < 500 || status > 599)) {
      return null;
    }
    for (final key in ['timeout_budget_ms', 'timeout_lateness_ms']) {
      if (value.containsKey(key) &&
          (value['reason'] != 'timeout' ||
              !ms(value[key]) ||
              (key == 'timeout_budget_ms' && value[key] == 0))) {
        return null;
      }
    }
    return NetworkRequestDiagnosticSnapshot._(value.cast<String, Object>());
  }
}

/// Only a fixed resource group is inspected; no path/query value is stored.
String diagnosticEndpointCategory(Uri uri) {
  final parts = uri.pathSegments;
  final resource = parts.length >= 3 && parts[0] == 'api' && parts[1] == 'v1'
      ? parts[2]
      : '';
  return switch (resource) {
    'auth' || 'phone' || 'email' || 'invitations' => 'auth',
    'profile' || 'users' => 'profile',
    'contacts' ||
    'contact-tags' ||
    'blocks' ||
    'friends' ||
    'friendships' ||
    'groups' =>
      'contacts',
    'media' || 'uploads' || 'moments' => 'media',
    'wallet' ||
    'ledger' ||
    'caibi' ||
    'fx' ||
    'red-packets' ||
    'transfers' ||
    'recharges' ||
    'payouts' ||
    'withdrawals' =>
      'finance',
    'settings' || 'push' || 'presence' || 'app-update' => 'settings',
    'support' || 'complaints' => 'support',
    _ => 'other',
  };
}
