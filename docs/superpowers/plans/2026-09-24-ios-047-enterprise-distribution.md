# v0.4.7/2172 iOS 企业回签包分发计划

状态：用户于 2026-09-24 回传 `ChatFlow-0.4.7-build2172.ipa` 并明确要求分发。延续已批准的[移动交付工作流](../../runbooks/mobile-delivery-workflow.md)和[轻量发布门禁](../../runbooks/release-metadata.md)。本计划只处理同一构建的最终 iOS IPA、iOS 安装页/manifest/弹窗及审计，不重建源码或改变 Android。

2026-09-24 17:21 HKT 门禁结果：回签包的签名 App ID 不匹配 Bundle ID，且没有生产 APNs 权限。另一并发流程已在生产做了部分静态与设置写入；用户表示会暂停该流程并通知。原步骤 2–5 暂停，不可把已经存在的生产文件视作本计划成功发布。确认并发流程停止后，先重读整套状态和审计，处理部分发布；收到可安装且身份正确的回签包后才继续分发。用户接受在仅需前台可用时缺少 APNs 的限制，但后台来电与消息提醒不可据此验收。

1. 冻结回签 IPA 的原文件 SHA256/字节数，核查唯一 app 的 Bundle ID、版本/build、iPhone/iPad、iOS 下限、APNs entitlement、签名与 provisioning identity、SQLCipher/共享资产。与同源 CI 候选比对；不能把候选 CI 签名证明误用为回签包证明。若包身份或签名不适合企业分发，停止生产写入。
2. 只读核对生产两个平台设置、iOS 当前不可变 IPA/manifest/安装页/官网文案与 API/worker 健康；确定全新不可变 URL 和 0700 私有备份目录。生成单一 iOS release JSON，`prepare` 与平台/路由/旧版兼容门禁通过。
3. 顺序上传回签原字节到服务器本次私有发布目录，核对 SHA256/大小；复制成新的不可变官网 IPA。通过 HTTPS HEAD 验证公网可访问和大小，不做发布阶段的完整公网回拉验包。
4. 运行现有 `release_metadata.py publish`，先原子发布 manifest/安装页/官网版本文案并做小元数据检查，再经 SettingService 原子更新 `app_ios_latest_version`、`app_ios_latest_build`、`app_ios_download_url` 与审计。使用同一服务单独审计本版 iOS 更新说明；Android 全部设置保持原值。
5. 回读实际设置、审计、manifest、网站安装入口及 HEAD，确认 Android 不变、iOS 弹窗指向 HTTPS 安装页且最终 manifest 指向不可变 IPA。更新源码静态页面和任务证据，提交并推送文档/静态变更。

文件系统、数据库和公网缓存不是同一事务：保留旧 IPA、旧静态文件和完整设置前态。有失败或未知写入结果先重新读取实际状态/审计，确认无漂移后才恢复或重试，不盲目回滚。设备安装反馈单独记录。
