# Matrix 会话连续性与密钥恢复 Quality/Security Review

**日期：** 2026-08-25

**评审阶段：** 设计/实施前控制评审

**结论：** **PASS — Quality/Security 控制设计已批准。**

本评审只确认威胁、控制和可执行断言覆盖充分，不声称尚未实现的功能或计划测试已经通过。最终实现必须在 Task 10 后评审中提供单元、组件、真实 Synapse 集成、模拟器 E2E 与日志扫描证据。

## 证据基线

- **正式规格：** `docs/superpowers/specs/2026-08-25-matrix-session-continuity-key-recovery-design.md`，尤其第 4–11、13 节。
- **架构决策：** ADR-0003 的 SQLCipher/双域持久化边界、ADR-0004 的短期单次 login token 边界、ADR-0007 的显式删除条件和标准 Matrix 恢复协议。
- **当前 SDK：** `apps/mobile_flutter/pubspec.lock` 固定 `matrix 0.34.0`。该版本提供 `Encryption.bootstrap()`、SSSS、`m.megolm_backup.v1` room-key backup API、`m.secret.request`/`m.secret.send`、Olm 加密发送以及 `DeviceKeys.verified`/`blocked` 状态；这些是可用的实施原语，不等于应用层校验已经完成。
- **当前应用：** `matrix_client_factory.dart` 使用 SQLCipher pragma key 并把数据库密钥放在 `SecureSessionStore`；`matrix_e2ee_client.dart` 当前只创建/打开 SSSS，尚未完成在线 Megolm 备份及严格秘密响应校验。因此以下“计划断言”均须后续先红后绿。

## Threat matrix

