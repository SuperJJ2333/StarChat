import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// 视频封面加载诊断（脱敏、**白名单字段**）。
///
/// 允许记录（仅这些）：
/// `id`（媒体标识的加盐哈希前 12 位）、`source`、`cache_hit`、
/// `generate_ms`、`decode_ms`、`download_bytes`。
///
/// **禁止**记录：视频内容/字节、媒体原始 ID、房间 ID、用户 ID、
/// access token、房间密钥、任何明文或可反查的身份信息。
///
/// 失败安全：日志回调抛异常绝不影响媒体加载（诊断永远不能让封面加载失败）。
final class VideoPosterDiagnostics {
  VideoPosterDiagnostics({
    ValueChanged<String>? log,
    this.salt = '',
    this.enabled = true,
  }) : _log = log ?? _defaultLog;

  /// 默认出口：`debugPrint`（真机 logcat 可见）。
  static void _defaultLog(String line) => debugPrint(line);

  /// 盐：只影响哈希，不参与任何业务逻辑。
  final String salt;
  final bool enabled;
  final ValueChanged<String> _log;

  /// 最近一次记录的字段（测试/证据用）。
  Map<String, Object?>? lastRecord;

  /// 固定键顺序（与字段白名单一一对应，顺序稳定便于 grep）。
  static const fieldOrder = <String>[
    'id',
    'source',
    'cache_hit',
    'generate_ms',
    'decode_ms',
    'download_bytes',
  ];

  /// 媒体标识 → 不可反查、不可跨账号关联的短指纹。
  static String fingerprint(String value, {String salt = ''}) {
    if (value.isEmpty) return 'none';
    final digest = sha256.convert(utf8.encode('$salt|$value')).toString();
    return digest.substring(0, 12);
  }

  void record({
    required String videoId,
    required String source,
    required bool cacheHit,
    required int generateMs,
    required int decodeMs,
    required int downloadBytes,
  }) {
    final values = <String, Object?>{
      'id': fingerprint(videoId, salt: salt),
      'source': source,
      'cache_hit': cacheHit,
      'generate_ms': generateMs,
      'decode_ms': decodeMs,
      'download_bytes': downloadBytes,
    };
    lastRecord = values;
    if (!enabled) return;
    final line = '[chatflow/videoposter] '
        '${fieldOrder.map((key) => '$key=${values[key]}').join(' ')}';
    try {
      _log(line);
    } catch (_) {
      // 诊断失败必须静默：绝不让日志问题影响封面加载。
    }
  }
}
