# Emoji direct send and warm resume

用户三项优化要求及持续debug交付已完成。首次明确基线2026-10-09T08:59:54+08，准确更早开始未知；完成2026-10-09T09:59:41.461375+08:00。
Managed tree W: = C:/Users/Administrator/.codex/worktrees/android2205-sync-deadlock/StarChat，b09bf2f2+既有WIP，无提交/合并。源在该树，交付证据同步主工作区。
[计划](../../superpowers/plans/2026-10-09-emoji-direct-send-warm-resume.md)、[报告](../../verification/2026-10-09-emoji-direct-send-warm-resume.md)。S1–S7 PASS；发送41+4/生成1、warm19、Moments9、native5、全量5730/9、边界377/23、Appanalyze0、SPEC→QUALITY及26重建gate通过。
保留数据覆盖5556 com.liuhetong.mobile.debug 2210→0.4.42+2211，75b31签名，SHA49e3189376cab3d42c686d5007b9264d915641ae124a474726da3e65dad70bbe。56私有资源SHA检查，启动异常计数0。热cache64/4MiB/8codec/30s；panel10次全部warm首帧，关闭不tick。冷加载仍需解码，高DPR/超期/压力可淘汰。
本次失败/返工完整保留：S3原SPECFAIL修复、IME注册/客户端时序、brace info、旧manifest拒绝覆盖、32→64导致早期全量取消；第一次完整5727/9/3fail的三个测试夹具已修正并双审，最终5730/9/0；构建旧版本正则预检失败已修正并复检。没有虚称取消或失败通过。原生产品输入不变，fixture-only-native-reuse.json绑定复用依据。
正式2206/iOS2205/候选2209/弹窗不变，未public分发。真机profile和原巨大历史首次查询缺口仍保留。
下一可执行步：收集用户模拟器反馈；真机可连后profile，不自行发布。
