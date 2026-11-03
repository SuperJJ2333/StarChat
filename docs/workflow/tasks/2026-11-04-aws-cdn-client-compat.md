# 新 AWS 账号 CDN App 兼容

用户已授权先发兼容客户端、升级后删除旧CDN。计划见 ../../superpowers/plans/2026-11-04-aws-cdn-client-compat.md。

基线37b472702311c7f161c09e6a297970135c1d2148，独立分支codex/aws-cdn-app-migration-20261104。当前阶段：准备RED用例与环境。验收、构建和发布均未完成，不宣称新版本已上线。

验收ID：C1精确新旧域名兼容；C2默认走新账号；C3源/传输/缓存边界不放宽；A1正式Android构建及签名；A2发布及平台隔离/回退；I1同源iOS候选及所需回签/设备验收；R1升级后旧CDN退役。

证据只写本目录树的 docs/verification/artifacts/2026-11-04/aws-cdn-client-compat/。生产当前Android2236，iOS版本与签名在对应发布前独立核实。源代码、旧全量失败和本次真实退出码分别保留。

RED-r2 已实际失败：新域名被拒绝、默认仍指向旧域名。初次RED另含一个无效端口断言（Dart将显式443归一化为HTTPS默认端口），已将该用例改为8443并重跑；保留原始失败，不用它证明产品缺陷。最小修正后表情相邻回归green-focused-r2通过；初次相邻失败为旧测试仍断言旧默认主机，已只同步该主机断言，其他传输/序列化/缓存断言不变。analyze退出0。

环境：Flutter3.44.9/Dart3.12.2；依赖offline恢复、锁文件SHA不变；沿用已核验原生libolm/libsqlcipher，实际SHA记录在各receipt。V盘仅本任务临时持有且每次核对后移除。当前生产新读回：Android和iOS均2236、min3不变，schema0095_wallet_source_alerts，设置模块摘要已保存CoScene迁移证据。候选冻结版本0.4.68+2237，尚未构建、签名、发布。

下一步：共享全量、版本门槛、规格和质量审查；再执行固定签名构建与可恢复发布。并行的EC2迁移由CoScene工作区执行，不修改本目录的其他功能。原生工具拒绝跨项目创建且无法登记后备目录；该Git工作树为本任务独占，路径在CoScene/work/下，原仓库工作树不动。
