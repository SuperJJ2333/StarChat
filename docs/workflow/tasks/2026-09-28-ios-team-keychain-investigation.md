# iOS 换签与旧会话可恢复性调查

## 恢复入口

- 用户问题：为什么 iOS 用户记录似乎与 Team ID 绑定，能否解决。用户确认旧签名 iPhone **尚未**安装新团队包；之前确认旧 App 可读历史、旧签名团队不可用、没有外部保存的 Matrix 恢复密钥；此次再确认**没有其他持钥设备**。
- 范围：当前仅调查与设计，不读取用户设备、凭证或消息，不修改 E2EE/认证代码，不重新发布 IPA 或回退官方入口。关联[已发布 2189 包记录](2026-09-28-ios13-distribution.md)与[迁移可行性核查](../../verification/2026-09-28-ios13-migration-feasibility.md)。
- 状态：用户已批准设计方向，调查与设计草案完成，书面规格待用户审阅。E2EE/密钥恢复属仓库保护变更，实施前仍需批准 ADR 及完成领域、质量/安全设计审查。
- 工作区：`C:/Users/Administrator/.codex/worktrees/ios-media-room-followup/StarChat`，源码基线 55fecdc4；本任务仅拥有本记录、iOS 换签恢复规格及 ADR-0087 草案。主目录 b9eca8a4 用于只读核查；移动端、服务端源码未修改。已发布 iOS 2189 为冻结候选。
- 更新：2026-09-28 18:50 +08 左右。阶段开始的精确时刻未记录，不推算工时。

## 验收台账

| ID | 目标 | 当前证据与状态 |
| --- | --- | --- |
| K01 | 区分业务账号与 Team ID | 已确认业务用户 ID/邮箱/手机号/Matrix 用户 ID 在服务端，不以 Apple Team ID 为主键；[业务模型](../../../services/business-api/app/modules/identity/models.py)。 |
| K02 | 定位本机数据绑定 | [ADR-0003](../../adr/0003-mobile-dual-session-persistence.md)将业务会话和 SQLCipher 密钥放平台安全存储；[iOS Keychain 查询](../../../apps/mobile_flutter/ios/Runner/IOSSecureSession.swift)未指定共享组，使用签名授权的默认组。[Apple TN2311](https://developer.apple.com/library/archive/technotes/tn2311/_index.html)说明权限由签名 entitlement 控制。 |
| K03 | 判定新 Team 可否直接读旧组 | 已发布旧包 Team `ZXB3TS7QD4`、新包 `A9HAF6NT6S`；[签名核验](../../verification/artifacts/2026-09-28/ios13-distribution/ipa-verification/report.md)。[Apple DTS](https://developer.apple.com/forums/thread/706128)说明变更 App ID 前缀后普通组旧项不可访问；旧团队不能签发过渡版，且此案为企业 IPA。仅改新包/服务器字段不能恢复旧组权限。 |
| K04 | 旧 E2EE 历史的现有恢复路径 | 已发布 2189 的恢复/设备验证 UI 无生产入口，`saveEncryptedRecoveryKey` 无生产调用点；用户确认无外部恢复密钥及其他持钥设备。服务器只保留密文，不接收房间密钥。若未来找到已存在且可解的备份，仍须逐账号实测；目前无已验证的旧历史全量迁移路径。 |
| K05 | 新签名包可安装及旧设备现状 | 用户尚未在旧签名 iPhone 安装新包，旧设备仍可读。新包真机覆盖安装、沙盒状态及聊天解密均未验证；不要把可能风险写成已经丢失。 |
| K06 | 并存安装与同账号登录风险 | 不同 Bundle ID 可隔离安装和本地容器；但 Business 新登录撤销旧会话，Synapse 登录删除其他 Matrix 设备。同账号两 App 同时在线不成立。首轮只用独立、无余额测试账号；唯一持钥旧 iPhone 不登录新包的真实旧账号。 |
| K07 | 未来恢复方案 | [书面规格](../../superpowers/specs/2026-09-28-ios-team-independent-e2ee-recovery-design.md)与[ADR-0087 草案](../../adr/0087-ios-cross-team-e2ee-recovery.md)已写，待用户审阅；真实加密备份需 Matrix 密文逐会话读回和全新设备解密证明，现有 SSSS-only 入口不算完成。 |
| K08 | 草案一致性与安全边界 | [文档核验](../../verification/2026-09-28-ios-team-recovery-design.md)：七份新文档相对链接缺失 0、占位词 0、staged whitespace 检查退出 0；独立领域及质量/安全只读复核提出的问题已写回规格，未批准 ADR、未运行实现测试。 |

## 方案方向与边界

未来可提供 Matrix 端到端加密备份及用户独立保存的恢复密钥；新团队 App 登录后用新本地库同步服务端密文并恢复房间密钥，不能把明文、恢复密钥或原始 SQLCipher 密钥交给业务 API。对保留旧加密库但缺 Keychain 密钥的设备须失败封闭、保留旧文件并提示可恢复范围；现有启动流程尚缺安全登录壳，不能把设计写成已实现。可信设备间在线密钥共享受单设备登录策略阻断，须独立设计并评审，不能作为旧 2189 的迁移承诺。现有旧 iPhone 不覆盖、不卸载，也不在并存测试包里登录真实旧账号。

## 阶段计时与交接

| 阶段 | 时间（Asia/Hong_Kong） | 类型 | 结果 |
| --- | --- | --- | --- |
| 仓库与 Apple/Matrix 规则核查 | 2026-09-28 18:28 左右至 18:34 +08（起点约数） | 调查/并行 | 三项独立只读核查：签名规则、本地存储、Matrix 恢复；未写生产、未收集用户密钥 |
| 用户批准方向及书面设计 | 2026-09-28 18:34 后；精确起点未记录 | 2026-09-28 18:50 +08 左右 | 设计/并行 | 用户批准推荐方向；补查 Business 和 Synapse 单设备策略；起草规格及 ADR，未修改源码或设备 |
| 独立只读评审与文档核验 | 2026-09-28 18:50 +08 左右 | 2026-09-28 18:57 +08 | 评审/并行 | 领域与质量/安全建议已写回并复核；相对链接、占位词和 staged whitespace 通过；正式 ADR 批准及实现仍待后续 |

下一可执行步骤：用户审阅书面规格和 ADR 草案；若要求修改先同步文档，若批准则编写逐任务实施计划，先完成受保护变更的 Domain 与 Quality/Security 设计评审并批准 ADR。真机验收先用可丢弃测试设备与独立账号；唯一旧持钥账号不得用于“试登录”。没有合法旧 Team 迁移构建或可用恢复密钥时，不能承诺旧消息全量无损恢复。
