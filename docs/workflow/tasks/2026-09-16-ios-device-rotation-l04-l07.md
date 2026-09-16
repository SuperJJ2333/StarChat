# 2026-09-16 iOS build 2121 登录 L04/L07：device 轮换与账号生命周期修复

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-16 明确要求"彻底修复 iOS build 2121 仍然存在的
  登录 L04 / L07"，并明确 2121 当前代码本身仍有缺陷、不得归因于旧包。授权范围：Matrix /
  登录 / 本地账号存储 / session lifecycle 的代码修复与自动测试；**不含**真机测试（用户自行执行）、
  构建 APK/IPA、发布、部署。禁止：清库规避、弱化 E2EE continuity、删除 binding 掩盖 mismatch、
  静默吞异常、改 FCM、顺手重构无关业务。
- 关联计划/ADR：本任务无独立计划文件；语义决策记录在
  [ADR-0072](../../adr/0072-matrix-device-id-rotation-continuity.md)（状态：提案，待批准）。
- 当前状态：实现 + 本地自动验证完成，**待用户真机验收与审查签署**。未构建、未安装、未发布。
- 负责人、工作树、文件所有权、源码commit：本会话在主工作树
  `D:\pythonProject\outsource\StarChat` 作业，基线 `8ef5cbac`。本任务独占的源文件：
  `lib/core/matrix_local_binding.dart`、`lib/core/session_store.dart`、
  `lib/features/matrix/matrix_client_factory.dart`、`lib/features/matrix/matrix_e2ee_client.dart`、
  `lib/features/matrix/matrix_security_logger.dart`、`lib/main.dart`、
  `test/features/matrix/device_rotation_login_lifecycle_test.dart`、
  `test/features/matrix/matrix_client_factory_test.dart`。
  并行任务正在修改 `lib/features/transfer/`、`lib/features/moments/`、`docs/workflow/current-state.md`
  等文件，本任务未触碰。
- 最后更新时间（含时区）：2026-09-16 23:10 +08。
- 下一条具体操作、必要输入、阻断的验收ID：用户在 iPhone 上按 A1 场景复测（同账号 A 已在
  设备 1 登录 → iPhone 重登 A）；阻断项 A1/A2 需真机反馈，A3（审查签署）需用户指定审查人。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | 账号 A 已在设备 1 登录；iPhone 重登 A：Business 成功 → 服务端单设备生效 → 收到 rotated device id → 安全更新 binding → Matrix 登录成功 → matrix-session → sync → 进入聊天首页；**无 L04、无 L07** | 是 | `device_rotation_login_lifecycle_test.dart`（服务端轮换 + 已存在 binding、同账号远端登录全链路、集成首登） | 无（未构建） | **待真机** |
| A2 | 失败可恢复：一次登录失败后重试必须成功，不得变成 L07 | 是 | 同上（L04 型失败后重试、并发 suspend 后重试） | 无 | 待真机 |
| A3 | 不弱化 E2EE：真正身份错配（换账号/homeserver/Olm 指纹/库代号）仍失败关闭 | 是 | 同上（轮换四类前置条件拒绝、Olm 身份变化拒绝、指纹不一致拒绝、continuity=unknown） | 无 | 待审查签署 |
| A4 | 数据安全：不删聊天记录、不重建 Olm 身份、不换 SQLCipher key | 是 | 同上（cipher/路径不变、`deletedPaths` 为空）；未做真实设备数据核对 | 无 | 待真机 |
| A5 | 账号切换 A→B→A：各自库/key/binding，无 alias、无 L07 | 是 | 同上（switching accounts） | 无 | 待真机 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| iOS/Android 客户端 | 未构建（沿用 0.3.92/2121 现状，本任务不含新包） | 未提交（工作树基于 `8ef5cbac`） | — | — | — |

测试记录：命令、退出码、通过/失败数、输入 hash、工具版本见
[验证记录](../../verification/2026-09-16-device-rotation-binding-migration.md)。
要点：`flutter test` 全量 **2699 通过 / 0 失败（退出码 0）**；
`flutter test test/features/matrix test/features/auth test/core` 1672 通过；
`dart analyze`（本任务 8 文件）No issues found；含一次变异敏感性检查（见验证记录）。
修复前同一组用例 6/6 失败，失败栈来自生产代码 `MatrixClientFactory.continuityMetadata`。
未执行项：真机测试、构建、发布、iOS 原生编译；
`flutter analyze` 全仓仍有 2 个 error，来自**并行任务**修改的
`lib/features/transfer/chat_transfer_sheet.dart` 与 `test/features/moments/moment_comment_composer_test.dart`，
本任务未声称全仓 analyze 通过。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 根因调查 | 2026-09-16 约 22:00 +08 | 22:20 | 主动读码 + codegraph | 无 | 定位 binding 不匹配 → L04 → 半挂起 → L07 链路 | 写失败用例 |
| 失败用例（红） | 22:20 | 22:35 | 工具（`flutter test`） | 无 | 6/6 失败，失败点与根因逐条对应 | 实现修复 |
| 实现 | 22:35 | 22:55 | 主动 | 无 | 绑定迁移 + suspend 重构 + selectAccount 临界区 + 诊断 | 补测试 |
| 测试补齐（绿） | 22:55 | 23:05 | 工具 | 无 | 14 新用例全绿，既有用例 2 处语义更新 | 全量验证 |
| 全量验证 | 23:05 | 23:35 | 工具（全量 3×~2 分钟）+ 变异检查 | 无 | 2699 通过 / 0 失败，analyze（本文件范围）无问题 | 文档与提交 |

总墙钟：约 1 小时 35 分（含并行的其他任务干扰造成的两次全量重跑与一次变异敏感性检查）。
重复工作：首次全量测试因并行任务改坏 `chat_transfer_sheet.dart` 产生 19 个编译类失败，
待其修好后重跑得全绿；非本任务代码问题。未知时段：无。

## 交接与回退

- 已确认根因／已排除假设：确认根因是 `deviceId` 被当作身份锚点导致权威轮换被误判
  （见验证记录的 Root Cause）。已排除：drain 超时单因（2121 已修）、用户仍在使用 2120
  （测试机确认为 2121）、业务登录失败（业务登录成功）。
- 待办及验收失败项：A1/A2/A4/A5 待真机；A3 待审查签署；ADR-0072 待批准。
- 已发布与仅候选的区别：本次**没有**任何新构建或发布；2121 的 Android 发布与 iOS
  企业签名候选状态不变。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（未部署、未改服务端）。
- 运行中CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：本任务改动是否已提交；`flutter analyze` 全仓的 2 个 error 是否
  已由并行任务修好；用户在 iPhone 上的 A1 实测结果（是否仍出现 L04/L07 及其阶段码）。
