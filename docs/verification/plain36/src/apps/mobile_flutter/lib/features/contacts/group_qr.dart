/// 群聊二维码的载荷编解码（纯逻辑，可测）。
///
/// 载荷形如 `changliao://g/<安全邀请令牌>`：
/// - 令牌由服务端随机签发（sha256 存储、默认 7 天过期、可撤销），
///   绝不是 Matrix 房间 ID（房间 ID 不可作为无限期入群凭证）；
/// - 与好友码 `changliao://u/<username>` 共用 scheme，扫码统一分流；
/// - 令牌为 URL-safe 随机串（>= 16 字符），载荷不含任何凭据。
const groupQrSchemePrefix = 'changliao://g/';

String buildGroupQrPayload(String token) =>
    '$groupQrSchemePrefix$token';

/// 解析群二维码；合法返回令牌，非法返回 null（与好友码互斥分流）。
String? parseGroupQrPayload(String raw) {
  final text = raw.trim();
  if (!text.startsWith(groupQrSchemePrefix)) return null;
  final token = text.substring(groupQrSchemePrefix.length);
  // 服务端 token_urlsafe(32)：字母数字 - _，长度 >= 16 防短伪造。
  return RegExp(r'^[A-Za-z0-9_-]{16,128}$').firstMatch(token) == null
      ? null
      : token;
}
