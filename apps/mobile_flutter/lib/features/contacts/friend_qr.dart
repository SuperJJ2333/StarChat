/// 好友二维码的载荷编解码（纯逻辑，可测）。
///
/// 载荷形如 `changliao://u/<畅聊号>`——微信式自定义 scheme：
/// - 本应用「扫一扫」识别后跳转「申请添加朋友」页；
/// - 畅聊号字符集与注册规则一致（字母开头，3-64 位字母/数字/_/-），
///   解析时据此拒绝任意 URL/文本，避免把无关二维码当好友码。
const friendQrSchemePrefix = 'changliao://u/';

String buildFriendQrPayload(String username) =>
    '$friendQrSchemePrefix${username.trim()}';

/// 解析好友二维码原始内容；合法时返回畅聊号，非法返回 null。
String? parseFriendQrPayload(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final candidate = text.startsWith(friendQrSchemePrefix)
      ? text.substring(friendQrSchemePrefix.length)
      : text;
  if (text.contains('://') && !text.startsWith(friendQrSchemePrefix)) {
    // 其它 scheme/URL（网页链接等）不是好友码。
    return null;
  }
  return RegExp(r'^[A-Za-z][A-Za-z0-9_-]{2,63}$').firstMatch(candidate) == null
      ? null
      : candidate;
}
