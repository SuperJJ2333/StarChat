# Figma 原始 Chat 与好友页一致性修复验证

**日期：** 2026-08-17  
**Figma：** `zpzwTbnj1hqx80tyRygX78`  
**模拟器：** `emulator-5554`（雷电模拟器）  
**Android 包：** `com.liuhetong.mobile`

## 修复结果

- Chat 浅色背景继续使用 Figma Token `#EDEDED`，导航与输入表面分别使用 `#F7F7F7`、`#FFFFFF`。
- Chat 和好友资料改由 root Navigator 打开，详情页不再残留首页 TabBar。
- 更多面板使用四列、`mainAxisExtent = 82` 的确定网格；393px 和 1.3 倍文字缩放 Widget 测试无 overflow。
- EmojiPicker 底部 ActionBar 已关闭，搜索和退格/删除按钮均不存在。
- 好友资料映射 `35:63`：126px 身份卡、72px 头像、在线状态、朋友圈三预览和三个纵向 48px 按钮。
- 雷电模拟器实际逻辑宽度低于 393px，首次冒烟捕获到朋友圈右侧 33px overflow；新增 360px 回归红灯后改为受限响应式宽度，最终截图无 overflow。

## Figma 节点

| 状态 | Node ID |
|---|---|
| 正式聊天交互画廊 | `107:3` |
| 更多面板 | `110:60` |
| Emoji 最近 | `110:143` |
| Emoji 全部 | `110:198` |
| Emoji 我的表情 | `110:261` |
| 普通文本消息菜单 | `111:2` |
| 图片/GIF 消息菜单 | `118:2` |
| 权威好友资料 | `35:63` |

原推测版好友 Section `107:9` 已删除，避免与权威节点 `35:63` 并存。Figma 注册信息已写入 `design-demo/artifacts/figma-state.json`。

## TDD 证据

红灯分别出现：

- 更多面板 `mainAxisExtent` 为 `null` 且缺少 `chat-more-panel` key；
- Emoji `bottomActionBarConfig.enabled` 实际为 `true`；
- 好友页缺少原始节点尺寸 key；
- Tab 内好友详情仍能找到 `CupertinoTabBar`；
- 360px 视口报 `A RenderFlex overflowed by 33 pixels on the right`。

绿灯：`contact_flow_test.dart` 4/4，通过原始尺寸、root route 和窄屏无溢出断言；Chat/Emoji/More 目标集合 10/10 通过。

## 自动验证

- `dart format --output=none --set-exit-if-changed lib test`：131 files，0 changed。
- `flutter analyze`：No issues found。
- `flutter test`：167 tests passed。
- `scripts/verify.ps1`：PASS；Matrix Bot 9 passed；Business API/Worker 161 passed、1 skipped；Flutter boundary 19 passed；OpenAPI、迁移与 Compose 检查通过。
- `flutter build apk --debug`：成功。构建输出包含 Flutter 对部分第三方插件未来 Built-in Kotlin 迁移的提示；本次未变更这些已锁定依赖，当前构建与运行不受影响。

## APK 与模拟器

- APK：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk`
- SHA-256：`C1EDE0827C592DB39CBDD870C72D24E4A5E5D24E1D08E11B0C3713EDAD9FD99B`
- 安装：`adb -s emulator-5554 install -r -d ...` → `Success`
- 启动进程 PID：`18459`
- Chat UIAutomator：`HAS_HOME_TABS=False`
- Emoji UIAutomator：`HAS_SEARCH=False`、`HAS_BACKSPACE=False`
- 好友资料 UIAutomator：`HAS_HOME_TABS=False`

## 视觉证据

- `docs/verification/artifacts/figma-chat-gallery.png`
- `docs/verification/artifacts/figma-chat-more.png`
- `docs/verification/artifacts/figma-chat-emoji.png`
- `docs/verification/artifacts/figma-message-text-menu.png`
- `docs/verification/artifacts/figma-message-image-menu.png`
- `docs/verification/artifacts/figma-friend-original.png`
- `docs/verification/artifacts/emulator-chat-more.png`
- `docs/verification/artifacts/emulator-chat-emoji.png`
- `docs/verification/artifacts/emulator-friend-profile-final.png`

## 规格与质量复核

- 原始节点优先级、色彩 Token、393px 基准、面板状态、好友纵向布局全部有代码或截图证据。
- 未修改 Matrix E2EE、业务 API、账本、红包权威状态或内部标识。
- 未引入新依赖、密钥、Token、真实聊天正文日志或跨模块数据库写入。
