/// 钱包页纯展示格式化（不含业务语义、不触网、不改金额）。
///
/// 规范见 `UI_DESIGN.md` §20：钱包里的 TRON 地址在**展示**时一律压缩到固定
/// 可视宽度（首 8 位 + 中段省略号 + 末 6 位），因此地址列不会因为不同长度的
/// 截断把复制 icon 挤到不同位置，文字始终靠左对齐；复制动作仍使用**完整**地址。
library;

/// 地址展示压缩：首 [head] 位 + 省略号 + 末 [tail] 位。
///
/// 长度不足以压缩时原样返回（绝不能为了压缩而丢信息一致性地截断中间段之外
/// 的内容）。仅用于展示；任何复制、校验、提交都必须使用完整值。
String compactWalletAddress(String value, {int head = 8, int tail = 6}) {
  if (head < 1 || tail < 1) {
    throw ArgumentError('地址压缩必须保留首尾可见位');
  }
  if (value.length <= head + tail + 1) return value;
  return '${value.substring(0, head)}…${value.substring(value.length - tail)}';
}

/// 订单/校验码展示压缩：首 10 位 + 省略号 + 末 8 位（字号更小、可复制完整值）。
String compactWalletCode(String value, {int head = 10, int tail = 8}) =>
    compactWalletAddress(value, head: head, tail: tail);
