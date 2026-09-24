import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

enum SupportRole {
  supportAgent('SUPPORT_AGENT'),
  financeSupport('FINANCE_SUPPORT'),
  supportSupervisor('SUPPORT_SUPERVISOR'),
  user('USER'),
  superAdmin('SUPER_ADMIN');

  const SupportRole(this.wireValue);
  final String wireValue;

  static SupportRole fromWireValue(Object? value) =>
      SupportRole.values.firstWhere(
        (role) => role.wireValue == value?.toString(),
        orElse: () => SupportRole.user,
      );

  bool get mayDisplayBadge => switch (this) {
        SupportRole.supportAgent ||
        SupportRole.financeSupport ||
        SupportRole.supportSupervisor =>
          true,
        SupportRole.user || SupportRole.superAdmin => false,
      };
}

/// Business-API result. It is deliberately separate from Matrix names and
/// profile data so an untrusted Matrix display name cannot mint a badge.
final class SupportIdentity {
  const SupportIdentity({
    required this.queryId,
    required this.userId,
    required this.matrixUserId,
    required this.badge,
    required this.role,
  });

  final String queryId;
  final String userId;
  final String? matrixUserId;
  final String? badge;
  final SupportRole role;

  String? get verifiedBadge {
    final value = badge?.trim();
    if (!role.mayDisplayBadge || value == null) return null;
    return RegExp('^[\u4E00-\u9FFF]{2,6}\$').hasMatch(value) ? value : null;
  }

  factory SupportIdentity.fromJson(Map<String, dynamic> json) =>
      SupportIdentity(
        queryId: json['query_id']?.toString() ?? '',
        userId: json['user_id']?.toString() ?? '',
        matrixUserId: _nonBlank(json['matrix_user_id']),
        badge: _nonBlank(json['badge']),
        role: SupportRole.fromWireValue(json['role']),
      );
}

abstract interface class SupportIdentityGateway {
  Future<List<SupportIdentity>> lookupSupportIdentities(List<String> userIds);
}

/// Display-only business identity snapshot. Staleness triggers background
/// revalidation on access, never removal. Only authoritative responses revoke
/// badges; failed/offline lookups retain the last verified presentation.
final class SupportIdentityRepository extends ChangeNotifier {
  SupportIdentityRepository(
    this._gateway, {
    this.ttl = const Duration(minutes: 5),
    Future<String?> Function()? scope,
    SupportIdentitySnapshotStore? store,
  })  : _scopeProvider = scope,
        _store = store;

  final SupportIdentityGateway _gateway;
  final Duration ttl;
  final Future<String?> Function()? _scopeProvider;
  final SupportIdentitySnapshotStore? _store;
  final Map<String, SupportIdentity> _byReference = {};
  final Map<String, DateTime> _fetchedAt = {};
  final Map<String, Completer<void>> _pending = {};
  final Set<String> _queued = {};
  // Keep successful-response watermarks even for revoked/absent identities.
  // Business and Matrix IDs can be queried concurrently before alias discovery.
  final Map<String, int> _referenceVersions = {};
  int _requestSequence = 0;
  Future<void>? _hydrating;
  Future<void> _writes = Future.value();
  String? _scope;
  int _generation = 0;
  bool _disposed = false;

  String? badgeFor(
          {String? userId, String? matrixUserId, String? displayName}) =>
      _byReference[_nonBlank(userId)]?.verifiedBadge ??
      _byReference[_nonBlank(matrixUserId)]?.verifiedBadge;

  Future<void> _hydrate() => _hydrating ??= _load();

  Future<String?> _resolveScope() async {
    try {
      return await _scopeProvider?.call();
    } catch (_) {
      // Badge presentation must not fail a page when secure storage is locked
      // or unavailable. Business requests retain their own auth/error handling.
      return null;
    }
  }

  Future<void> _load() async {
    final generation = _generation;
    final scope = await _resolveScope();
    if (_disposed || generation != _generation) return;
    _scope = scope;
    if (scope == null) {
      // Startup may bind Matrix identity after the first widget mounts.
      // An unavailable namespace is not a completed cache initialization.
      _hydrating = null;
      return;
    }
    if (_store == null) return;
    try {
      await _writes;
      final items = await _store.read(scope);
      if (_disposed || generation != _generation) return;
      for (final item in items) {
        _put(item);
      }
      // Disk snapshots are revalidated on the first access of each launch.
      if (items.isNotEmpty) notifyListeners();
    } catch (_) {/* Cache availability never blocks authoritative lookup. */}
  }

  Future<void> warm(Iterable<String?> references, {bool force = false}) async {
    final generation = _generation;
    await _hydrate();
    if (_disposed || generation != _generation) return;
    if (_scopeProvider != null && _scope == null) return;
    final waiting = <Future<void>>[];
    final now = DateTime.now();
    for (final reference in references) {
      final id = _nonBlank(reference);
      if (id == null) continue;
      final pending = _pending[id];
      if (pending != null) {
        waiting.add(pending.future);
        continue;
      }
      if (!force &&
          _fetchedAt[id] != null &&
          now.difference(_fetchedAt[id]!) < ttl) {
        continue;
      }
      final completion = Completer<void>();
      _pending[id] = completion;
      _queued.add(id);
      waiting.add(completion.future);
    }
    if (_queued.isNotEmpty) scheduleMicrotask(_flush);
    await Future.wait(waiting);
  }

