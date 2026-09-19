import 'dart:async';
import 'package:flutter/foundation.dart';
import 'ledger_gateway.dart';
import 'ledger_page_snapshot_store.dart';

final class LedgerController extends ChangeNotifier {
  LedgerController(this.gateway, {LedgerPageSnapshotStore? snapshots})
      : _snapshots = snapshots,
        _epoch = gateway.sessionEpoch {
    _subscription = gateway.sessionInvalidations.listen((_) => _endSession());
    final snapshot = _snapshots?.read();
    if (snapshot != null) {
      // 本地优先：首帧就有上次成功的首页，不用先看一次空白/加载圈。
      _items.addAll(snapshot.items);
      _nextCursor = snapshot.nextCursor;
      _snapshotScope = snapshot.scope;
    }
  }
  final LedgerGateway gateway;
  final LedgerPageSnapshotStore? _snapshots;
  late final StreamSubscription<void> _subscription;
  late final int _epoch;
  final _items = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> get items => List.unmodifiable(_items);
  String? _kind, _query, _nextCursor, error;

  /// 本地快照里的首页来自哪个账号作用域；与当前作用域不一致时必须丢弃。
  String? _snapshotScope;

  /// 有数据时的刷新失败：列表仍在屏幕上，只标记「这次没刷新成功」，
  /// **不**设置 [error]（否则列表尾部会冒出错误/重试条）。
  bool stale = false;

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

  /// 账号切换保护：本地快照里的首页若属于另一个账号，先丢弃再发起请求，
  /// 账单绝不跨账号展示。作用域无法确定时保守丢弃（宁可少显示）。
  Future<void> _dropForeignSnapshot() async {
    final snapshotScope = _snapshotScope;
    if (snapshotScope == null || _items.isEmpty) return;
    String? scope;
    try {
      scope = await gateway.resolveCacheScope();
    } catch (_) {
      scope = null;
    }
    if (_disposed) return;
    if (scope == snapshotScope) return;
    _items.clear();
    _nextCursor = null;
    _snapshotScope = null;
    unawaited(_snapshots?.clear());
  }

  Future<void> _persistSnapshot() async {
    final store = _snapshots;
    if (store == null || _items.isEmpty || hasFilters) return;
    String scope;
    try {
      scope = await gateway.resolveCacheScope();
    } catch (_) {
      return; // 作用域不可知时宁可不落盘，避免快照跨账号。
    }
    _snapshotScope = scope;
    try {
      await store.write(LedgerPageSnapshot(
        scope: scope,
        items: List<Map<String, dynamic>>.of(_items),
        nextCursor: _nextCursor,
        savedAt: DateTime.now(),
      ));
    } catch (_) {
      // 本地快照写失败不是刷新失败。
    }
  }

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
      // 不再清空 _items/_nextCursor：刷新期间与刷新失败后，旧数据都必须留在屏幕上。
      error = null;
      _retryPage = false;
      // 只有真的持有本地快照时才需要等待作用域校验；没有快照就不引入额外的
      // 异步跳转（首次请求的发起时机与旧实现完全一致）。
      if (_snapshotScope != null && _items.isNotEmpty) {
        await _dropForeignSnapshot();
        if (_disposed || generation != _generation) return;
      }
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
      if (refresh) {
        // 首页刷新成功才替换列表：失败路径完全不动已有数据。
        _items
          ..clear()
          ..addAll(rows);
      } else {
        final seen = _items.map((e) => e['id']).toSet();
        for (final row in rows) {
          if (seen.add(row['id'])) {
            _items.add(row);
          }
        }
      }
      _nextCursor = cursor as String?;
      error = null;
      stale = false;
      _retryPage = false;
      if (refresh) unawaited(_persistSnapshot());
    } catch (e) {
      if (!_disposed &&
          generation == _generation &&
          epoch == gateway.sessionEpoch) {
        _retryPage = !refresh;
        if (_items.isEmpty) {
          // 从未成功过且没有任何数据：唯一允许报错的失败。
          error = '账单加载失败，请重试';
        } else if (refresh) {
          stale = true; // 保留列表，只留弱失败标记。
        } else {
          error = '账单加载失败，请重试'; // 翻页失败仍走尾部重试。
        }
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

  /// 是否存在任何筛选条件（展示层据此区分「没有账单」与「没有符合条件的账单」）。
  bool get hasFilters =>
      _kind != null || _startAt != null || _endAt != null ||
      (_query != null && _query!.trim().isNotEmpty);

  /// 一次清空全部筛选（类型/时间/关键词），只发一次列表请求。
  /// 展示层的「重置筛选」入口使用；不改变查询语义与分页规则。
  void clearFilters() {
    if (_disposed || sessionEnded) return;
    _kind = null;
    _startAt = null;
    _endAt = null;
    _query = null;
    _invalidatePending();
    _items.clear();
    _nextCursor = null;
    _notify();
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
