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
        SupportRole.supportSupervisor => true,
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

/// In-memory, account-scoped caller-owned projection of the authoritative
/// support lookup endpoint. No identity data is persisted. A failed or newer
/// request clears queried values before it starts, which keeps presentation
/// conservative during revocation, account changes, and offline errors.
final class SupportIdentityRepository extends ChangeNotifier {
  SupportIdentityRepository(this._gateway,
      {this.ttl = const Duration(seconds: 30)});

  final SupportIdentityGateway _gateway;
  final Duration ttl;
  final Map<String, _CachedSupportIdentity> _byReference = {};
  final Map<String, DateTime> _fetchedAt = {};
  int _generation = 0;
  bool _disposed = false;

  String? badgeFor({String? userId, String? matrixUserId, String? displayName}) {
    // displayName intentionally has no lookup path: names received from Matrix
    // are presentation data and cannot be evidence of a business role.
    final id = _nonBlank(userId);
    final matrix = _nonBlank(matrixUserId);
    String? forReference(String? reference) {
      final cached = _byReference[reference];
      if (cached == null || !DateTime.now().isBefore(cached.expiresAt)) {
        return null;
      }
      return cached.identity.verifiedBadge;
    }

    return forReference(id) ?? forReference(matrix);
  }

  Future<void> warm(Iterable<String?> references, {bool force = false}) async {
    if (_disposed) return;
    final ids = <String>[];
    final seen = <String>{};
    for (final reference in references) {
      final value = _nonBlank(reference);
      if (value != null && seen.add(value)) ids.add(value);
    }
    if (ids.isEmpty) return;
    final now = DateTime.now();
    final needed = force
        ? ids
        : ids
            .where((id) =>
                _fetchedAt[id] == null || now.difference(_fetchedAt[id]!) >= ttl)
            .toList(growable: false);
    if (needed.isEmpty) return;

    final generation = ++_generation;
    _clear(needed);
    _notify();
    try {
      final items = <SupportIdentity>[];
      for (var start = 0; start < needed.length; start += 100) {
        final end = (start + 100).clamp(0, needed.length);
        items.addAll(await _gateway.lookupSupportIdentities(
            needed.sublist(start, end)));
        if (_disposed || generation != _generation) return;
      }
      if (_disposed || generation != _generation) return;
      final fetched = DateTime.now();
      for (final item in items) {
        final badge = item.verifiedBadge;
        if (badge == null) continue;
        final references = <String>{
          item.queryId,
          item.userId,
          if (item.matrixUserId != null) item.matrixUserId!,
        };
        final cached = _CachedSupportIdentity(item, fetched.add(ttl));
        for (final reference in references) {
          if (reference.isNotEmpty) _byReference[reference] = cached;
        }
      }
      for (final id in needed) {
        _fetchedAt[id] = fetched;
      }
      _notify();
    } catch (_) {
      // Query references were removed before the request. Leave them empty.
      if (!_disposed && generation == _generation) _notify();
    }
  }

  void clear() {
    if (_disposed) return;
    _generation++;
    _byReference.clear();
    _fetchedAt.clear();
    _notify();
  }

  void _clear(Iterable<String> ids) {
    final stale = <_CachedSupportIdentity>{
      for (final id in ids)
        if (_byReference[id] != null) _byReference[id]!,
    };
    if (stale.isNotEmpty) {
      _byReference.removeWhere((_, cached) => stale.contains(cached));
    }
    for (final id in ids) {
      _fetchedAt.remove(id);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _byReference.clear();
    _fetchedAt.clear();
    super.dispose();
  }
}

final class _CachedSupportIdentity {
  const _CachedSupportIdentity(this.identity, this.expiresAt);
  final SupportIdentity identity;
  final DateTime expiresAt;
}

String? _nonBlank(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