  /// Revalidate visible/previously queried identities once on app foreground.
  /// There is no mobile role-change push contract; this is not instant delivery.
  Future<void> refreshKnown() async {
    final generation = _generation;
    await _hydrate();
    if (_disposed || generation != _generation) return;
    await warm({..._byReference.keys, ..._fetchedAt.keys}, force: true);
  }

  Future<void> _flush() async {
    if (_queued.isEmpty || _disposed) return;
    final ids = _queued.toList();
    _queued.clear();
    final generation = _generation;
    final completions = {for (final id in ids) id: _pending[id]!};
    final sequence = ++_requestSequence;
    try {
      for (var start = 0; start < ids.length; start += 100) {
        final batch = ids.sublist(start, (start + 100).clamp(0, ids.length));
        final items = await _gateway.lookupSupportIdentities(batch);
        if (_disposed || generation != _generation) return;
        final before = _visible();
        final now = DateTime.now();
        final returned = {for (final item in items) ..._references(item)};
        for (final id in batch) {
          if (!returned.contains(id)) _applyResult([id], null, sequence, now);
        }
        for (final item in items) {
          _applyResult(_references(item), item, sequence, now);
        }
        if (!mapEquals(before, _visible())) notifyListeners();
        await _persist();
      }
    } catch (_) {
      // Offline/server errors do not revoke an already verified display badge.
    } finally {
      for (final entry in completions.entries) {
        if (identical(_pending[entry.key], entry.value)) {
          _pending.remove(entry.key);
        }
        if (!entry.value.isCompleted) entry.value.complete();
      }
    }
  }

  void _applyResult(Iterable<String> references, SupportIdentity? item,
      int sequence, DateTime fetchedAt) {
    final aliases = references.toSet();
    // Revocation of any known alias covers the entire previous identity.
    for (final id in references) {
      final previous = _byReference[id];
      if (previous != null) aliases.addAll(_references(previous));
    }
    if (aliases.any((id) => (_referenceVersions[id] ?? 0) > sequence)) {
      return;
    }
    _remove(aliases);
    if (item != null) _put(item);
    for (final id in aliases) {
      _referenceVersions[id] = sequence;
      _fetchedAt[id] = fetchedAt;
    }
  }

  Map<String, String?> _visible() => {
        for (final entry in _byReference.entries)
          entry.key: entry.value.verifiedBadge
      };

  Iterable<String> _references(SupportIdentity item) => <String>{
        item.queryId,
        item.userId,
        if (item.matrixUserId != null) item.matrixUserId!,
      }.where((id) => id.isNotEmpty);

  void _put(SupportIdentity item) {
    // Explicit USER/disabled/missing role removes every previously known alias.
    _remove(_references(item));
    if (item.verifiedBadge == null) return;
    for (final id in _references(item)) {
      _byReference[id] = item;
    }
  }

  void _remove(Iterable<String> ids) {
    final previous = {
      for (final id in ids)
        if (_byReference[id] != null) _byReference[id]!
    };
    _byReference.removeWhere((_, item) => previous.contains(item));
  }

  Future<void> _persist() {
    final scope = _scope;
    if (scope == null || _store == null) return Future.value();
    final items = _byReference.values.toSet().toList();
    _writes = _writes
        .then((_) => _store.write(scope, items))
        .catchError((Object _) {});
    return _writes;
  }

  void clear() {
    if (_disposed) return;
    _generation++;
    final scope = _scope;
    final oldScope = scope != null ? Future.value(scope) : _resolveScope();
    _scope = null;
    _hydrating = null;
    _queued.clear();
    for (final completion in _pending.values) {
      if (!completion.isCompleted) completion.complete();
    }
    _pending.clear();
    _byReference.clear();
    _fetchedAt.clear();
    _referenceVersions.clear();
    if (_store != null) {
      _writes = _writes.then((_) async {
        final previous = await oldScope;
        if (previous != null) await _store.write(previous, const []);
      }).catchError((Object _) {});
    }
    notifyListeners();
  }

  @override
  void dispose() {
    // Pages must not dispose the BusinessApiClient-owned shared repository.
    _generation++;
    _disposed = true;
    for (final completion in _pending.values) {
      if (!completion.isCompleted) completion.complete();
    }
    _pending.clear();
    _queued.clear();
    super.dispose();
  }
}

abstract interface class SupportIdentitySnapshotStore {
  Future<List<SupportIdentity>> read(String scope);
  Future<void> write(String scope, List<SupportIdentity> items);
}

final class PreferencesSupportIdentitySnapshotStore
    implements SupportIdentitySnapshotStore {
  const PreferencesSupportIdentitySnapshotStore();
  String _key(String scope) => 'support.identity.v1.$scope';
  @override
  Future<List<SupportIdentity>> read(String scope) async {
    final raw = (await SharedPreferences.getInstance()).getString(_key(scope));
    if (raw == null) return const [];
    return (jsonDecode(raw) as List)
        .map((item) =>
            SupportIdentity.fromJson((item as Map).cast<String, dynamic>()))
        .toList();
  }

  @override
  Future<void> write(String scope, List<SupportIdentity> items) async {
    final prefs = await SharedPreferences.getInstance();
    if (items.isEmpty) {
      await prefs.remove(_key(scope));
      return;
    }
    await prefs.setString(
        _key(scope),
        jsonEncode(items
            .map((item) => {
                  'query_id': item.queryId,
                  'user_id': item.userId,
                  'matrix_user_id': item.matrixUserId,
                  'badge': item.badge,
                  'role': item.role.wireValue,
                })
            .toList()));
  }
}

String? _nonBlank(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
