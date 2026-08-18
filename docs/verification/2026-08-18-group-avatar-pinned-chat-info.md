# 群头像、置顶群组与聊天信息验证证据

日期：2026-08-18

## 测试先行证据

- `group_avatar_mosaic_test.dart` 首次运行因 `group_avatar_mosaic.dart` 不存在而失败；实现 1–9 人固定行表后通过。
- `conversation_preferences_test.dart` 首次运行因偏好模型和稳定排序不存在而失败；实现账号数据编解码与排序后通过。
- `mute_exception_policy_test.dart` 首次运行因免打扰判断策略不存在而失败；实现纯本地判断后通过。
- `chat_history_search_test.dart` 首次运行因本地分类索引不存在而失败；实现关键字、媒体、文件、链接、日期和发送者过滤后通过。
- `direct_chat_info_test.dart` 首次运行因私聊信息页不存在而失败；实现统一信息入口后通过。
- `group_chat_info_test.dart` 新增免打扰子项测试先观察到 `折叠该聊天` 缺失，再实现批准的嵌套页面。

专项测试（头像布局、会话偏好、免打扰、搜索及私聊信息页）：全部通过。

## Flutter 验证

- `dart format lib test`：144 files，格式稳定。
- `flutter analyze`：`No issues found!`。
- `flutter test`：188 tests passed。

## Figma 证据

文件：[`zpzwTbnj1hqx80tyRygX78`](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78)

| Frame | Node ID |
| --- | --- |
| `group-avatar-mosaic-spec` | `146:2` |
| `messages-pinned-groups` | `146:79` |
| `chat-room-direct-info-nav` | `146:134` |
| `group-chat-info-muted-on` | `146:156` |
| `group-mute-exceptions` | `146:220` |
| `followed-group-members-max4` | `146:252` |
| `direct-chat-info` | `146:307` |
| `chat-history-search-group` | `146:353` |
| `chat-history-media-results` | `146:389` |
| `chat-history-member-filter` | `146:416` |

- 10 个 Frame 均精确为 `393 × 852`。
- 字体仅使用 `Noto Sans SC` 和 `Material Symbols Rounded`。
- 10 个 Frame 的递归 overflow 审计均为 0。
- 视觉总览：`docs/verification/artifacts/group-chat-v2/figma-contact-sheet.png`。

## 仓库验证

`pwsh -NoProfile -File scripts/verify.ps1`：`Verification: PASS`。

- Matrix Bot：9 passed。
- Business API / Worker：161 passed，1 skipped。
- Flutter boundary：19 passed。
- migrations、OpenAPI、Docker Compose 和 repository policy 均通过。

## APK 与雷电模拟器

- APK：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk`。
- 大小：241,975,891 bytes。
- 安装目标：`emulator-5554`。
- `adb install -r`：`Success`。
- 包名：`com.liuhetong.mobile`。
- 版本：`0.1.0` / versionCode 1。
- `lastUpdateTime=2026-08-18 09:03:06`。
- 消息页运行截图：`docs/verification/artifacts/group-chat-v2/emulator-installed.png`。
- 群聊信息截图：`docs/verification/artifacts/group-chat-v2/emulator-group-info.png`。
- 免打扰展开截图：`docs/verification/artifacts/group-chat-v2/emulator-muted.png`。

## 边界复核

- 群头像只使用 Matrix 当前加入成员，并在设备端组合，不上传组合图或成员明文。
- 置顶、折叠和免打扰设置写入 Matrix per-room account data，同账号设备可同步。
- 搜索只遍历当前设备已经解密的时间线，不调用业务 API 或远端明文搜索。
- 清空聊天记录仍只写本机隐藏集合，不发送 Matrix redaction。
- 通话功能仍位于输入区更多面板，只移除聊天导航栏的语音/视频快捷图标。
