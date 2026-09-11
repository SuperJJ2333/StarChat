import 'dart:async';
import 'package:flutter/foundation.dart';
import 'ledger_gateway.dart';

final class LedgerController extends ChangeNotifier {
  LedgerController(this.gateway) : _epoch = gateway.sessionEpoch {
    _subscription = gateway.sessionInvalidations.listen((_) => _endSession());
  }
  final LedgerGateway gateway;
  late final StreamSubscription<void> _subscription;
  late final int _epoch;
  final _items = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> get items => List.unmodifiable(_items);
  String? _kind, _query, _nextCursor, error;
  DateTime? _startAt, _endAt;
  String? get kind => _kind;
  String? get query => _query;
  String? get nextCursor => _nextCursor;
  bool get hasMore => _nextCursor != null;
  DateTime? get startAt => _startAt;
  DateTime? get endAt => _endAt;
  bool sessionEnded = false;
  bool loading = false;
  bool loadingMore = false;
  int _generation = 0;
  Timer? _debounce;
  bool _disposed = false;
  bool _retryPage = false;
  Future<void> load({bool refresh = true}) async {
    if (_disposed) return;
    if (sessionEnded || gateway.sessionEpoch != _epoch) {
      _endSession();
      return;
    }
    if (!refresh && (_nextCursor == null || loading || loadingMore)) return;
    final generation = refresh ? ++_generation : _generation;
    final epoch = _epoch;
    if (refresh) {
      _items.clear();
      _nextCursor = null;
      error = null;
      _retryPage = false;
    }
    if (refresh) {
      loading = true;
    } else {
      loadingMore = true;
    }
    _notify();
    try {
      final page = await gateway.listLedgerTransactions(
          kind: _kind,
          startAt: _startAt,
          endAt: _endAt,
          q: _query,
          cursor: refresh ? null : _nextCursor);
      if (_disposed || generation != _generation) return;
      if (epoch != gateway.sessionEpoch) {
        _endSession();
        return;
      }
      final raw = page['items'];
      if (raw is! List) throw FormatException('invalid ledger page');
      final cursor = page['next_cursor'];
      if (cursor != null && (cursor is! String || cursor.isEmpty)) {
        throw FormatException('invalid ledger cursor');
      }
      final rows = <Map<String, dynamic>>[];
      for (final row in raw) {
        if (row is! Map ||
            row['id'] is! String ||
            (row['id'] as String).isEmpty) {
          throw FormatException('invalid ledger item');
        }
        rows.add(Map.unmodifiable(Map<String, dynamic>.from(row)));
      }
      final seen = _items.map((e) => e['id']).toSet();
      for (final row in rows) {
        if (seen.add(row['id'])) {
          _items.add(row);
        }
      }
      _nextCursor = cursor as String?;
      error = null;
      _retryPage = false;
    } catch (e) {
      if (!_disposed &&
          generation == _generation &&
          epoch == gateway.sessionEpoch) {
        error = '账单加载失败，请重试';
        _retryPage = !refresh;
      }
    }
    if (_disposed || generation != _generation) return;
    if (epoch != gateway.sessionEpoch) {
      _endSession();
      return;
    }
    loading = false;
    loadingMore = false;
    _notify();
  }

  Future<void> loadMore() => load(refresh: false);
  void _endSession() {
    if (sessionEnded) return;
    _generation++;
    sessionEnded = true;
    _items.clear();
    _nextCursor = null;
    _debounce?.cancel();
    loading = false;
    loadingMore = false;
    error = '会话已结束，请重新打开账单';
    _notify();
  }

  void _invalidatePending() {
    _generation++;
    _debounce?.cancel();
    loading = false;
    loadingMore = false;
    error = null;
  }

  void search(String value) {
    if (_disposed || sessionEnded) return;
    _query = value;
    _invalidatePending();
    _items.clear();
    _nextCursor = null;
    _notify();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!_disposed && !sessionEnded) unawaited(load(refresh: true));
    });
  }

  void setKind(String? value) {
    if (_disposed || sessionEnded) return;
    _kind = value;
    _invalidatePending();
    unawaited(load(refresh: true));
  }

  void setDateRange(DateTime? start, DateTime? end) {
    if (_disposed || sessionEnded) return;
    if (start != null && end != null && !start.isBefore(end)) {
      error = '开始日期不能晚于结束日期';
      _notify();
      return;
    }
    _startAt = start;
    _endAt = end;
    _invalidatePending();
    unawaited(load(refresh: true));
  }

  Future<void> retry() => load(refresh: !_retryPage);
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _debounce?.cancel();
    _subscription.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
