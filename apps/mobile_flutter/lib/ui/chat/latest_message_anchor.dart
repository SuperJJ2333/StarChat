import 'package:flutter/widgets.dart';

/// A reversed timeline follows a newly added outgoing bubble after layout.
/// A receipt updating the same stable key never steals the user's scroll.
final class LatestMessageAnchor {
  LatestMessageAnchor(this.controller);
  final ScrollController controller;
  String? _latest;
  bool _scheduled = false;
  bool _disposed = false;

  void update(String? stableId, {required bool outgoing}) {
    final changed = _latest != stableId;
    _latest = stableId;
    if (!changed || !outgoing || stableId == null || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (_disposed || !controller.hasClients) return;
      controller.jumpTo(controller.position.minScrollExtent);
    });
  }

  void dispose() => _disposed = true;
}
