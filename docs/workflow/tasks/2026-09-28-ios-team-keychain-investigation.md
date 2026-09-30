# iOS 换签与旧会话可恢复性调查

## 恢复入口

- 用户问题：为什么 iOS 用户记录似乎与 Team ID 绑定，能否解决。用户确认旧签名 iPhone **尚未**安装新团队包；之前确认旧 App 可读历史、旧签名团队不可用、没有外部保存的 Matrix 恢复密钥；此次再确认**没有其他持钥设备**。
- 范围：当前仅调查与设计，不读取用户设备、凭证或消息，不修改 E2EE/认证代码，不重新发布 IPA 或回退官方入口。关联[已发布 2189 包记录](2026-09-28-ios13-distribution.md)与[迁移可行性核查](../../verification/2026-09-28-ios13-migration-feasibility.md)。
- 状态：调查完成，准备向用户呈现可审阅的恢复方案。E2EE/密钥恢复属仓库保护变更，实施前需获方案批准并依次完成领域及质量/安全审查。
- 工作区：`D:/pythonProject/outsource/StarChat`，当前仅新建本调查记录；移动端、服务端源码只读。源码冻结版本仍需在方案中明确区分现行主目录与已发布 iOS 2189。
- 更新：2026-09-28 18:34 +08。阶段开始的精确时刻未记录，不推算工时。

## 验收台账

| ID | 目标 | 当前证据与状态 |
| --- | --- | --- |
| K01 | 区分业务账号与 Team ID | 已确认业务用户 ID/邮箱/手机号/Matrix 用户 ID 在服务端，不以 Apple Team ID 为主键；[业务模型](../../../services/business-api/app/modules/identity/models.py)。 |
| K02 | 定位本机数据绑定 | [ADR-0003](../../adr/0003-mobile-dual-session-persistence.md)将业务会话和 SQLCipher 密钥放平台安全存储；[iOS Keychain 查询](../../../apps/mobile_flutter/ios/Runner/IOSSecureSession.swift)未指定共享组，使用签名授权的默认组。[Apple TN2311](https://developer.apple.com/library/archive/technotes/tn2311/_index.html)说明权限由签名 entitlement 控制。 |
| K03 | 判定新 Team 可否直接读旧组 | 已发布旧包 Team `ZXB3TS7QD4`、新包 `A9HAF6NT6S`；[签名核验](../../verification/artifacts/2026-09-28/ios13-distribution/ipa-verification/report.md)。[Apple DTS](https://developer.apple.com/forums/thread/706128)说明变更 App ID 前缀后普通组旧项不可访问；旧团队不能签发过渡版，且此案为企业 IPA。仅改新包/服务器字段不能恢复旧组权限。 |
| K04 | 旧 E2EE 历史的现有恢复路径 | 已发布 2189 的恢复/设备验证 UI 无生产入口，`saveEncryptedRecoveryKey` 无生产调用点；用户确认无外部恢复密钥及其他持钥设备。服务器只保留密文，不接收房间密钥。若未来找到已存在且可解的备份，仍须逐账号实测；目前无已验证的旧历史全量迁移路径。 |
| K05 | 新签名包可安装及旧设备现状 | 用户尚未在旧签名 iPhone 安装新包，旧设备仍可读。新包真机覆盖安装、沙盒状态及聊天解密均未验证；不要把可能风险写成已经丢失。 |

## 方案方向与边界

未来可提供 Matrix 端到端加密备份及用户独立保存的恢复密钥、可信设备之间的验证和密钥共享；新团队 App 登录后用新本地库同步服务端密文并恢复房间密钥，不能把明文、恢复密钥或原始 SQLCipher 密钥交给业务 API。对保留旧加密库但缺 Keychain 密钥的设备须失败封闭、保留旧数据并提示可恢复范围。此方案可避免**未来**签名变化依赖 Team ID，但无法倒推出当前旧组中未迁移的密钥。现有旧 iPhone 不覆盖、不卸载。

## 阶段计时与交接

| 阶段 | 时间（Asia/Hong_Kong） | 类型 | 结果 |
| --- | --- | --- | --- |
| 仓库与 Apple/Matrix 规则核查 | 2026-09-28 18:28 左右至 18:34 +08（起点约数） | 调查/并行 | 三项独立只读核查：签名规则、本地存储、Matrix 恢复；未写生产、未收集用户密钥 |

下一可执行步骤：向用户解释业务账号与 Keychain 的区别、现有旧历史迁移的硬约束，并呈现“保留旧 iPhone + 新团队版独立运行”和“面向未来的端到端加密备份/设备迁移”方案。需要真机参与时只做用户主动、逐账号、密钥留在设备的验收。没有合法旧 Team 迁移构建或可用恢复密钥时，不能承诺旧消息全量无损恢复。
