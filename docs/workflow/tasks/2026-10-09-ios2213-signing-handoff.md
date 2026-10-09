# iOS0.4.44+2213待签名IPA

- 授权：用户要求提供IPA自行签名，之后回传分发；本阶段仅候选构建/交接，无生产/弹窗或TestFlight写入。
- 源：main ee558632，独立worktree C:/Users/Administrator/.codex/worktrees/ios-signing-2213/StarChat，branch codex/ios-history-ipa-2213。
- 计划：[构建交接](../../superpowers/plans/2026-10-09-ios2213-signing-handoff.md)。
- 文件所有权：root仅workflow版本、契约测试、本文/计划/证据。无产品逻辑变更。
- 开始：2026-10-09，精确阶段时间在本任务receipt中；当前准备/构建前验证。
- 目标：0.4.44+2213，com.liuhetong.liuhetongMobile，arm64/iOS16+，待企业重签，源APNs/VoIP/SQLCipher/Keychain边界保留。
- 已有门禁：同源main共享5758PASS9skip/analyze0；本轮CI版本不一致RED1，修正后focused见version-green.log。
- 证据：docs/verification/artifacts/2026-10-09/ios2213-signing/。
- 下一步：专项验证/规格→质量审查，push仅候选branch，然后追踪macOS完整device/native门禁。

| ID | 预期 | 状态 |
| --- | --- | --- |
| SOURCE | 最新共享源码与当前版本一致 | 已冻结基线，待候选SHA |
| DEVICE | 完整生产plugins与arm64 release IPA | 待CI |
| NATIVE | iOS存储/SQLCipher/Keychain实跑 | 待CI |
| HANDOFF | IPA、manifest、权益说明及SHA | 待构建 |
| PUBLICATION | 本阶段不变更线上 | 未执行 |

最终签名身份/Keychain保留数据覆盖升级须绑定回签IPA和真机结果，不以候选源码权益代替实际已签权益。
