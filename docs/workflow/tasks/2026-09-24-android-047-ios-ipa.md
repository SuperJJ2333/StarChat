# v0.4.7 Android 更新与 iOS IPA 任务记录

## 恢复入口

- 目标与授权：2026-09-24 用户要求 Android 新版本更新弹窗；iOS 先提供 IPA 供用户企业签，签回后再分发。用户选择 v0.4.7；构建号 2172。
- 计划：[实施计划](../../superpowers/plans/2026-09-24-android-047-ios-ipa.md)。遵循 [移动交付工作流](../../runbooks/mobile-delivery-workflow.md)、[APK 常规重建](../../runbooks/android-apk-rebuild.md)和[轻量发布门禁](../../runbooks/release-metadata.md)。
- 当前状态：Android 正式包及更新弹窗已发布，iOS 候选 IPA 已交付待企业重签；MI 6 当前 ADB 离线，正式包未做覆盖安装烟测。
- 负责人、工作树、文件所有权：`/root` 版本/CI/生产发布/记录，`/root/android_release_audit` 独立 Android 构建产物，`/root/ios_build_audit` CI/IPA 交付只读审计；`D:\pythonProject\outsource\StarChat\.worktrees\online-room-refresh`。禁止并行编辑相同文件。源基线 HEAD `8ed729a1` + 前两任务已验证的未提交功能变更。
- 最后更新时间：2026-09-24 15:40 HKT。
- 下一条具体操作：用户取 IPA 加企业签并回传最终包；届时先确认版本、大小、Bundle ID、签名与 Keychain 连续性，再单独发布 iOS 弹窗。MI 6 连线后可补正式包保留数据覆盖烟测。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| REL-ANDROID | 0.4.6 正式客户端提示 0.4.7，点击取得固定签名 arm64 包 | 已构建 | 常规重建、固定签名、HEAD/审计/设置通过；设备未连接 | 已发布 | 待用户升级反馈 |
| REL-IOS-IPA | 提供 0.4.7/2172 IPA 供企业重签 | CI 成功、已提取 | CI 签名/APNs/SQLCipher/iPad、包内身份、本地 SHA 通过 | 仅交付 IPA，不发布 iOS 更新 | 待用户企业签回传 |
| REL-ISOLATION | Android 元数据更新后 iOS 仍 0.3.102/2144，最低支持版本与审计正确 | 已实现 | 生产回读、四条审计通过 | 已发布 Android；iOS 不变 | 无 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android 现网 | 0.4.6/2165 | 既有正式发布 | `com.liuhetong.mobile`/固定证书 | `ChatFlow-0.4.6-build2165-arm64.apk`，SHA256 `60826c925134fa5d07dcba6a4829d6a463ba9bbf37446650000d0855634d871e` | 2026-09-24 只读回读 |
| iOS 现网 | 0.3.102/2144 | 既有企业分发 | 现有 iOS 入口 | 保持不变 | 2026-09-24 只读回读 |
| API/worker | c41dfffc/90696ffa | 前一任务 | 已上线 | [前一任务记录](2026-09-24-me-invitations-moments-interactions.md) | 2026-09-24 |
| Android 新版 | 0.4.7/2172 | `e7ba46a43ab8046e9ffe932827f20ea59820e996` | `com.liuhetong.mobile`/固定证书 `75b31c66…` | [公网 APK](https://www.liuhetong888.com/downloads/ChatFlow-0.4.7-build2172-arm64.apk)，80,915,486 字节，SHA256 `7741e45a9c2c8b70a0ad46977a657f96b86f9500f7a1fa4bd04155e08906c773` | 2026-09-24 15:33 HKT，弹窗已发布 |
| iOS 待重签候选 | 0.4.7/2172 | 同一移动端源码提交 `e7ba46a4…` | `com.liuhetong.liuhetongMobile`/当前 Apple Distribution 候选签名，待企业重签 | `D:\pythonProject\outsource\StarChat\docs\verification\artifacts\2026-09-24\android-047-ios-ipa\ios\ChatFlow-0.4.7-build2172-enterprise-resign-candidate.ipa`，60,809,306 字节，SHA256 `4ee3a233e66b0349666e43adae7a016ead3e2bef2dfd8e45c9840cda3c924767` | [CI run 35969111874](https://github.com/SuperJJ2333/StarChat/actions/runs/35969111874) 成功；未分发 iOS |

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 前态/方案与版本核对 | 2026-09-24 15:00 HKT | 15:14 HKT | 主动/并行只读 | Android/iOS/根 | 现网设置回读与用户版本选择 | 冻结源码 |
| 候选测试、审查与提交 | 15:14 HKT | 15:21 HKT | 主动/工具 | 根/独立审查 | Flutter 4120/9、analyze0、16 版本/发布测试，提交并推送 `e7ba46a4` | 双端构建 |
| 双端构建与包验证 | 15:21 HKT | 15:32 HKT | CI/本机构建，含已知插件修正 | Android/CI | Android `BUILD_2172_PASS`、iOS CI run35969111874 成功 | Android 发布、IPA 交付 |
| Android 上传与发布回读 | 15:30 HKT | 15:34 HKT | 工具/生产 | 根 | 私有上传 SHA、PUBLISH_PASS、HEAD200、审计4条、iOS不变 | IPA 提取 |
| IPA 取回及交接验证 | 15:34 HKT | 15:40 HKT | 下载/验包 | 根 | ZIP digest、IPA SHA/Info.plist/资源与 CI 一致；复制到项目工件目录 | 待用户企业签 |

## 交接与回退

- 已确认：MI 6 的 0.4.10 Debug 因版本名较高，不应预期显示 0.4.7 弹窗；正式 0.4.6 可按版本比较获得更新。
- 待办：MI 6 当前 `adb devices -l` 空列表，正式 2172 未真机覆盖安装；用户企业签回传及其后 iOS 分发。自动化通过不代替用户真机体验。
- 已发布与仅候选：Android 0.4.7/2172 已发布弹窗；iOS 0.4.7/2172 只是 Apple Distribution 候选 IPA，线上 iOS 仍 0.3.102/2144。
- 生产备份/恢复：服务器私有 `/opt/starchat/releases/android-047-2172-20260924/` 保存上传包、release/artifact、旧别名目标、前后设置；`/opt/starchat/docs/verification/artifacts/2026-09-24/android-047-2172/` 为 0700 元数据备份及审计对应 trace。旧不可变 APK 保留。故障时先核对当前别名、设置和审计，再按备份原子恢复别名及通过有审计 SettingService 修正本平台设置；发布器拒绝 build 回退，不能盲目重跑旧 release JSON。
- 运行中的 CI/命令：CI run 35969111874 已成功；无持续隧道需要留存，临时 loopback SOCKS 待本任务关闭。
