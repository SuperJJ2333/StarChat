# 六合通 Flutter 组件

所有业务页面必须使用 `lib/ui/` 中的公开组件，并从 `WeChatColors`、`WeChatSpacing`、`WeChatRadius` 和 `WeChatTypography` 获取视觉值。

## 基础组件

- `WeChatPrimaryButton`：主操作、禁用和加载态。
- `WeChatPageScaffold`：统一导航栏、安全区和页面结构。
- `WeChatListTile`：56dp 最小高度的列表单元。

## 聊天组件

- `WeChatMessageBubble`：进出方向和发送中/失败/重试。
- `WeChatTimestamp`：时间分组标签。
- `WeChatUnreadBadge`：未读数，超过 99 显示 `99+`。
- `WeChatVoiceBubble`：1–60 秒宽度、播放状态。
- `WeChatAttachmentTile`：文件名、进度和重试。

## 金融组件

- `WeChatRedPacketCard`：可领取、已领取、已领完、已过期和已撤回。
- `WeChatStatusChip`：处理、成功和失败，始终同时显示图标与文字。

业务组件不得通过客户端展示状态改变红包、账本或钱包权威结果。