| 威胁 | Attacker | Control | Assertion | 证据来源 | Result |
|---|---|---|---|---|---|
| stolen Business Token | 取得有效 Business Access/Refresh Token，但没有 Matrix 设备私钥、SSSS 恢复密钥或可信旧设备的攻击者 | Business Token 只能认证业务接口并申请短期单次 Matrix login token；新 Matrix 设备默认不可信，不能仅凭业务认证取得 `m.megolm_backup.v1` 秘密。撤销/失效后认证门拒绝访问，但不清本机 Matrix 数据。 | 计划测试证明 login token 单次/短期使用；仅凭 Business Token 的未验证新设备无法收到恢复秘密；API 捕获扫描不存在恢复密钥、room key 或消息明文。 | ADR-0004 决策 3–7；正式规格第 4、5.4、11.3、11.5 节。 | **PASS** |
| stolen Matrix Token | 取得 Matrix Access Token，但没有 SQLCipher 数据库、Olm 账号、备份私钥或 SSSS 恢复密钥的攻击者 | Synapse 只返回密文事件、加密备份和加密 to-device 内容；Business 认证门仍控制 APP 聊天入口。Token 可被撤销，且不得进入日志；任何 Matrix 权限都不能触达 ledger/wallet。 | 真实 Synapse 计划测试以测试标记扫描网络、容器日志和存储，只发现密文；撤销 token 后同步被拒而本机库不删除；财务接口调用数保持零。 | 根 `AGENTS.md`；正式规格第 4、6.2、11.2、11.5、11.7 节；ADR-0007 决策 8、11–12。 | **PASS** |
| 未验证设备 | 同 MXID 下尚未完成 SAS/二维码验证的新设备 | 只向同 MXID、已验证、未封禁且非本机设备发请求；响应还必须经 Olm 加密并校验发送设备身份、公钥和签名链。SDK 0.34.0 暴露 verified/blocked 与 verified-device SSSS 请求筛选原语。 | 计划单元和 Synapse 集成测试证明未验证设备收不到或无法使客户端接受 `m.megolm_backup.v1` 秘密。 | 正式规格第 5.4、9、11.3、11.5 节；SDK `encryption/ssss.dart`、`src/utils/device_keys_list.dart`。 | **PASS** |
| blocked device | 已封禁但仍可尝试发送 to-device 事件的旧设备 | 请求候选和响应接收两侧都检查 `blocked == false`；状态变化后不得沿用旧信任快照，且其他有效请求保持可重试。 | 计划测试在请求前及响应到达前分别封禁设备，均拒绝秘密且不写加密缓存、不开始备份恢复。 | 正式规格第 5.4、9、11.3、11.5 节；SDK `DeviceKeys.blocked` 与 SSSS 设备筛选。 | **PASS** |
| 伪造 request ID | 能注入或重放 Olm to-device 响应，但不知道当前挂起请求标识的设备/服务器观察者 | request ID 必须与本机当前、同 MXID、同备份版本的未完成请求精确绑定；未知、已取消或已消费 ID 一律拒绝，成功后取消其余请求。 | 计划单元测试篡改 request ID，断言秘密未缓存、备份未恢复，并产生不含敏感值的稳定拒绝事件码。 | 正式规格第 5.4、7、10、11.3 节。 | **PASS** |
| 15 分钟后重放 | 保存过有效加密响应并在有效期后重放的设备或中转方 | 请求记录使用可注入时钟和创建时间；接收时重新计算 15 分钟有效期，过期、已消费或已取消请求不接受。30 秒 UI 超时不缩短协议有效期，仍在 15 分钟内的迟到响应需完整校验。 | 计划测试把时钟推进到边界内外，证明边界内完整有效响应可恢复，超过 15 分钟的响应不缓存、不恢复。 | 正式规格第 8、9、11.3、11.4 节。 | **PASS** |
| 备份公钥不匹配 | 以其他备份版本的私钥/秘密替换响应，或服务器返回被替换的 backup auth data | 从候选秘密导出公钥，并与当前 MXID、备份版本和服务器 auth data 的公钥绑定比较；不匹配时停止，不覆盖本机秘密、不删除旧备份、不自动创建替代版本。 | 计划单元和 Synapse 集成测试篡改公钥/版本，断言现有版本和本机秘密保持不变，恢复不启动。 | 正式规格第 7、9、11.3、11.5 节；SDK 0.34.0 的 key backup info/restore 原语。 | **PASS** |
| SQLCipher DB 损坏 | 磁盘损坏、错误密钥或可篡改应用文件但无法解锁平台安全存储的攻击者 | 数据库打开失败时关闭聊天数据访问，保留数据库文件和原密钥，提供重试及明确二次确认的手动清除；不得自动删除、重建密钥或静默生成新设备。SQLCipher 仅保护静态数据，完整恢复仍依赖备份/可信设备。 | 计划单元测试注入 open failure，断言 delete/reset/key-generation 均未调用；模拟器测试验证错误页重试和手动清除确认边界。 | 正式规格第 6.2、9、11.2、11.6 节；`matrix_client_factory.dart` 的加密打开与独立 reset 路径。 | **PASS** |
| rooted-device 限制 | 已取得 root/jailbreak、调试注入或系统安全存储解锁上下文的本机攻击者 | SQLCipher 与 Keystore/Keychain 是纵深保护，不承诺抵抗已完全控制的设备；本设计也不增加服务器托管或业务凭证派生恢复密钥作为补偿。恢复密钥仍不得进入 Business API、Synapse 明文面、日志或验证材料。该残余风险必须在最终安全说明中明确，不能宣称“root 后仍安全”。 | Task 10 复核发布配置没有调试旁路或普通存储副本，日志/网络/服务器扫描无秘密，并记录平台安全存储在 rooted/jailbroken 环境下不提供绝对保护的残余风险；不把尚未定义的平台完整性拦截策略冒充现有控制。 | 正式规格第 3、4、5.3、10、11.7 节；ADR-0007 安全理由；`session_store.dart` 与 `matrix_client_factory.dart` 的当前安全存储/SQLCipher 接入。 | **PASS** |
| 敏感日志泄漏 | 能读取应用、崩溃、分析、Synapse 或验证日志的内部人员/恶意应用 | 结构化日志只含稳定事件码、阶段、结果、trace ID 和安装级 HMAC-SHA256 脱敏标识；禁止消息/附件明文、恢复/Olm/Megolm 密钥、Token、诊断盐和完整 Matrix 标识。验证材料也不保存测试标记值。 | 发布版和调试版计划扫描应用日志、API 捕获、容器日志、Synapse 存储和验证材料；敏感测试标记命中数为零，同时错误事件具备 `event_code`、stage、outcome、trace ID。 | 正式规格第 10、11.5、11.7、12 节；根 `AGENTS.md` 日志与仓库卫生规则。 | **PASS** |

## 审批边界与残余风险

本次审批接受以下明确边界：服务器被攻破或 token 被盗时，攻击者可能获得密文、元数据或以被盗身份发送 Matrix 事件，但不得因此得到恢复秘密/消息明文，也不得影响资产状态；完全受控的 rooted/jailbroken 终端超出 Keystore/Keychain 与 SQLCipher 的绝对保护承诺，应用必须透明说明并在 Task 10 复核该残余风险。

当前应用实现与上述控制仍有差距，尤其是在线备份、请求关联/时限/公钥校验、非破坏性 Token 失效路径和日志扫描。Quality/Security 仅批准按这些断言实施；Task 10 必须以实际输出完成最终后评审，不能沿用本文件的设计级 **PASS** 替代运行证据。
