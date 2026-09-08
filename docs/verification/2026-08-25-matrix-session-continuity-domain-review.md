# Matrix 会话连续性与密钥恢复 Domain Review

**日期：** 2026-08-25

**评审阶段：** 设计/实施前控制评审

**结论：** **PASS — Domain 控制设计已批准。**

本结论批准的是
`docs/superpowers/specs/2026-08-25-matrix-session-continuity-key-recovery-design.md`
和 ADR-0007 定义的领域边界，不代表功能已经实现或测试已经运行。当前代码中的破坏性启动、登录补偿路径仍须在后续任务中按测试先行方式替换；最终实现仍须通过 Task 10 的规格符合性、Domain 和 Quality/Security 后评审。

## 权威边界

| 评审项 | 决策与证据 | 结果 |
|---|---|---|
| Business API 只认证，不传 Matrix 秘密 | Business API 的权限止于业务账号认证、会话撤销、账号状态和一次性 Matrix Login Token；SSSS 恢复密钥、备份私钥、Olm/Megolm 会话密钥、消息及附件明文不得进入 Business 请求、响应、Outbox 或日志。证据：正式规格第 3、4、5.4 节，ADR-0004 决策 1–5，ADR-0007 决策 6–8。 | **PASS** |
| Login grant MXID 必须先与本机绑定一致 | 在打开聊天、同步或展示任何本机房间数据前，必须比较 login grant 的 `matrix_user_id` 与独立持久化的本机绑定；一致时才复用原数据库/设备，不一致时关闭聊天入口并进入明确切换确认。证据：正式规格第 5.1、5.2、6.2、9 节，ADR-0007 决策 1、3、4。 | **PASS** |
| 不同账号只在明确确认后 reset | grant MXID 不同不得立即 reset；取消时保留原账号全部 Matrix 数据并终止新账号切换，确认后才允许删除原账号 SQLCipher 数据库、数据库密钥、SSSS 本机缓存和绑定。独立“清除本机聊天数据”还需二次确认。证据：正式规格第 6.3 节，ADR-0007 决策 4。 | **PASS** |
| 普通退出保留 Matrix DB/device/keys | 普通退出尽力撤销并清除 Business 会话，停止同步并关闭数据库句柄；本机绑定、SQLCipher 数据库及密钥、Matrix Access Token、设备 ID、Olm/Megolm 和交叉签名状态全部保留。任何部分失败不得补偿为 Matrix reset。证据：正式规格第 6.1 节，ADR-0007 决策 1–2。 | **PASS** |
| Token 失效或封禁拒绝访问但不删 Matrix 数据 | Business Token 失效、账号封禁或 Matrix `M_UNKNOWN_TOKEN`/`M_FORBIDDEN` 必须关闭 Business 认证门后的聊天入口；可对同一绑定账号使用原设备 ID重新认证，但不得调用 SDK `logout()`、`clear()` 或本地 reset，也不得删除数据库及安全存储密钥。证据：正式规格第 3、5.2、6.2、9 节，ADR-0007 决策 3、11。 | **PASS** |
| Matrix 状态不得影响 ledger/wallet | Matrix 事件、bot 回调、推送、设备验证/封禁、备份或解密状态都只能改变通信域状态和展示；不得读取、推导或写入 ledger、wallet、red packet，也不得触发财务补偿。资金恢复与聊天密钥是否可恢复相互独立。证据：根 `AGENTS.md` 架构不变量，正式规格第 5.4、9、13 节，ADR-0007 决策 8–9。 | **PASS** |

## 实施约束与待验证证据

当前基线不是本次审批的运行证据：

- `apps/mobile_flutter/lib/core/session_bootstrap_controller.dart` 当前仍会在 Business 会话缺失、Matrix Token 失效或封禁时调用 `resetLocalStore()`。
- `apps/mobile_flutter/lib/features/auth/login_controller.dart` 当前仍会在不同 MXID 未确认时 reset，并在若干登录失败补偿路径调用 Matrix logout。
- `apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart` 已能复用 SQLCipher 持久数据库，也明确区分 `reopen` 与删除数据库/密钥的 `reset`，可作为非破坏性关闭和显式清除的实施基础。
- `apps/mobile_flutter/lib/core/session_store.dart` 当前把 Business 会话与 Matrix 数据库密钥分开存储，但版本化本机 Matrix 绑定仍需实现。

后续实现必须以正式规格第 11 节的测试先行矩阵证明：普通退出、Business 会话缺失、Token 失效、封禁和暂时错误的 reset 次数均为零；不同 MXID 取消时为零且确认后恰为一次；聊天入口在绑定校验和 Business 认证通过前不可访问；Matrix 事件或密钥状态不能调用任何财务写接口。上述测试证据将在实现阶段产生，不在本预评审中冒充已运行结果。

## 审批

Domain 评审批准该受保护变更进入实现阶段，条件是实现不得扩大 Business API、Synapse 或财务域权限，并在 Task 10 后评审中逐项用实际测试和脱敏证据复核。
