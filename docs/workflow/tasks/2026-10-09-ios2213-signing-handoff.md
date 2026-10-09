# iOS0.4.44+2213待签名IPA

- 授权：用户要求提供IPA自行签名，之后回传分发；本阶段仅候选构建/交接，无生产/弹窗或TestFlight写入。
- 源：main ee558632，独立worktree C:/Users/Administrator/.codex/worktrees/ios-signing-2213/StarChat，branch codex/ios-history-ipa-2213。
- 计划：[构建交接](../../superpowers/plans/2026-10-09-ios2213-signing-handoff.md)。
- 文件所有权：root仅workflow版本、契约测试、本文/计划/证据。无产品逻辑变更。
- 开始：2026-10-09，精确阶段时间在本任务receipt中；当前候选交接完成，等待用户企业签名回传。
- 目标：0.4.44+2213，com.liuhetong.liuhetongMobile，arm64/iOS16+，待企业重签，源APNs/VoIP/SQLCipher/Keychain边界保留。
- 已有门禁：同源main共享5758PASS9skip/analyze0；本轮CI版本不一致RED1，修正后focused见version-green.log。
- 证据：docs/verification/artifacts/2026-10-09/ios2213-signing/。
- 下一步：收到用户回签IPA后，核验最终签名/profile/实际权益及与本候选payload关系，再更新iOS分发渠道。

| ID | 预期 | 状态 |
| --- | --- | --- |
| SOURCE | 最新共享源码与当前版本一致 | 候选2f423a3499727f7080f4a8bf1d8c3a8225b3d5ba，与main所有移动端Git blob一致 |
| DEVICE | 完整生产plugins与arm64 release IPA | SUCCESS，29plugins/46frameworks |
| NATIVE | iOS存储/SQLCipher/Keychain实跑 | SUCCESS，13+4+1=18PASS/attempt1 |
| HANDOFF | IPA、manifest、权益说明及SHA | Downloads与primary delivery副本SHA一致 |
| PUBLICATION | 本阶段不变更线上 | 未执行 |

最终签名身份/Keychain保留数据覆盖升级须绑定回签IPA和真机结果，不以候选源码权益代替实际已签权益。

## CI启动与本地验证

- 2026-10-09 18:49:56+08 GitHub创建run37919997058/attempt1，源码2f423a3499727f7080f4a8bf1d8c3a8225b3d5ba，branch codex/ios-history-ipa-2213；device113785366978、simulator113785366949。只push候选分支，无mainpush/Apple upload/生产变更。
- version-red.log：原workflow仍2205，版本契约RED1；version-green.log：打包+版本36PASS/3.02s。native-contract-local.log为1PASS/1Windows Ruby条件skip，CI要求Ruby实际2PASS/0skip。先前命令误写不存在测试文件造成no tests collected，已纠正路径，非源码失败。
- source-and-gates.json：所有移动端Git blobs与刚完成main一致，共享5758PASS/9skip/analyze0按精确输入复用；不是用Windows结果替代iOS。
- review-prebuild.md：SPEC→QUALITY均PASS；确认候选分支只匹配unsigned workflow，不触发签名上传任务。
- 本机凭据仅GCM进程内使用，未保存/打印；GitHub artifact重定向跨host会移除Authorization，HTTPS校验保留。

## Device已完成、native尚待

- Device113785366978 SUCCESS；pod102.3s/Xcode227.6s，完整Runner87.9MB。macOS Ruby权限2PASS/0skip。
- CI artifact11611333284外层ZIP34582517bytes/SHA4500f8231c39af3ce3a08c30d73c0d4fb450f225cc2b0e49eb288527cac6df2f；device evidence11611433142/SHA0873805aca5dc98f65b170b0b356fd0ac667e90b5df61c29701921d2aef303a5。均API digest及CRC绑定。
- IPA34839152bytes/SHA3cfa40ed6bae4d91e6b702162f5d9ccbfb2a3620bcedf9021b6e53662347b952；479Payloadfiles/46frameworks/29productionplugins，actualarm64/iPhoneOS/版本2213/SQLCipher6exports/资产/五usage校验通过。
- review-artifact.md先SPEC后QUALITY PASS，全部46框架SHA独立验证。source entitlements非实际已签权益。
- 原生simulator三target仍执行中，未宣称native通过或打包交接完成；IPA已复制Downloads及primary ignored delivery，两副本SHA一致，正式渠道未改。

## 最终交接（替代上述阶段性native待执行状态）

- 两job/CI均SUCCESS，native18PASS，三target均首次exit0/无超时或VMservice stall。selected-source绑定iPhone15/iOS26.2与精确2f423a34。final-build-receipt.json记录各job开始/完成与墙钟，模拟器artifact11613191231/API digest及CRC验证。
- 首target编译511.8s、测试5m28s；其中25万迁移192573ms，timer持续推进。此为后台迁移合成测试，不等同真机任意历史UI帧证明。
- 已交付未签名IPA34839152bytes/SHA3cfa40ed6bae4d91e6b702162f5d9ccbfb2a3620bcedf9021b6e53662347b952。路径C:/Users/Administrator/Downloads/ChatFlow-0.4.44-build2213-unsigned.ipa；对应签名说明同Downloads，完整manifest/entitlements/工具与SHA在primary ignored delivery。
- 成品审查SPEC→QUALITY已通过，最终native补充见review-artifact.md。仅候选分支推送，未推main/未改正式Android2213或iOS2205/官网/弹窗。
- 本轮打包交付无剩余工作；企业签名与真机保数据覆盖检查、公开分发等待用户回签文件。所有CI/本地watcher已结束，无自建隧道。
