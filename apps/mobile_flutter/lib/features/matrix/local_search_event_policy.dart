import 'dart:collection';

import 'package:matrix/matrix.dart';

enum LocalSearchEventEffect { none, append, invalidate }

/// Classifies Matrix room updates for an in-progress local search. Ordinary
/// heads can wait for user refresh; withdrawals and changes to old plaintext
/// must revoke the visible results immediately.
final class LocalSearchEventPolicy {
  final Queue<String> _recentOrder = Queue<String>();
  final Set<String> _recentIds = <String>{};

  LocalSearchEventEffect classify(EventUpdate update) {
    switch (update.type) {
      case EventUpdateType.ephemeral:
      case EventUpdateType.accountData:
      case EventUpdateType.state:
      case EventUpdateType.inviteState:
        return LocalSearchEventEffect.none;
      case EventUpdateType.history:
        return LocalSearchEventEffect.invalidate;
      case EventUpdateType.timeline:
      case EventUpdateType.decryptedTimelineQueue:
        break;
    }
    final event = update.content;
    final id = event['event_id'];
    if (id is! String || id.isEmpty || _isSecurityChange(event)) {
      return LocalSearchEventEffect.invalidate;
    }
    if (update.type == EventUpdateType.decryptedTimelineQueue) {
      return _recentIds.contains(id)
          ? LocalSearchEventEffect.append
          : LocalSearchEventEffect.invalidate;
    }
    if (!_recentIds.add(id)) return LocalSearchEventEffect.invalidate;
    _recentOrder.addLast(id);
    while (_recentOrder.length > 4096) {
      _recentIds.remove(_recentOrder.removeFirst());
    }
    return LocalSearchEventEffect.append;
  }

  static bool _isSecurityChange(Map<String, dynamic> event) {
    if (event['type'] == 'm.room.redaction' || event['redacts'] != null) {
      return true;
    }
    final topRelation = event['m.relates_to'];
    if (topRelation is Map && topRelation['rel_type'] == 'm.replace') {
      return true;
    }
    final content = event['content'];
    if (content is! Map) return false;
    if (content['redacts'] != null) return true;
    final relation = content['m.relates_to'];
    return relation is Map && relation['rel_type'] == 'm.replace';
  }

  void clear() {
    _recentOrder.clear();
    _recentIds.clear();
  }
}
