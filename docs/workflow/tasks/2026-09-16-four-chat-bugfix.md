# 任务记录：四个聊天缺陷修复（朋友圈评论相册 / 群聊转账 / 专属红包 / 私聊转账）

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-16 报障四项并要求修复；随后要求「推送 debug 版
  给我测试检验」，并在被问及打包范围时明确选择「全部一起打进去」。边界：不改业务 API、
  不改 Matrix 服务端、不改钱包/账本；不构建 iOS；不做生产发布。
- 关联计划/ADR：无独立计划或 ADR（四项均为缺陷修复，未触碰受保护变更）。
  验证记录 [2026-09-16-four-chat-bugfix](../../verification/2026-09-16-four-chat-bugfix.md)；
  交付记录 [2026-09-16-four-bugfix-2123-mi6](../../verification/2026-09-16-four-bugfix-2123-mi6.md)。
- 当前状态：实现与本地验证完成；已构建并安装 Mi 6 debug 包；**待用户真机验收**
- 负责人、工作树、文件所有权、源码commit：主工作树；基线 `8ef5cbac`；修复内容随
  `5de83879` 进入历史（见「交接与回退」的提交信息问题）。拥有
  `moment_comment_composer.dart`、`scan_qr_page.dart`、`chat_transfer_sheet.dart`、
  `chat_red_packet_sheet.dart`、`room_page.dart` 及对应测试
- 最后更新时间（含时区）：2026-09-16 23:29 +08（Asia/Hong_Kong）
- 下一条具体操作、必要输入、阻断的验收ID：用户按交付记录第 4 节路径真机验收 A1–A4；
  无阻断项

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 朋友圈评论→选图→发送：正常返回并带图，不卡死、可退出相册 | `MomentGallerySelection` 统一记录字段；`flash` 明确拒绝 | 契约测试（编译期）+ `moment_comment_composer_test` | 2123 debug 已装 Mi 6 | 待真机 |
| A2 | 群聊转账收款人只出现本群成员，非好友群成员也能转账 | `isGroup` + `_liveGroupMemberIdentities`（实时 `refreshRoomInfo`）；群聊不传 `contactsSource` | `chat_transfer_sheet_test`「群聊收款人只能来自当前群成员…」 | 同上 | 待真机 |
| A3 | 专属红包→指定成员：显示头像/备注，选中不再报「无法确认红包账号」 | 传 `resolveBusinessUser`/`avatarMedia`；`chatRoomMembersFor` 填业务身份 | `chat_red_packet_sheet_test` + 变异探针 | 同上 | 待真机 |
| A4 | 私聊转账收款人固定为对方、不可点击 | `_recipientLocked`：无点击、无箭头、`_pickRecipient` 直接返回 | `chat_transfer_sheet_test`「私聊转账收款人固定为对方，不可更改」 | 同上 | 待真机 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android Debug（仅 Mi 6 真机） | 0.3.92-debug/2123 | `5de83879`（含 `20d4673a` 的登录/会话改动） | `com.liuhetong.mobile`，固定身份 `75b31c66…ba61fff` | `artifacts/2026-09-16/android-0.3.92-debug-2123/ChatFlow-0.3.92-debug-2123-arm64-rebuilt.apk`，SHA256 `5e499e8c…66abad` | 2026-09-16 23:29:10 +08 覆盖安装成功，firstInstallTime 未变；**未做正式发布** |
| iOS | 未构建 | — | — | — | 未发布 |
| 服务端 | 未改动 | — | — | — | 未部署 |

测试记录：

- `flutter test`（全量，修复阶段）→ 退出码 0，2698 通过 / 0 失败（改动前 2680）。
  日志 `artifacts/2026-09-16/flutter-full-bugfix4.txt`。
- `flutter test`（全量，**提交后核实**）→ 退出码 0，2699 通过 / 0 失败。
  日志 `artifacts/2026-09-16/flutter-full-post2123.txt`。
- `flutter analyze` → 退出码 0，`No issues found!`。
- 定向回归（提交后核实，含 `chat_red_packet_sheet_test`、`local_history_clear_test` 等）
  → 33 通过 / 0 失败。
- 重建验证：清单语义一致、原生/Flutter 资产差异 0、smali 类差异 0（27313/27313）。
- 工具版本 Flutter 3.44.9 / Dart 3.12.2 / Apktool 2.12.1 / build-tools 36.0.0 /
  JDK 17.0.20.8；OS Windows 10 Pro 19045。
- 未执行项：未构建 iOS、未部署生产、未做服务端契约测试（本任务未改服务端）。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 根因调查（4 项） | 2026-09-16 22:3x +08 | 22:5x | 主动 | — | 源码追踪 | — |
| TDD 修复 | 22:5x | 23:1x | 主动 | — | 见验收台账 | — |
| 构建/安装 2123 | 23:1x | 23:29 | 工具 | — | build/install 日志 | — |
| 文档与索引 | 23:2x | 进行中 | 主动 | — | — | — |

总墙钟：精确值未知（未逐段计时），不估成精确分钟。

## 交接与回退

- 已确认根因/已排除假设：四项根因见验证记录。已排除：Matrix 房间成员关系、业务 API 契约、
  E2EE 与账本逻辑均非本次成因。
- **提交信息问题（需知悉）**：本次四项修复随提交 `5de83879` 进入历史，而该提交的信息是
  「feat: add download page for ChatFlow with iOS and Android installation options」，
  内容却包含移动端多项改动。历史不可追溯风险已存在；如需，可用
  `git log -p -- <file>` 定位，或后续提交补充说明。未回写历史（不改写已推送提交）。
- 待办及验收失败项：A1–A4 待用户真机验收。工作树仍留有其他任务的遗留文件
  `test/features/matrix/_tmp_probe_test.dart`，未清理（不属于本任务）。
- 已发布与仅候选的区别：本次全部为**真机 debug 测试包**，无任何正式发布。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（未触碰生产）。
- 运行中CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：Mi 6 上 `com.liuhetong.mobile` 是否为 2123；四项修复的代码标记
  （`MomentGallerySelection`、`_recipientLocked`、`isGroup`、`chatRoomMembersFor`）是否仍在；
  定向测试是否仍绿。
