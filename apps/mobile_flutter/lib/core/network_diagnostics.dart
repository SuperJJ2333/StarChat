import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOStreamedResponse;
import 'package:uuid/uuid.dart';

enum DiagnosticNetwork { unknown, wifi, mobile, ethernet, vpn, none, other }

enum NetworkOutcome {
  http2xx,
  http3xx,
  http4xx,
  http5xx,
  networkError,
  timeout,
  cancelled,
}

const _outcomeNames = [
  'http_2xx',
  'http_3xx',
  'http_4xx',
  'http_5xx',
  'network_errors',
  'timeouts',
  'cancelled',
];
const _boundaries = [100, 250, 500, 1000, 2000, 5000, 10000, 30000];
final _versionPattern = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,8})?$');
final _idPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _utcPattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(?:Z|\+00:00)$',
);

/// DateTime.tryParse normalizes impossible dates. Validate the closed wire
/// grammar and all calendar components before accepting persisted metadata.
DateTime? parseDiagnosticUtc(Object? value) {
  if (value is! String) return null;
  final match = _utcPattern.firstMatch(value);
  if (match == null) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc || parsed.year < 1) return null;
  final parts = [
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
  ];
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] != int.parse(match.group(i + 1)!)) return null;
  }
  final fraction = match.group(7) ?? '';
  if (parsed.millisecond * 1000 + parsed.microsecond !=
      int.parse(fraction.padRight(6, '0'))) {
    return null;
  }
  return parsed;
}

/// Immutable, closed metadata. No caller-provided text or transport data enters
/// the summary. Persisted summaries retain their original release and window.
final class NetworkDiagnosticSnapshot {
  NetworkDiagnosticSnapshot._(Map<String, Object> json)
    : _json = Map.unmodifiable({
        ...json,
        'success_latency_buckets': List<int>.unmodifiable(
          json['success_latency_buckets'] as List<int>,
        ),
      });
  final Map<String, Object> _json;
  String get sampleId => _json['sample_id'] as String;
  int get attempts => _json['attempts'] as int;
  Map<String, Object> toJson() => {
    ..._json,
    'success_latency_buckets': List<int>.of(
      _json['success_latency_buckets'] as List<int>,
    ),
  };

  static NetworkDiagnosticSnapshot? tryParse(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    const keys = {
      'sample_id',
      'version',
      'platform',
      'window_start',
      'window_end',
      'target',
      'network',
      'attempts',
      'http_2xx',
      'http_3xx',
      'http_4xx',
      'http_5xx',
      'network_errors',
      'timeouts',
      'cancelled',
      'success_latency_buckets',
    };
    if (value.length != keys.length || !value.keys.every(keys.contains)) {
      return null;
    }
    if (value['sample_id'] is! String ||
        !_idPattern.hasMatch(value['sample_id'] as String) ||
        value['version'] is! String ||
        !_versionPattern.hasMatch(value['version'] as String) ||
        !const ['android', 'ios', 'other'].contains(value['platform']) ||
        value['target'] != 'primary_api' ||
        !DiagnosticNetwork.values.any((n) => n.name == value['network'])) {
      return null;
    }
    final start = parseDiagnosticUtc(value['window_start']),
        end = parseDiagnosticUtc(value['window_end']);
    if (start == null || end == null || start.isAfter(end)) return null;
    bool count(Object? n) => n is int && n >= 0 && n <= 1000000;
    if (!count(value['attempts']) ||
        value['attempts'] == 0 ||
        !_outcomeNames.every((key) => count(value[key]))) {
      return null;
    }
    final buckets = value['success_latency_buckets'];
    if (buckets is! List || buckets.length != 9 || !buckets.every(count)) {
      return null;
    }
    if (_outcomeNames.fold<int>(0, (sum, key) => sum + (value[key] as int)) !=
            value['attempts'] ||
        buckets.cast<int>().fold<int>(0, (a, b) => a + b) !=
            value['http_2xx']) {
      return null;
    }
    return NetworkDiagnosticSnapshot._({
      ...value.cast<String, Object>(),
      'success_latency_buckets': buckets.cast<int>(),
    });
  }
}

final class _Counts {
  _Counts(this.start, this.end);
  DateTime start, end;
  final outcomes = List<int>.filled(7, 0);
  final buckets = List<int>.filled(9, 0);
  int attempts = 0;
}

