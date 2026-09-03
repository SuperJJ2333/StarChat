import 'package:flutter/foundation.dart';

/// 应用内顶部横幅条目（PRD §7）。
final class InAppBannerItem {
  const InAppBannerItem({
    required this.id,
    required this.conversationId,
    required this.title,
    required this.body,
    required this.timestamp,
    this.avatarUrl,
  });

  final String id;
  final String conversationId;
  final String title;
  final String body;

  /// Matrix mxc:// 头像地址（未缓存时 UI 先用占位头像，PRD §23/§48）。
  final String? avatarUrl;
  final DateTime timestamp;
}

/// 应用内横幅队列（PRD §7/§15）。
///
/// 一次只展示一条，停留时长由 UI 层控制（默认 3 秒）后调用
/// [dismissCurrent]；同一会话的新横幅原地替换，风暴时最多排队 3 条。
final class InAppBannerController extends ChangeNotifier {
  static const maxQueueLength = 3;

  InAppBannerItem? _current;
  final List<InAppBannerItem> _queue = [];

  InAppBannerItem? get current => _current;

  int get queueLength => _queue.length;

  void present(InAppBannerItem item) {
    if (_current == null) {
      _current = item;
      notifyListeners();
      return;
    }
    if (_current!.conversationId == item.conversationId) {
      _current = item;
      notifyListeners();
      return;
    }
    final existingIndex = _queue.indexWhere(
      (queued) => queued.conversationId == item.conversationId,
    );
    if (existingIndex >= 0) {
      _queue[existingIndex] = item;
    } else {
      if (_queue.length >= maxQueueLength) {
        _queue.removeAt(0);
      }
      _queue.add(item);
    }
    notifyListeners();
  }

  void dismissCurrent() {
    if (_queue.isEmpty) {
      if (_current == null) return;
      _current = null;
    } else {
      _current = _queue.removeAt(0);
    }
    notifyListeners();
  }

  void clear() {
    _current = null;
    _queue.clear();
    notifyListeners();
  }
}
