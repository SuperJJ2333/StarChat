# iOS0.4.44+2213回签包官网渠道

- 用户提供Downloads/Telegram Desktop/9w6mt9j32dyjldij_signed.ipa，要求暂不启用更新弹窗、仅更新官网渠道。沿用本会话此前指定包直接分发偏好；不更改通用签名校验器，不声称常规回签/真机覆盖通过。
- 本次精确SHA9e5d358224a3fba64c6c5008bb0d20bf026a3fa3705a158b476ab1eb99bc8a21，37966033bytes，实际0.4.44+2213，Bundle com.liuhetong.liuhetongMobile。
- 严格身份检查FAIL：实际AppID7XL5R8V6RC.com.qiming.newhqzl299与Bundle不一致；profile生产APNs/企业分发/未过期；已签APNs production/get-task-allow false，签名Team7XL5R8V6RC。严格原包比较FAIL：App目录/可执行文件改名、额外hagoaltnteofw.dylib及资源。完整失败证据保留。诊断归一化包仅用于分析，不上传/不分发。
- 源CI3cfa40ed6bae4d91e6b702162f5d9ccbfb2a3620bcedf9021b6e53662347b952，候选2f423a34/CI37919997058通过；该结果不证明重签修改的执行安全或Apple企业验证。
- 生产基线读取当前iOS2205静态，Android2213；owns官网iOS三静态文件、唯一私有暂存及0700备份、本文/计划/索引；不写app_ios_*或Android设置，不重启容器。
- [计划](../../superpowers/plans/2026-10-09-ios2213-static-distribution.md)。状态：2026-10-09 21:42:40+08官网已发布，STATIC_IOS_DISTRIBUTION_PASS；更新设置十项及容器身份完全不变。
- 证据：docs/verification/artifacts/2026-10-09/ios2213-static。实际旧renderer RED→新publisher五项GREEN，SPEC→QUALITY PASS；上传SHA/大小匹配；服务器及工作站HTTPS验证通过。详见[报告](../../verification/2026-10-09-ios2213-static-distribution.md)。下一步仅待用户iPhone安装反馈，未启用2213更新弹窗。
- 源码回填download/manifest与公网精确一致；admin-home仅回填iOS两处标签，保留main已有提现鉴权cacheEpoch代码，未用线上旧文件覆盖该差异。
- 开始时间精确值由preflight/阶段receipt记录；未记录段不重构。
