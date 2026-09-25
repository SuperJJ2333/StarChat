# v0.4.7 Android 更新与 iOS IPA 任务记录

## 恢复入口

- 目标与授权：2026-09-24 用户要求 Android 新版本更新弹窗；iOS 先提供 IPA 供用户企业签，签回后再分发。用户选择 v0.4.7；构建号 2172。
- 计划：[实施计划](../../superpowers/plans/2026-09-24-android-047-ios-ipa.md)。遵循 [移动交付工作流](../../runbooks/mobile-delivery-workflow.md)、[APK 常规重建](../../runbooks/android-apk-rebuild.md)和[轻量发布门禁](../../runbooks/release-metadata.md)。
- 当前状态：构建准备；正式 Android 现网 0.4.6/2165，iOS 现网 0.3.102/2144，MI 6 内部 Debug 0.4.10/2171。
- 负责人、工作树、文件所有权：`/root` 版本/CI/生产发布/记录，`/root/android_release_audit` 独立 Android 构建产物，`/root/ios_build_audit` CI/IPA 交付只读审计；`D:\pythonProject\outsource\StarChat\.worktrees\online-room-refresh`。禁止并行编辑相同文件。源基线 HEAD `8ed729a1` + 前两任务已验证的未提交功能变更。
- 最后更新时间：2026-09-24 15:13 HKT。
- 下一条具体操作：同步 0.4.7+2172、完成候选门禁并冻结提交，然后并行构建两端；Android 后续按发布手册更新生产弹窗。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| REL-ANDROID | 0.4.6 正式客户端提示 0.4.7，点击取得固定签名 arm64 包 | 待构建 | 待验 | 待发布 | 待用户升级反馈 |
| REL-IOS-IPA | 提供 0.4.7/2172 IPA 供企业重签 | 待 CI | 待验 | 不发布 iOS 更新 | 待用户企业签回传 |
| REL-ISOLATION | Android 元数据更新后 iOS 仍 0.3.102/2144，最低支持版本与审计正确 | 待发布 | 待生产回读 | 待发布 | 无 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android 现网 | 0.4.6/2165 | 既有正式发布 | `com.liuhetong.mobile`/固定证书 | `ChatFlow-0.4.6-build2165-arm64.apk`，SHA256 `60826c925134fa5d07dcba6a4829d6a463ba9bbf37446650000d0855634d871e` | 2026-09-24 只读回读 |
| iOS 现网 | 0.3.102/2144 | 既有企业分发 | 现有 iOS 入口 | 保持不变 | 2026-09-24 只读回读 |
| API/worker | c41dfffc/90696ffa | 前一任务 | 已上线 | [前一任务记录](2026-09-24-me-invitations-moments-interactions.md) | 2026-09-24 |

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 前态/方案与版本核对 | 2026-09-24 15:00 HKT | 进行中 | 主动/并行只读 | Android/iOS/根 | 现网设置回读与用户版本选择 | 冻结源码 |

## 交接与回退

- 已确认：MI 6 的 0.4.10 Debug 因版本名较高，不应预期显示 0.4.7 弹窗；正式 0.4.6 可按版本比较获得更新。
- 待办：最终双端构建与审计、Android 发布及 iOS IPA 交付。
- 已发布与仅候选：目前尚未发布本版；iOS 本次只交付候选。
- 生产备份、恢复和漂移检查：待发布时填写。保留旧不可变 APK、旧 latest-arm64 目标和双端设置 0700 前态。
- 运行中的 CI/命令：待填写。
