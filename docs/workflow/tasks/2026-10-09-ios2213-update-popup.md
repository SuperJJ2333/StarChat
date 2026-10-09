# iOS2213更新弹窗

- 授权：用户最新“好的，请你推送IOS更新弹窗”，覆盖此前不启用弹窗的限制；不改变指定IPA及其已记录的签名/设备验证缺口。
- 源码main b7db82ab，工作树干净。owns本文、计划、验证报告、current-state新索引及专属ios2213-popup证据；无业务/移动/通用发布器代码变动。
- [计划](../../superpowers/plans/2026-10-09-ios2213-update-popup.md)。阶段：发布完成、待真机反馈。iOS latest2205→2213/version0.4.44，仅两设置及两审计；普通更新，min3/说明/安装页/Android保持。
- 基线：已发布网站SHA9e5d358224a3fba64c6c5008bb0d20bf026a3fa3705a158b476ab1eb99bc8a21，37966033bytes；严格签名FAIL不被元数据发布转为通过。
- 时间：2026-10-09约22:00+08恢复与实时读取；22:04+08发布及route/audit核验完成，命令wall8.66s；精确stage时间见start-time/preflight/result，未记录时段未知。
- 验收：77契约PASS，SPEC→QUALITY PASS，真实十键事务CAS，两条settings.update/SUCCESS审计；iOS/Android/legacy实际route函数投影通过，公网三路401及IPA HEAD通过；官网下载与容器身份保持。证据在docs/verification/artifacts/2026-10-09/ios2213-popup，见[报告](../../verification/2026-10-09-ios2213-update-popup.md)。
- 备份：/opt/starchat/docs/verification/artifacts/2026-10-09/ios2213-popup-9e5d3582（0700）；trace ios2213-popup-20261009-9e5d3582。无运行隧道/任务命令。若需撤销，先读当前设置及trace，另走有审计的CAS纠正，不盲重放。
- 下步：用户旧版iOS实际弹窗及安装反馈；未声称APNs通知推送、强制升级、签名或保数据覆盖验证通过。
