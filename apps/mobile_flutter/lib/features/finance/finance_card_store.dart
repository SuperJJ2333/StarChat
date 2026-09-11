import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/business_api_client.dart';

enum FinanceCardKind { redPacket, transfer }

final class FinanceCardKey {
  const FinanceCardKey(this.kind, this.id);
  const FinanceCardKey.redPacket(String id)
      : this(FinanceCardKind.redPacket, id);
  const FinanceCardKey.transfer(String id) : this(FinanceCardKind.transfer, id);
  final FinanceCardKind kind;
  final String id;
  @override
  bool operator ==(Object other) =>
      other is FinanceCardKey && other.kind == kind && other.id == id;
  @override
  int get hashCode => Object.hash(kind, id);
}

abstract interface class FinanceCardGateway {
  int get sessionEpoch;
  Stream<void> get sessionInvalidations;
  Future<String?> currentUserId();
  Future<Map<String, dynamic>> redPacketDetail(String id);
  Future<Map<String, dynamic>> chatTransferDetail(String id);
}

final class BusinessFinanceCardGateway implements FinanceCardGateway {
  BusinessFinanceCardGateway(this.api);
  final BusinessApiClient api;
  @override
  int get sessionEpoch => api.sessionEpoch;
  @override
  Stream<void> get sessionInvalidations => api.sessionInvalidations.map((_) {});
  @override
  Future<String?> currentUserId() => api.currentUserId();
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) =>
      api.redPacketDetail(id);
  @override
  Future<Map<String, dynamic>> chatTransferDetail(String id) =>
      api.chatTransferDetail(id);
}

final class FinanceCardState {
  const FinanceCardState(
      {this.detail,
      this.viewerId,
      this.loading = false,
      this.error,
      this.updatedAt,
      this.ended = false});
  final Map<String, dynamic>? detail;
  final String? viewerId;
  final String? error;
  final bool loading;
  final bool ended;
  final DateTime? updatedAt;
  bool get terminal {
    final status = detail?['status'];
    if (status == 'COMPLETED' ||
        status == 'EXPIRED' ||
        status == 'CANCELLED' ||
        status == 'ACCEPTED' ||
        status == 'DECLINED') {
      return true;
    }
    final serverTime = DateTime.tryParse('${detail?['server_time'] ?? ''}');
    final expiresAt = DateTime.tryParse('${detail?['expires_at'] ?? ''}');
    return serverTime != null &&
        expiresAt != null &&
        !serverTime.toUtc().isBefore(expiresAt.toUtc());
  }

  FinanceCardState copyWith(
          {Map<String, dynamic>? detail,
          String? viewerId,
          bool? loading,
          String? error,
          DateTime? updatedAt,
          bool? ended,
          bool keepError = false,
          bool clearDetail = false}) =>
      FinanceCardState(
        detail: clearDetail ? null : detail ?? this.detail,
        viewerId: viewerId ?? this.viewerId,
        loading: loading ?? this.loading,
        error: keepError ? this.error : error,
        updatedAt: updatedAt ?? this.updatedAt,
        ended: ended ?? this.ended,
      );
}

final class FinanceCardLease {
  FinanceCardLease._(this._store, this.key, this._entry);
  final FinanceCardStore _store;
  final FinanceCardKey key;
  final _Entry _entry;
  bool _visible = false;
  bool _disposed = false;
  ValueNotifier<FinanceCardState> get notifier => _entry.notifier;
  bool get visible => _visible;
  void setVisible(bool visible, {bool force = false}) {
    if (!_disposed) _store._setVisible(this, visible, force: force);
  }

  Future<FinanceCardState> ensureFresh({bool force = true}) => _disposed
      ? Future.value(notifier.value)
      : _store._ensure(this, force: force);
  void retry() {
    unawaited(ensureFresh());
  }

  void dispose() {
    if (!_disposed) {
      _disposed = true;
      _store._release(this);
    }
  }
}

final class FinanceCardStore {
  FinanceCardStore(this.gateway,
      {this.refreshPeriod = const Duration(seconds: 15),
      this.maxEntries = 200,
      DateTime Function()? now})
      : assert(maxEntries > 0),
        _now = now ?? DateTime.now,
        _epoch = gateway.sessionEpoch {
    _sub = gateway.sessionInvalidations.listen((_) => _end());
  }
  final FinanceCardGateway gateway;
  final Duration refreshPeriod;
  final int maxEntries;
  final DateTime Function() _now;
  final int _epoch;
  late final StreamSubscription<void> _sub;
  final _entries = <FinanceCardKey, _Entry>{};
  final _queue = <_Entry>[];
  int _active = 0;
  bool _ended = false;
  bool _disposed = false;

