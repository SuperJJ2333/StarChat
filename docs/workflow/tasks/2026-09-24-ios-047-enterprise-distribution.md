# v0.4.7/2172 iOS 企业包分发任务记录

## 恢复入口

- 目标与授权：用户先前约定回传企业签 IPA 后分发，本轮于 2026-09-24 指向 `D:\pythonProject\outsource\StarChat\docs\verification\artifacts\2026-09-24\android-047-ios-ipa\ios\ChatFlow-0.4.7-build2172.ipa` 并明确要求“请你进行分发”。不重建 iOS，不改 Android 更新。
- 计划：[实施计划](../../superpowers/plans/2026-09-24-ios-047-enterprise-distribution.md)；[验证记录](../../verification/2026-09-24-ios-047-enterprise-distribution.md)；依据[轻量发布门禁](../../runbooks/release-metadata.md)与[分发职责](../../runbooks/app-release-deployment.md)。
- 当前状态：本任务只读审计完成，本任务未执行发布。另一并发流程已将回签 IPA、manifest、下载页及 iOS 版本设置部分写入生产；用户于 2026-09-24 表示会暂停该流程并通知本任务，尚未收到暂停完成通知。回签 IPA 的签名 App ID 与 Bundle ID 不一致，暂不能作为可安装的正式更新交付。
- 负责人/所有权：`/root` 持有发布记录、静态源码、服务器写入及任务证据；`/root/ipa_audit` 和 `/root/ios_release_audit` 只读并行复核。工作树 `D:\pythonProject\outsource\StarChat\.worktrees\online-room-refresh`，起点 HEAD `04f2f97a04d7a615b9caaf999883131e0987a7b8`、跟踪文件干净。
- 最后更新时间：2026-09-24 17:22 HKT。
- 下一条操作：等待用户明确确认并发发布已暂停；然后重新读取完整生产状态和审计，以最新状态为基准处理错误的部分发布。有效回签包仍需匹配 `ZXB3TS7QD4.com.liuhetong.liuhetongMobile`，并经安装验证；若要求后台来电和消息提醒，还需生产 APNs 权限。

## 验收台账

| ID | 场景及预期 | 包/源码证据 | 生产证据 | 未验收 |
| --- | --- | --- | --- | --- |
| IOS-SIGN | 回签 IPA 是 0.4.7/2172，企业分发身份与既有 bundle/推送能力连续 | Bundle ID/version/build 正确；签名及 profile 的 `application-identifier=ZXB3TS7QD4.cn.edu.buaa.bhpan.fileProvider` 与 Bundle ID 不匹配；签名和 profile 均无 `aps-environment` | 不适用 | 失败；未做真机安装 |
| IOS-OTA | 官网可下载不可变 IPA，manifest/安装按钮匹配，旧入口兼容 | 本任务没有运行 prepare/check | 并发流程上传了相同 SHA 的 IPA，manifest 与下载页指向 2172；签名门禁未通过 | 部分发布，不能验收 |
| IOS-POPUP | iOS 更新弹窗显示新版本及说明，点击 HTTPS 安装页 | 本任务未发布 | 17:21 HKT 设置已为 0.4.7/2172；本次变更没有发现相应 app_setting 审计，且 admin-home.js 仍展示旧版 | 不能验收 |
| ANDROID-ISOLATION | Android 仍 0.4.7/2172、原 URL/说明/最低支持值不变 | 只读快照 | 17:21 HKT Android 仍为 0.4.7/2172 | 发布后复核待做 |

## 版本和证据

| 项目 | 当前事实 | 文件/SHA/位置 | 发布状态 |
| --- | --- | --- | --- |
| 用户回签 IPA | 文件 61,434,769 字节 | SHA256 `12258dac74ace99c7d462b5a50ec99122b5d45861e753715e27c26fc6c0b53f2`，上述用户路径；签名 App ID 不匹配，无 APNs | 并发流程已上传到 `/opt/starchat/frontend/downloads/ios/ChatFlow-0.4.7-2172.ipa`，本任务未写入 |
| 同源 CI 候选 | 0.4.7/2172，来源提交 `e7ba46a4…` | 60,809,306 字节，SHA256 `4ee3a233e66b0349666e43adae7a016ead3e2bef2dfd8e45c9840cda3c924767` | 候选已交接，不能作最终包签名证明 |
| 生产 Android | 0.4.7/2172 | 不可变 `ChatFlow-0.4.7-build2172-arm64.apk` | 保持 |
| 生产 iOS | 17:21 HKT iOS 设置 0.4.7/2172，静态 manifest 和下载页已指向回签 IPA，admin-home.js 仍旧版 | manifest SHA256 `62c754a3d3cc6ae998a0fd29cfd1b8f860e4e62709ca2e3c03a886b366331084`；下载页 SHA256 `6154d712d8fff891bf78e37453cfe699ccc703f977504aa4a0d4269bff73f710` | 并发流程部分发布，无对应设置审计；本任务未发布 |

## 阶段计时

| 阶段 | 开始（HKT） | 结束 | 类型/证据 | 下一步 |
| --- | --- | --- | --- | --- |
| 回签包/现网并行审计 | 2026-09-24 16:25 | 2026-09-24 17:21 | 本地/生产只读；包 SHA、签名权益、静态 SHA、设置/审计回读 | 等待并发流程暂停与有效包 |
| 状态记录与链接核对 | 2026-09-24 17:22 | 2026-09-24 17:30 | 新增分发计划/验证/任务记录，更新当前状态；新增链接核对及 `git diff --check` 通过 | 等待并发流程暂停与有效包 |

## 交接与回退

- 用户回传即为本次分发授权；签名身份仍要依据包和交接事实核对，不臆测重签工具。
- 并发流程在本任务只读审计期间修改了生产，用户表示会暂停并通知；收到明确暂停通知前不执行任何生产写入。旧 manifest 的现场备份 SHA256 为 `a7b89bf847cdfe413c9ad2cb50eab3ffa897d5c363e472aa92cab5c2bfc4de6f`，旧下载页原字节已保存在 `docs/verification/artifacts/2026-09-24/ios-047-enterprise-distribution/preprod/`。回退须先重新读取完整设置与审计并核对静态 SHA，不能用审计前的旧前态盲写。
