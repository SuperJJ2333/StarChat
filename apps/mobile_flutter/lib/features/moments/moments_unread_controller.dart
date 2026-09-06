import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Counts new visible posts, independently of likes/comments. No post bodies
/// are stored. A successful display consumes only its own IDs.
final class MomentsUnreadController extends ChangeNotifier {
  MomentsUnreadController(
      {required this.accountKey,
      required this.load,
      required this.preferences});
  final String accountKey;
  final Future<Map<String, dynamic>> Function({String? since, String? cursor})
      load;
  final SharedPreferences preferences;
  String get _key =>
      'moments.unread.v1.${base64UrlEncode(utf8.encode(accountKey))}';
  String? _since;
  String? _snapshot;
  final Set<String> _viewed = {};
  Set<String> _pending = {};
  bool _disposed = false;
  Future<void>? _refreshing;
  int get count => _pending.length;

  Future<void> initialize() async {
    if (accountKey.isEmpty) return;
    try {
      final raw = preferences.getString(_key);
      if (raw != null) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        _since = json['since'] as String?;
        _viewed.addAll(List<String>.from(json['viewed'] ?? const []));
        _pending = Set<String>.from(json['pending'] ?? const []);
        if (!_disposed) notifyListeners();
      }
    } catch (_) {
      /* A corrupt account snapshot is treated as a fresh baseline. */
    }
    await refresh();
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    if (accountKey.isEmpty || _disposed) return;
    try {
      final pending = <String>{};
      final scanned = <String>{};
      String? cursor;
      String? snapshot;
      final cursors = <String>{};
      do {
        final response = await load(since: _since, cursor: cursor);
        if (_disposed) return;
        snapshot ??= response['server_time'] as String;
        for (final item in (response['items'] as List? ?? const [])) {
          final id = (item as Map)['id'] as String;
          scanned.add(id);
          if (!_viewed.contains(id)) pending.add(id);
        }
        cursor = response['next_cursor'] as String?;
        if (cursor != null && !cursors.add(cursor)) {
          throw const FormatException('repeated cursor');
        }
      } while (cursor != null);
      _snapshot = snapshot;
      _since ??= snapshot;
      _viewed.retainAll(scanned);
      // An item may have become visible while a later page was in flight.
      _pending = pending.difference(_viewed);
      _compact();
      await _save();
      if (!_disposed) notifyListeners();
    } catch (_) {/* Offline/failed scans preserve the previous badge. */}
  }

  Future<void> markDisplayed(Iterable<String> ids) async {
    if (_disposed || _since == null) return;
    final newlyViewed = ids
        .where((id) =>
            !_viewed.contains(id) &&
            (_pending.contains(id) || _refreshing != null))
        .toSet();
    if (newlyViewed.isEmpty) return;
    _viewed.addAll(newlyViewed);
    _pending.removeAll(newlyViewed);
    // Do not advance the boundary during a scan: concurrent newer arrivals
    // must not be consumed by displaying an older cached feed.
    if (_refreshing == null) _compact();
    await _save();
    if (!_disposed) notifyListeners();
  }

  void _compact() {
    if (_pending.isEmpty && _snapshot != null) {
      _since = _snapshot;
      // Keep IDs at the inclusive timestamp boundary until the next scan.
      // They are small metadata only and never contain post text or images.
    }
  }

  Future<void> _save() => preferences.setString(
      _key,
      jsonEncode({
        'since': _since,
        'viewed': _viewed.toList(),
        'pending': _pending.toList(),
      }));

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