  @visibleForTesting
  int get cacheEntryCount => _entries.length;

  FinanceCardLease lease(FinanceCardKey key) {
    if (!_live()) {
      if (_disposed) return FinanceCardLease._(this, key, _Entry.ended(key));
      final entry = _entry(key, ended: true);
      entry.references++;
      return FinanceCardLease._(this, key, entry);
    }
    final entry = _entry(key);
    entry.references++;
    return FinanceCardLease._(this, key, entry);
  }

  void invalidate(FinanceCardKey key) {
    if (_live()) {
      final entry = _entries[key];
      if (entry != null) {
        _touch(entry);
        _invalidate(entry);
      }
    }
  }

  _Entry _entry(FinanceCardKey key, {bool ended = false}) {
    final entry =
        _entries.remove(key) ?? (ended ? _Entry.ended(key) : _Entry(key));
    _entries[key] = entry;
    return entry;
  }

  void _touch(_Entry entry) {
    _entries.remove(entry.key);
    _entries[entry.key] = entry;
  }

  bool _live() {
    if (_disposed) return false;
    if (_ended || gateway.sessionEpoch != _epoch) {
      _end();
      return false;
    }
    return true;
  }

  bool _owns(FinanceCardLease lease) =>
      identical(_entries[lease.key], lease._entry);

  void _setVisible(FinanceCardLease lease, bool visible,
      {required bool force}) {
    if (!_live() || !_owns(lease)) return;
    final entry = lease._entry;
    _touch(entry);
    if (lease._visible == visible) {
      if (visible && force) _ensureRequest(entry, force: true);
      return;
    }
    lease._visible = visible;
    entry.visibleLeases += visible ? 1 : -1;
    if (!visible && entry.visibleLeases == 0) {
      entry.timer?.cancel();
      if (entry.explicitReaders == 0) _removeQueued(entry);
      entry.notifier.value =
          entry.notifier.value.copyWith(loading: false, keepError: true);
      if (entry.inFlight && entry.explicitReaders == 0) {
        entry.generation++;
        entry.dirty = true;
      }
      return;
    }
    if (visible) _ensureRequest(entry, force: force);
  }

  Future<FinanceCardState> _ensure(FinanceCardLease lease,
      {required bool force}) async {
    if (!_live() || !_owns(lease)) return lease.notifier.value;
    final entry = lease._entry;
    _touch(entry);
    entry.explicitReaders++;
    try {
      if (!entry.inFlight && !entry.queued) _ensureRequest(entry, force: force);
      final settled = entry.settled;
      if (settled != null) await settled.future;
      return entry.notifier.value;
    } finally {
      entry.explicitReaders--;
      _trim();
    }
  }

  void _invalidate(_Entry entry) {
    if (entry.inFlight) {
      if (!entry.dirty) entry.generation++;
      entry.dirty = true;
      return;
    }
    entry.dirty = true;
    if (entry.visibleLeases > 0 || entry.explicitReaders > 0) _enqueue(entry);
  }

  void _ensureRequest(_Entry entry, {required bool force}) {
    if (!_live() || entry.notifier.value.ended) return;
    if (entry.inFlight || entry.queued) return;
    final stale = entry.notifier.value.updatedAt == null ||
        _now().difference(entry.notifier.value.updatedAt!) >= refreshPeriod;
    if (force ||
        entry.dirty ||
        ((entry.visibleLeases > 0 || entry.explicitReaders > 0) &&
            !entry.notifier.value.terminal &&
            stale)) {
      _invalidate(entry);
    }
    _scheduleTimer(entry);
  }

  void _enqueue(_Entry entry) {
    if (entry.queued ||
        entry.inFlight ||
        (entry.visibleLeases == 0 && entry.explicitReaders == 0)) {
      return;
    }
    entry.settled ??= Completer<void>();
    entry.queued = true;
    entry.notifier.value = entry.notifier.value.copyWith(loading: true);
    _queue.add(entry);
    _drain();
  }

