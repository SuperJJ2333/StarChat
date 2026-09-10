# iOS 卸载重装登录失败（L07）修复

## 恢复入口

- 目标、用户授权来源及边界：用户 2026-09-11 报告 iPhone 8 卸载重装后同账号登录出现
  "聊天登录未完成，请重试（L07）"，要求定位并修复。用户已选定修复方向（安装标记 +
  首次启动清理）与清理范围（清除全部遗留、对齐 Android）；授权撰写 ADR。边界：
  客户端本地存储与启动流程；不改服务端、不改 E2EE 算法与密钥恢复流程。
- 关联计划/ADR：设计
  [2026-09-11-ios-reinstall-installation-generation-design.md](../../superpowers/specs/2026-09-11-ios-reinstall-installation-generation-design.md)、
  [ADR-0068](../../adr/0068-installation-generation-reset.md)（待双评审）。
- 当前状态：调查完成，设计待评审（尚未实现）。
- 负责人、工作树、文件所有权、源码 commit：工作树 `.worktrees/ios-reinstall-l07`，
  分支 `codex/ios-reinstall-l07`，基线 `8ec6782e`。本任务拥有：上述设计文档、ADR-0068、
  本任务记录，以及实施阶段将新增/修改的
  `apps/mobile_flutter/lib/core/installation_marker.dart`（新）、
  `apps/mobile_flutter/lib/core/installation_reconciler.dart`（新）、
  `apps/mobile_flutter/lib/core/session_store.dart`、`apps/mobile_flutter/lib/main.dart`、
  `apps/mobile_flutter/test/features/matrix/ios_reinstall_continuity_test.dart`。
  **不触碰**主工作树中另一任务的未提交 `[L07Debug]` 插桩
  （`session_store.dart` / `login_controller.dart` / `matrix_e2ee_client.dart` / `main.dart`）。
- 最后更新时间（含时区）：2026-09-11T00:47:52+0800。
- 下一条具体操作、必要输入、阻断的验收 ID：用户评审设计文档与 ADR-0068 →
  调用 writing-plans 产出实施计划 → TDD 实现。阻断 A01–A05；A06 需真机。

## 根因（已确认部分与未确认部分）

已确认（代码级复现）：iOS 卸载后钥匙串保留、沙盒（含 SQLCipher 库）删除，
`continuityMetadata` 读到仍在的绑定却面对空库，抛
`StateError('Matrix continuity identity is unavailable')`；该异常发生在
`account_storage` 阶段，即 L07。

已排除（服务端只读调查）：不存在"同一 deviceKey 登录撤销本次新会话"的路径
（`tokens.py:56-66` 先撤销、`:85-92` 后创建，同一事务）。

未实测确认：同机"被登出"提示归因为随钥匙串存活的旧业务会话在启动时被恢复、
而该 family 已被服务端标为 `SESSION_REPLACED`。按风险记录，不作结论。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A01 | 重装后同账号登录不再出现 L07 | 未开始 | 复现用例已存在（断言修复前行为，绿）；实施时反转断言 | 无 | 待真机 |
| A02 | iOS 重装的本地状态与 Android 卸载后一致 | 未开始 | T3–T5、T8 计划 | 无 | 待真机 |
| A03 | 清理失败不永久化残留（标记不写入） | 未开始 | T6 计划 | 无 | — |
| A04 | 标记读取失败不误删有效会话 | 未开始 | T7 计划 | 无 | — |
| A05 | 现有完整性守卫与账号切换行为不变 | 未开始 | 相关回归套件 | 无 | — |
| A06 | 真机确认 L07 消失 | 未开始 | 需含修复的构建 | 无 | **未完成** |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| iOS 企业版（用户设备） | 0.3.81/2085（用户报告环境，未在本次核对设备） | 含 `e373329b` | 企业签名 | 见 2026-09-10-ios-0381-enterprise-publication.md | 未发布新包 |

本任务至今无发布产物。

已执行测试（真实退出码）：

- `flutter test test/features/matrix/ios_reinstall_continuity_test.dart`
  → 退出码 0，`All tests passed!`（3 个用例）。该文件当前**断言修复前的行为**，
  用途是证明异常即 L07 的来源，不是修复已生效的证据。
  工作目录 `apps/mobile_flutter`；工具链 Flutter 3.44.9 / Dart 3.12.2；
  操作系统 Windows 10 Pro 19045。源码输入：工作树 `codex/ios-reinstall-l07` 基线 `8ec6782e`。
- 未执行：`flutter analyze`、共享逻辑全量 Flutter 门禁、任何构建与真机验证。
  原因：设计尚未获批，未改动生产代码。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 定位 | 未知（本次会话未记录起始时间） | 2026-09-11T00:47:52+0800 | 主动 + 两个只读调查子代理并行 | 服务端会话语义、客户端连续性守卫 | 根因已确认；计时不可用 | 设计评审 |

总墙钟：不可用——本次会话起始时间未记录，按规则记为未知，不依文件时间编造。

## 交接与回退

- 已确认根因/已排除假设：见上"根因"节。已排除"同 deviceKey 自撤销"假设。
- 待办及验收失败项：A01–A06 全部未开始。
- 已发布与仅候选的区别：本次无任何构建与发布，不存在候选包。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：不适用（无服务端与生产改动）。
- 运行中CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：先读本记录与设计文档，确认设计是否已获批准、
  ADR-0068 是否已过双评审；再确认主工作树的 `[L07Debug]` 插桩是否仍属其他任务未提交状态。
  实现时遵守 TDD：先把复现用例的断言反转（红），再最小实现（绿）。
