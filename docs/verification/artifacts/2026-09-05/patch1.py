from pathlib import Path

root = Path('.')

# ── #1 策略引擎：当前会话抑制仅限前台 ──────────────────────────────
p = root / 'apps/mobile_flutter/lib/core/notification/notification_policy_engine.dart'
raw = p.read_text(encoding='utf-8')
old = """  // PRD §18/§53：当前正在查看的会话不产生提醒（已读回执由聊天页推进）。
  if (context.isCurrentConversation) return const NotificationDecision();"""
new = """  // PRD §18/§53：前台正在查看的会话不产生提醒（已读回执由聊天页推进）。
  // 后台修复：退后台后聊天页仍挂载（未 dispose），isRoomOpen 残留 true——
  // 后台必须照常系统通知（微信语义：后台一律提醒，仅静音例外）。
  if (context.isCurrentConversation && context.appForeground) {
    return const NotificationDecision();
  }"""
assert old in raw, 'policy old not found'
p.write_text(raw.replace(old, new), encoding='utf-8', newline='')
print('policy OK')
