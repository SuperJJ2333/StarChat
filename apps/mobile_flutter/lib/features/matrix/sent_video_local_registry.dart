import 'dart:io';

import 'package:flutter/foundation.dart';

/// 发送端本地视频回读登记：发送成功后点击自己的视频消息优先读取
/// 本机压缩产物，避免弱网下从服务器回下载大文件超时失败。
/// 按 txid 前缀匹配（`outgoing-jobId-0-target` 与 jobId 对应），
/// 容量上限防泄漏；仅保留文件引用，不复制字节。
final class SentVideoLocalRegistry {
  SentVideoLocalRegistry._();

  static final SentVideoLocalRegistry shared = SentVideoLocalRegistry._();

  static const _maxEntries = 32;
  final _entries = <String, File>{}; // jobId -> local compressed file
  final _order = <String>[];

  void register({required String jobId, required File file}) {
    if (jobId.isEmpty || !file.existsSync()) return;
    if (_entries.containsKey(jobId)) return;
    _entries[jobId] = file;
    _order.add(jobId);
    while (_order.length > _maxEntries) {
      _entries.remove(_order.removeAt(0));
    }
    assert(() {
      debugPrint('[SentVideoLocal] registered job=$jobId size=${file.lengthSync()}');
      return true;
    }());
  }

  /// [transactionId] 为消息 VM 的 transactionId（`outgoing-jobId-0-n`）。
  File? findByTransactionId(String? transactionId) {
    if (transactionId == null) return null;
    final marker = 'outgoing-';
    if (!transactionId.startsWith(marker)) return null;
    // 'outgoing-<jobId>-0-<n>' → jobId 部分去掉首尾两段。
    final body = transactionId.substring(marker.length);
    final lastDash = body.lastIndexOf('-');
    if (lastDash <= 0) return null;
    final withoutTarget = body.substring(0, lastDash);
    final secondLast = withoutTarget.lastIndexOf('-');
    if (secondLast <= 0) return null;
    final jobId = withoutTarget.substring(0, secondLast);
    final file = _entries[jobId];
    if (file == null) return null;
    return file.existsSync() ? file : null;
  }
}
