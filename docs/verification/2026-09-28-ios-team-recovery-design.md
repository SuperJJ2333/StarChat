# iOS 跨团队恢复设计核验（2026-09-28）

范围仅为文档和只读架构审查。工作树基线 55fecdc49addbb0cf4d3e3f6b2b56eb2eab0c358；未修改移动端、业务 API、Synapse、服务器设置或安装包；未触碰旧签名 iPhone。

## 产物身份

| 文件 | SHA-256 |
| --- | --- |
| [设计规格](../superpowers/specs/2026-09-28-ios-team-independent-e2ee-recovery-design.md) | E840F026983CD3E3188410F108D1453F62287173EC8263A56FB26E50470357F7 |
| [ADR-0087 草案](../adr/0087-ios-cross-team-e2ee-recovery.md) | 9BC120CC5D59822375AF892664B7D5AD618007678B2F7FE338E7F55D63DC9DC5 |

## 核查结果

- 2026-09-28 18:57 +08，PowerShell 7、UTF-8 无 BOM：git diff --cached --check 退出 0；补充本报告后二次核验时 staged 文档九项、非文档 0、无 unstaged 文件。
- 对本次七份新文档逐个解析相对 Markdown 链接，缺失 0；规格、ADR、任务记录的 TBD/TODO/FIXME/待定/占位扫描命中 0。现有 current-state.md 旧段落有历史缺失链接，本次没有扩展为全文件链接通过声明。
- 独立领域只读复核：确认 Business 与 Matrix 稳定身份、单设备 broker 会撤销旧 family 并删除旧 Matrix 设备；补入来源端“准备换机”门禁、目标端认证前告知、本机 Keychain 缓存与外存恢复码区别，以及 O/N/P 分账号验收。复核后无剩余 P0/P1 领域设计阻断项。
- 独立质量/安全只读复核：补入解锁后真实 Keychain 缺失判定、SSSS IV/MAC 与备份私钥推导公钥校验、房间密钥恢复与设备信任分状态、逐条下载解密才可显示“可切换”。复核后无剩余 P1 设计缺口。
- 上述为草案审查与文档一致性核验，**不是** ADR 批准、实现测试、真机迁移、IPA 构建或发布。用户审阅书面规格后，还需按 AGENTS.md 完成正式 Domain 与 Quality/Security 设计批准和实施计划。
