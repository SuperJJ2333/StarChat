# 新账号 CDN 客户端兼容发布核验

2026-11-04 HKT。用户选择先发布兼容 App、升级后删除旧 CDN。旧 CDN 及仍被其引用的旧桶均保留，尚未退役。

## Android 已发布

- 0.4.68 / 2237，`com.liuhetong.mobile`，arm64-v8a；源码 `42caae85306e4e82799d7b2cb76c4f714854a7d8`。
- 默认使用 `d29qsnrzc2iag0.cloudfront.net`，严格兼容旧 `d12fjr06o6tga5.cloudfront.net`；编译产物也核验两域名。原路径、HTTPS、重定向与 SHA 校验边界不放宽。
- 最终 APK 73,655,386 字节，SHA256 `2e54914c7687365a2c33e2053289a441ecbfbb889d483095eb50db18e0ac80eb`，固定 signer `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。标准重建、16KiB 对齐及内容检查通过。
- 不可变文件先安装香港下载站，再完整校验传到新账号 S3。S3 条件写入和 SHA256 checksum 核对通过；新 CloudFront 仅新增该 APK 精确路径，使用新桶源站，Deployed、HTTP HEAD 200 与 CORS 核验通过。没有改变其他源站路径或桶策略。
- 官网、版本 JSON、latest-arm64 别名已切换。单事务仅写 Android 版本/构建号，读回两条对应审计记录；其他八项设置保留，iOS 仍 0.4.67 / 2236，最低支持版本仍 3，更新说明不变。
- 发布后再次验证真实更新接口函数、十项设置、审计、静态摘要、别名、APK 完整摘要、公开路径和容器/守护基线：PASS。没有为本次 App 发布重启业务服务。

[Android 下载](https://www.liuhetong888.com/download?platform=android&install=1) · [新 CDN 不可变包](https://d29qsnrzc2iag0.cloudfront.net/downloads/ChatFlow-0.4.68-build2237-arm64.apk)

关键证据在 `artifacts/2026-11-04/aws-cdn-client-compat/`：`android2237-final-r2/`、`distribution/{runtime-manifest,cdn-install,cdn-check,switch}.json`、`published-2237-readback.json`。生产备份在香港 `/opt/starchat/docs/verification/artifacts/2026-11-04/android2237-release/release-backup/`，重放发布被拒绝；事务结果不明时必须先查设置和审计，不能盲目重放或回退。

## 测试的实际范围

规格、质量/安全复审通过，发布门禁 38 项通过；最终专项目标 55 项、版本合同 6 项、analyze 通过。完整 Flutter 原运行退出非零，真实日志保留；负载释放后三个失败的完整文件 64 项重跑通过，合并有效覆盖 6428 PASS、9 个既有条件 SKIP。`combined-coverage-final.json` 明确 `singleFullRunPassed=false`，不能声称单次全量命令通过。共享后端全量因资源竞争被有身份核验地中断，未记为通过；后端产品源码没有因 App 修改。

## iOS 候选与剩余门槛

同源 CI [41701039864](https://github.com/SuperJJ2333/StarChat/actions/runs/41701039864) 的设备 release 编译及无签名交接门禁已通过，模拟器原生门禁仍以 CI 最终状态为准。

无签名 IPA 已下载，GitHub artifact digest、ZIP CRC、版本/Bundle、完整 IPA 摘要及编译后新旧 CDN 字符串已本地核验。IPA SHA256 `0924fc470c40d724e7fa37a2911892e397745349c35578a2627a59f9ffa0cbd1`，35,152,605 字节；交接目录 `artifacts/2026-11-04/aws-cdn-client-compat/ios2237-signing-handoff/`。该包尚未企业回签或发布，不可直接安装。

沿用既有用户回签流程，不联系第三方。最终包仍需核验生产 APNs Team `HY9Q7Q35S5`、Bundle、签名权益、原内容差异及真机保数据升级/推送；不能用卸载清库代替升级验证。

Android 真机覆盖升级、iOS 最终回签/真机验收以及用户升级完成均未在本次自动核验中取得。旧资源删除仍受这些兼容性门槛约束；未提高最低支持版本或强制淘汰旧用户。