  void _removeQueued(_Entry entry) {
    if (!entry.queued) return;
    _queue.remove(entry);
    entry.queued = false;
    _settle(entry);
  }

  void _drain() {
    while (_live() && _active < 4 && _queue.isNotEmpty) {
      final entry = _queue.removeAt(0);
      entry.queued = false;
      if (entry.visibleLeases == 0 && entry.explicitReaders == 0) {
        _settle(entry);
        continue;
      }
      entry.inFlight = true;
      entry.dirty = false;
      final generation = entry.generation;
      _active++;
      unawaited(_get(entry, generation));
    }
  }

  Future<void> _get(_Entry entry, int generation) async {
    try {
      final viewerId = await gateway.currentUserId();
      if (!_live() || generation != entry.generation) return;
      final detail = entry.key.kind == FinanceCardKind.redPacket
          ? await gateway.redPacketDetail(entry.key.id)
          : await gateway.chatTransferDetail(entry.key.id);
      if (!_live() || generation != entry.generation) return;
      entry.notifier.value = FinanceCardState(
          detail: Map.unmodifiable(detail),
          viewerId: viewerId,
          updatedAt: _now());
    } catch (error) {
      if (_live() && generation == entry.generation) {
        entry.notifier.value =
            error is BusinessApiException && error.statusCode == 403
                ? FinanceCardState(error: '无权查看该状态', updatedAt: _now())
                : entry.notifier.value
                    .copyWith(loading: false, error: '加载状态失败，请重试');
      }
    } finally {
      _active--;
      entry.inFlight = false;
      if (_live()) {
        if (entry.dirty &&
            (entry.visibleLeases > 0 || entry.explicitReaders > 0)) {
          _enqueue(entry);
        } else {
          entry.notifier.value =
              entry.notifier.value.copyWith(loading: false, keepError: true);
          _settle(entry);
          if (!entry.dirty) _scheduleTimer(entry);
        }
        _trim();
        _drain();
      }
    }
  }

  void _scheduleTimer(_Entry entry) {
    entry.timer?.cancel();
    if (!_live() ||
        entry.inFlight ||
        entry.queued ||
        entry.visibleLeases == 0 ||
        entry.notifier.value.terminal) {
      return;
    }
    entry.timer =
        Timer(refreshPeriod, () => _ensureRequest(entry, force: true));
  }

  void _settle(_Entry entry) {
    final settled = entry.settled;
    if (settled != null && !settled.isCompleted) settled.complete();
    entry.settled = null;
  }

  void _release(FinanceCardLease lease) {
    if (!_owns(lease)) return;
    if (lease._visible) _setVisible(lease, false, force: false);
    lease._entry.references--;
    _touch(lease._entry);
    _trim();
  }

  void _trim() {
    while (_entries.length > maxEntries) {
      _Entry? candidate;
      for (final entry in _entries.values) {
        if (entry.references == 0 &&
            entry.explicitReaders == 0 &&
            !entry.inFlight &&
            !entry.queued &&
            entry.settled == null) {
          candidate = entry;
          break;
        }
      }
      if (candidate == null) return;
      candidate.timer?.cancel();
      candidate.notifier.dispose();
      _entries.remove(candidate.key);
    }
  }

  void _end() {
    if (_disposed || _ended) return;
    _ended = true;
    _queue.clear();
    for (final entry in _entries.values) {
      entry.timer?.cancel();
      entry.notifier.value =
          const FinanceCardState(error: '会话已结束', ended: true);
      _settle(entry);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sub.cancel();
    for (final entry in _entries.values) {
      entry.timer?.cancel();
      entry.notifier.dispose();
      _settle(entry);
    }
    _entries.clear();
    _queue.clear();
  }
}

final class _Entry {
  _Entry(this.key) : notifier = ValueNotifier(const FinanceCardState());
  _Entry.ended(this.key)
      : notifier =
            ValueNotifier(const FinanceCardState(error: '会话已结束', ended: true));
  final FinanceCardKey key;
  final ValueNotifier<FinanceCardState> notifier;
  int references = 0;
  int visibleLeases = 0;
  int generation = 0;
  bool queued = false;
  bool inFlight = false;
  bool dirty = false;
  int explicitReaders = 0;
  Timer? timer;
  Completer<void>? settled;
}
