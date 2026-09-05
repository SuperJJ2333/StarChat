from pathlib import Path

root = Path('apps/mobile_flutter')

# ── A) NotificationEvent：头像/未读字段 ─────────────────────────────
p = root / 'lib/core/notification/notification_event.dart'
raw = p.read_text(encoding='utf-8')
if 'avatarUrl' not in raw:
    raw = raw.replace(
        "  final bool isMention;",
        "  final bool isMention;\n\n"
        "  /// 发送者头像（业务头像 URL；系统通知大图标，缺省占位）。\n"
        "  final String? avatarUrl;\n\n"
        "  /// 该会话当前未读数（含本条；系统通知 number 角标）。\n"
        "  final int? unreadCount;",
        1)
    raw = raw.replace(
        "    this.isMention = false,",
        "    this.isMention = false,\n    this.avatarUrl,\n    this.unreadCount,",
        1)
    p.write_text(raw, encoding='utf-8', newline='')
print('A event OK')
