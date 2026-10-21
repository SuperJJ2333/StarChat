import 'package:flutter/widgets.dart';

/// A reversed timeline follows a newly added outgoing bubble after layout.
/// A receipt updating the same stable key never steals the user's scroll.
final class LatestMessageAnchor {
  LatestMessageAnchor(this.controller) {
    controller.addListener(_onPositionChanged);
  }
  final ScrollController controller;
  String? _latest;
  int _generation = 0;
  bool _disposed = false;
  bool _followingLatest = false;
  bool get followingLatest => !_disposed && _followingLatest;

  void _onPositionChanged() {
    if (controller.hasClients &&
        controller.position.hasContentDimensions &&
        controller.position.extentBefore > .5) {
      cancelPending();
    }
  }

  void update(String? stableId,
      {required bool outgoing, bool newSend = false}) {
    if (!newSend || !outgoing || stableId == null) return;
    final changed = _latest != stableId;
    _latest = stableId;
    if (!changed) return;
    final generation = ++_generation;
    _followingLatest = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || generation != _generation || !controller.hasClients) {
        return;
      }
      controller.jumpTo(controller.position.minScrollExtent);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// A gesture supersedes an earlier send's pending layout correction.
  void cancelPending() {
    _generation++;
    _followingLatest = false;
  }

  void dispose() {
    _disposed = true;
    controller.removeListener(_onPositionChanged);
  }
}
