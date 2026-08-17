# 通讯录、Composer 与群聊信息验证证据

**日期：** 2026-08-18  
**规格：** `docs/superpowers/specs/2026-08-18-contacts-composer-group-info-design.md`

## Test-first 红灯证据

- 通讯录：`contacts index follows the list surface during pull down` 初次失败，索引顶部实际仍为 `44.0`，未随联系人分组下移。
- Composer：纯状态测试初次得到 `showsSend == false`；Widget 测试找不到 `composer-send-surface`；无焦点 Emoji 仍显示 `composer-more`。
- 群聊创建：测试初次因缺少 `currentUserDisplayName` 参数编译失败，旧服务仍接受一名受邀好友。
- 群聊信息：测试初次因 `group_chat_info_controller.dart` 与 `group_chat_info_page.dart` 不存在而失败；成员选择和本地历史搜索也分别先以缺少类型失败。

以上测试均在生产代码修改前运行并观察到与缺失功能一致的失败。

## Flutter 绿灯证据

- Focused tests：通讯录、Composer、群聊创建、群聊信息共 `19 passed`。
- 全量 `flutter test`：`176 tests passed`。
- `flutter analyze`：`No issues found!`。
- `dart format --output=none --set-exit-if-changed lib test`：134 files，0 changed。

## Figma 证据

文件：[`zpzwTbnj1hqx80tyRygX78`](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78)

| Frame | Node ID |
| --- | --- |
| `chat-room-group-default` | `139:2` |
| `group-chat-info-default` | `139:55` |
| `group-chat-info-expanded` | `139:145` |
| `group-chat-member-picker` | `139:232` |
| `group-chat-name-edit` | `139:315` |
| `group-chat-announcement-edit` | `139:337` |
| `group-chat-history-search` | `139:359` |

- 七个 Frame 均精确为 `393 × 852`，节点审计 overflow 列表为空。
- 正文统一 `Noto Sans SC`，真实图标统一 `Material Symbols Rounded`。
- 视觉总览：`docs/verification/artifacts/group-info/figma-contact-sheet.png`。

## 仓库与 APK

- `pwsh -NoProfile -File scripts/verify.ps1`：`Verification: PASS`。
  - Matrix Bot：9 passed
  - Business API / Worker：161 passed，1 skipped
  - Flutter boundary：19 passed
- APK：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk`（241,935,159 bytes）
- 雷电模拟器：`emulator-5554`，`adb install -r` 返回 `Success`。
- 包名：`com.liuhetong.mobile`，`lastUpdateTime=2026-08-18 06:30:57`。
- 安装运行截图：`docs/verification/artifacts/group-info/emulator-installed.png`。

## 规格与质量复审

- 通讯录只修复内容和索引共同回弹，不改变 `★ / A-Z / #` 数据规则。
- 群聊至少由当前用户加两位受邀好友组成；房间仍为 private、non-direct、E2EE。
- 群名称与公告写入 `m.room.name` / `m.room.topic`；个人房间偏好写入 Matrix 房间级账号数据。
- 清空记录只写本设备本地隐藏集合，不发送 Matrix redaction。
- 历史搜索只处理当前设备已解密时间线，不向业务服务上传正文。
