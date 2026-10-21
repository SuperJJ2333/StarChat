import 'package:flutter/widgets.dart';

/// A reversed timeline follows a newly added outgoing bubble after layout.
/// A receipt updating the same stable key never steals the user's scroll.
final class LatestMessageAnchor {
  LatestMessageAnchor(this.controller);
  final ScrollController controller;
  String? _latest;
  int _generation = 0;
  bool _disposed = false;

  void update(String? stableId,
      {required bool outgoing, bool newSend = false}) {
    if (!newSend || !outgoing || stableId == null) return;
    final changed = _latest != stableId;
    _latest = stableId;
    if (!changed) return;
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || generation != _generation || !controller.hasClients) {
        return;
      }
      controller.jumpTo(controller.position.minScrollExtent);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// A gesture supersedes an earlier send's pending layout correction.
  void cancelPending() => _generation++;

  void dispose() => _disposed = true;
}