/// Fixed-size counters on the request path; snapshots freeze only at flush/stop.
final class NetworkDiagnostics {
  NetworkDiagnostics({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  static const maximumSnapshots = 32;
  final _active = <DiagnosticNetwork, _Counts>{};
  final _queue = <NetworkDiagnosticSnapshot>[];
  int _generation = 0;
  String? _version, _platform;
  bool _supported = true;
  DiagnosticNetwork network = DiagnosticNetwork.unknown;
  int droppedAttempts = 0;
  bool get hasPending => _queue.isNotEmpty || _active.isNotEmpty;

  void start({
    required String version,
    required String platform,
    required int generation,
  }) {
    clear();
    _version = version;
    _platform = platform;
    _generation = generation;
  }

  void clear() {
    _generation++;
    _version = _platform = null;
    _active.clear();
    _queue.clear();
    _supported = true;
    network = DiagnosticNetwork.unknown;
    droppedAttempts = 0;
  }

  void disable() {
    _supported = false;
    _active.clear();
    _queue.clear();
  }

  NetworkAttempt? begin() {
    if (_version == null || !_supported) return null;
    return NetworkAttempt._(this, _generation, network, _now().toUtc());
  }

  void _complete(
    NetworkAttempt attempt,
    NetworkOutcome outcome,
    Duration elapsed,
  ) {
    if (_version == null || !_supported || attempt._generation != _generation) {
      return;
    }
    final wallEnd = _now().toUtc();
    final end = wallEnd.isBefore(attempt._start) ? attempt._start : wallEnd;
    final counts = _active.putIfAbsent(
      attempt._network,
      () => _Counts(attempt._start, end),
    );
    if (counts.attempts >= 1000000) {
      droppedAttempts++;
      return;
    }
    if (attempt._start.isBefore(counts.start)) counts.start = attempt._start;
    if (end.isAfter(counts.end)) counts.end = end;
    counts.attempts++;
    counts.outcomes[outcome.index]++;
    if (outcome == NetworkOutcome.http2xx) {
      final ms = elapsed.inMilliseconds;
      final index = _boundaries.indexWhere((upper) => ms <= upper);
      counts.buckets[index < 0 ? 8 : index]++;
    }
  }

  void freeze() {
    for (final entry in _active.entries) {
      final c = entry.value;
      final snapshot = NetworkDiagnosticSnapshot._({
        'sample_id': const Uuid().v4(),
        'version': _version!,
        'platform': _platform!,
        'window_start': c.start.toIso8601String(),
        'window_end': c.end.toIso8601String(),
        'target': 'primary_api',
        'network': entry.key.name,
        'attempts': c.attempts,
        for (var i = 0; i < _outcomeNames.length; i++)
          _outcomeNames[i]: c.outcomes[i],
        'success_latency_buckets': c.buckets,
      });
      restore(snapshot);
    }
    _active.clear();
  }

  void restore(NetworkDiagnosticSnapshot snapshot) {
    if (_queue.any((item) => item.sampleId == snapshot.sampleId)) return;
    if (_queue.length >= maximumSnapshots) {
      droppedAttempts += snapshot.attempts;
      return;
    }
    _queue.add(snapshot);
  }

  List<NetworkDiagnosticSnapshot> pending({int limit = 8}) {
    freeze();
    return List.unmodifiable(_queue.take(limit));
  }

  List<NetworkDiagnosticSnapshot> get persisted {
    freeze();
    return List.unmodifiable(_queue);
  }

  void acknowledge(Iterable<NetworkDiagnosticSnapshot> sent) {
    final ids = sent.map((s) => s.sampleId).toSet();
    _queue.removeWhere((s) => ids.contains(s.sampleId));
  }
}

final class NetworkAttempt {
  NetworkAttempt._(this._owner, this._generation, this._network, this._start);
  final NetworkDiagnostics _owner;
  final int _generation;
  final DiagnosticNetwork _network;
  final DateTime _start;
  final _watch = Stopwatch()..start();
  bool _ended = false;
  void complete(NetworkOutcome outcome, {Duration? elapsed}) {
    if (_ended) return;
    _ended = true;
    _watch.stop();
    _owner._complete(this, outcome, elapsed ?? _watch.elapsed);
  }

  void error(Object error) => complete(
    error is TimeoutException
        ? NetworkOutcome.timeout
        : error is http.RequestAbortedException
        ? NetworkOutcome.cancelled
        : NetworkOutcome.networkError,
  );
}

/// Decorates transport, never changes requests, retry, authentication or timeout.
/// Completion means consuming the full response body, not receiving headers.
final class DiagnosticHttpClient extends http.BaseClient {
  DiagnosticHttpClient(this._inner, this._diagnostics);
  final http.Client _inner;
  final NetworkDiagnostics Function() _diagnostics;
  static final _attemptGroupKey = Object();
  Future<T> _track<T>(Future<T> Function() action) {
    if (Zone.current[_attemptGroupKey] != null) return action();
    final group = <NetworkAttempt>[];
    final future = runZoned(action, zoneValues: {_attemptGroupKey: group});
    return _RequestFuture<T>(future, group);
  }

  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) =>
      _track(() => super.get(url, headers: headers));
  @override
  Future<http.Response> head(Uri url, {Map<String, String>? headers}) =>
      _track(() => super.head(url, headers: headers));
  @override
  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _track(
    () => super.post(url, headers: headers, body: body, encoding: encoding),
  );
  @override
  Future<http.Response> put(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _track(
    () => super.put(url, headers: headers, body: body, encoding: encoding),
  );
  @override
  Future<http.Response> patch(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _track(
    () => super.patch(url, headers: headers, body: body, encoding: encoding),
  );
  @override
  Future<http.Response> delete(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) => _track(
    () => super.delete(url, headers: headers, body: body, encoding: encoding),
  );
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _track(() => _send(request));
  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    final attempt = _diagnostics().begin();
    if (attempt != null) {
      (Zone.current[_attemptGroupKey] as List<NetworkAttempt>?)?.add(attempt);
    }
    try {
      final response = await _inner.send(request);
      if (attempt == null) return response;
      late StreamSubscription<List<int>> subscription;
      late StreamController<List<int>> controller;
      controller = StreamController<List<int>>(
        sync: true,
        onListen: () {
          subscription = response.stream.listen(
            controller.add,
            onError: (Object e, StackTrace s) {
              attempt.error(e);
              controller.addError(e, s);
            },
            onDone: () {
              final outcome = switch (response.statusCode) {
                >= 200 && < 300 => NetworkOutcome.http2xx,
                >= 300 && < 400 => NetworkOutcome.http3xx,
                >= 400 && < 500 => NetworkOutcome.http4xx,
                >= 500 && < 600 => NetworkOutcome.http5xx,
                _ => NetworkOutcome.networkError,
              };
              attempt.complete(outcome);
              unawaited(controller.close());
            },
          );
        },
        onPause: () => subscription.pause(),
        onResume: () => subscription.resume(),
        onCancel: () {
          attempt.complete(NetworkOutcome.cancelled);
          return subscription.cancel();
        },
      );
      if (response is IOStreamedResponse) {
        if (response is http.BaseResponseWithUrl) {
          return _IoResponseWithUrl(
            controller.stream,
            response,
            (response as http.BaseResponseWithUrl).url,
          );
        }
        return _IoResponse(controller.stream, response);
      }
      if (response is http.BaseResponseWithUrl) {
        return _ResponseWithUrl(
          controller.stream,
          response,
          (response as http.BaseResponseWithUrl).url,
        );
      }
      return _Response(controller.stream, response);
    } catch (error) {
      attempt?.error(error);
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}

/// Future.timeout only bounds its caller; it does not cancel HTTP. Observe the
/// same timeout without aborting the connection or replacing its late result.
/// The token completes once, so late bytes cannot count a second outcome.
final class _RequestFuture<T> implements Future<T> {
  _RequestFuture(this._inner, this._attempts);
  final Future<T> _inner;
  final List<NetworkAttempt> _attempts;
  @override
  Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) =>
      _RequestFuture(
        _inner.timeout(
          timeLimit,
          onTimeout: () {
            for (final attempt in _attempts) {
              attempt.complete(NetworkOutcome.timeout);
            }
            if (onTimeout != null) return onTimeout();
            throw TimeoutException('Future not completed', timeLimit);
          },
        ),
        _attempts,
      );
  @override
  Stream<T> asStream() => _inner.asStream();
  @override
  Future<T> catchError(Function onError, {bool Function(Object)? test}) =>
      _RequestFuture(_inner.catchError(onError, test: test), _attempts);
  @override
  Future<R> then<R>(FutureOr<R> Function(T) onValue, {Function? onError}) =>
      _RequestFuture(_inner.then(onValue, onError: onError), _attempts);
  @override
  Future<T> whenComplete(FutureOr<void> Function() action) =>
      _RequestFuture(_inner.whenComplete(action), _attempts);
}

class _Response extends http.StreamedResponse {
  _Response(Stream<List<int>> stream, http.StreamedResponse original)
    : super(
        stream,
        original.statusCode,
        contentLength: original.contentLength,
        request: original.request,
        headers: original.headers,
        isRedirect: original.isRedirect,
        persistentConnection: original.persistentConnection,
        reasonPhrase: original.reasonPhrase,
      );
}

final class _ResponseWithUrl extends _Response
    implements http.BaseResponseWithUrl {
  _ResponseWithUrl(super.stream, super.original, this.url);
  @override
  final Uri url;
}

class _IoResponse extends IOStreamedResponse {
  _IoResponse(Stream<List<int>> stream, this.original)
    : super(
        stream,
        original.statusCode,
        contentLength: original.contentLength,
        request: original.request,
        headers: original.headers,
        isRedirect: original.isRedirect,
        persistentConnection: original.persistentConnection,
        reasonPhrase: original.reasonPhrase,
      );
  final IOStreamedResponse original;
  @override
  Future<Socket> detachSocket() => original.detachSocket();
}

final class _IoResponseWithUrl extends _IoResponse
    implements http.BaseResponseWithUrl {
  _IoResponseWithUrl(super.stream, super.original, this.url);
  @override
  final Uri url;
}
