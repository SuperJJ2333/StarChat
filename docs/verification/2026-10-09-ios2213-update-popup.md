# iOS0.4.44+2213普通更新弹窗已启用

用户在官网指定包分发后明确要求“好的，请你推送IOS更新弹窗”。2026-10-09 22:04+08 `IOS_POPUP_PUBLISH_PASS`，随后 `ROUTE_AND_AUDIT_READBACK_PASS`；现有iOS应用更新配置0.4.36+2205→0.4.44+2213。

- 仅修改`app_ios_latest_version`与`app_ios_latest_build`。通过现有公开SettingService、PostgreSQL事务十键CAS和两条成功审计，trace `ios2213-popup-20261009-9e5d3582`。Android五设置/iOS min3/说明/HTTPS安装页保持；无强更、服务重启、静态写入或IPA替换。
- 安装入口：[官网iOS安装页](https://www.liuhetong888.com/download?platform=ios&install=1)。精确包37966033bytes/SHA256 `9e5d358224a3fba64c6c5008bb0d20bf026a3fa3705a158b476ab1eb99bc8a21`；服务器全文SHA及网站三静态SHA/小型公网GET、工作站HEAD200/大小通过，未公网回拉IPA。
- 77轻量发布契约PASS（0.46s）；未变事务helper输入SHA `57115372317368a79d9fe697c0dcf9e136bafb7b83cfa37fbe23949b4bd3b7da`，运行模块路径及实际SETTINGS_SCRIPT与同目录文件相等门禁通过。复用既有相同事务PG证据，无重新运行PG声称。SPEC→QUALITY/security PASS。
- 真实当前API容器的路由函数读取生产设置：iOS2213、Android2213、无platform默认Android均匹配；两条审计actor/reason/前后值均精确一致。此为路由函数投影，未伪造用户令牌或称登录用户HTTP端到端验收。工作站HTTPS三个未登录接口均401，鉴权保持；全部容器ID/image与发布前相同。
- 唯一0700备份 `/opt/starchat/docs/verification/artifacts/2026-10-09/ios2213-popup-9e5d3582` 保存十设置前后态、静态SHA、容器身份。共享文件锁+数据库事务CAS；已审计写入不自动回退，结果不明先查trace及现值，拒绝盲重放。
- 包的既有AppID/Bundle不一致及原包payload差异仍为严格校验FAIL，见[官网发布报告](2026-10-09-ios2213-static-distribution.md)。本次配置变化未转为签名/安装/覆盖保数据验证通过。用户真机弹窗、下载安装结果待反馈；未发送APNs系统通知。

主工作树起始main b7db82ab；无执行代码或移动源码变化，仅任务文档/索引。证据目录 `docs/verification/artifacts/2026-10-09/ios2213-popup`：start-time、static-result、publish_popup、preflight-final、review-popup、release-contract-tests、popup-result、publish-and-route、public-check、public-ipa-head。恢复至完成约22:00–22:05+08，各未记录阶段精确耗时未知；实际发布加路由核验命令wall8.66s。
