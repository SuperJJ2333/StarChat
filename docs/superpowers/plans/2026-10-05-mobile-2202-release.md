# Android 2202更新与iOS签名交接计划

> For agentic workers: use subagent-driven-development for independent publication preparation and ordered review. User directly authorizes Android publication and iOS candidate handoff; do not ask again for these authorized actions.

**Goal:** 发布包含已验收修复的Android正式ARM64更新及弹窗，并交付同源iOS原始IPA供用户重签。

**Architecture:** 候选0.4.33+2202/源码265a5027，移动tree5cd2a854…与完整验收b54完全一致。沿既有轻量元数据、固定APK重建/签名、不可变上传及平台隔离发布流程；iOS仅候选交接，不企业分发或TestFlight上传。

**Spec:** docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md；docs/runbooks/mobile-delivery-workflow.md；release-metadata.md；android-apk-rebuild.md。

- [x] R1：读取生产当次设置/静态/镜像/包别名/双路分发基线，确认build2202未占用；领取仅Android元数据/包/弹窗文件，不部署业务服务或覆盖iOS配置。root拥有构建、CI、任务/计划；发布准备actor只拥有artifacts/mobile-2202-release/publish-prep。
- [x] R2：冻结移动源及生成输入；复用同源5455全测/analyze0和iOS18/26E2EE恢复CI，正式ARM64源码→Apktool2.12.1→zipalign16→固定75b31签名→独立语义/native锁/ABI门禁。沿已知cache，不删除或重定向旧junction。
- [x] R3：使用既有publisher及公共SettingService事务CAS/审计，完成当次前态、回退与平台隔离专项验证，先规格后质量/安全独立审查。更新说明拟“修复聊天搜索定位、历史消息及图片视频加载；优化登录注册提示与验证码倒计时。”；不提高最低支持build。
- [x] R4：完整性受控上传不可变APK，双路/CDN当前机制保持；先包/页面/alias，再仅Android设置及更新说明，按HEAD/小元数据验收，不公网完整回拉。未知结果先读回，不盲目重放。确认另一端十键及运行容器保持、旧包回退可用。
- [x] R5：复用自动运行37235412773 exact265a5027 iOS signed compatibility candidate；下载原始artifact并核验digest、IPA版本/BundleID、原生SQLCipher/APNs/Keychain/资源及CI门禁，交付原始IPA供企业重签。最终回签包另行检查签名身份与内容；本次无iOS分发。
- [x] R6：更新任务/恢复索引与证据，必要静态回填逐文件保全主区1372无关WIP，合入推送；最终列明Android已发布与iOS待用户签名的区别。

新工作仅包装与发布，无产品代码行为改动；若需要publisher行为变更先失败测试。已授权生产发布不是再次确认的理由。stage时间由命令/CI/实际receipt记录，不估计。
