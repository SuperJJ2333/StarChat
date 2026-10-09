# Android2205严重不可用紧急回退

- 用户授权：“立即回退0.4.33，改版本0.4.37，发布新版本，之后再解决问题”。现象：2205消息列表空、无法进入会话。
- 开始可靠时刻2026-10-08T21:26:52+08（用户消息/首次操作之前具体时刻未知）；下一步先撤回2205渠道，再打包旧代码为2206。
- [计划](../../superpowers/plans/2026-10-08-android2206-emergency-rollback.md)，新隔离worktree C:/Users/Administrator/.codex/worktrees/android-0433-rollback-2206/StarChat，源2a32683acb2d322df09ba3509c220198ab86ecf0。
- 所有权：本任务文档/证据、恢复分支版本及必要索引回退兼容文件；官网Android元数据/三设置，iOS与min3/运行服务保留。
- 验收：R1停止2205新增分发；R2原0.4.33代码0.4.37+2206固定签名包；R3保留2205已写入的数据兼容；R4官网/CDN/弹窗真实后验；R5之后独立排2205根因。
- 旧2202实际成品82193438bytes/SHA0e5255a631ceb37c6556f08caf1b7199637d85c5ea6bd050c49cf6d2f8e642c2，固定75b31；原锁ac0966cb…94ac。当前生产需当次重读，不能继承20:30快照。
- 进度：独立SPEC回退审计确认数据库version9不变、legacy未删除，但2205新写只更新normalized而旧代码只读legacy，最小一次性事务兼容桥为必要保数据边界；不能直接保证旧二进制回退无损。

## 实际状态与证据（21:56+08）

- 已完成R1：21:32:40.641953+08生产PUBLISH_PASS，Android官网/registry/latest及三键恢复2202；当前手机2205不能装旧2202，不卸载、不清数据，待2206覆盖。
- 2206源码fe9e07abc36cba22596e975fd833c6c61b531145，原2a32683a聊天行为加一次性事务bridge及版本，测试Fake真实delegate补齐。1876输入/manifest ed413255c2c7acdc5b7b107c831fe69e457b2ded7764615de1151139bbb9973d，原锁ac0966cb…94ac未改。
- 21:53:29.108+08 BUILD_2206_ARM64_PASS，28阶段真实exit0。最终APK82848798bytes/SHA fb7005f59c0a8e7a16a633a06f5cca10d30784c4508912cb442d95cefbd02436、单固定75b31签名v2/v3、version0.4.37/code2206/package com.liuhetong.mobile/ARM64/非debug。原生/DEX/manifest/完整资产及源码freeze实际检查通过，无obfuscation/R8/tree-shake。
- SOURCE SPEC→QUALITY接受；21:55:28+08实际成品SPEC接受，QUALITY正在进行；私有上传进行，尚未公开2206。
- 证据根目录：[primary](../../verification/artifacts/2026-10-08/android2206-emergency-rollback/)，构建/Flutter本地日志在上述独立worktree的同名任务目录。`delivery/artifact.json`、`source-binding.json`、`publish-prep/freeze-manifest.json`绑定身份；严禁把旧2205验收作为当前手机验收。

## 验证与保留缺口

- Bridge实际SDK RED3失败/1通过，实施后5通过；事务注入失败不留下marker/索引、重试成功、empty-ready清旧值、copying保留、4500ID完整、重开不覆盖回退后新写；原事件/密钥/token/normalized表保持。
- 全量Flutter首轮真实FAILED：5411通过、49失败、9既有skip，5:05；48初轮失败已复核修复测试环境缺目录及Fake rawQuery委托（subsets52/3、remaining2/1）。剩余日期搜索case line286在纯原2a生产源码同一环境同样失败，`context-original-baseline.json/log`为证；用户要求先恢复原版，此基线缺陷保留另查，不声称全量全部通过。新测试仅删重复import，生产候选SDK字节恢复SHA70615f…9978。
- Analyze最后21:49:22+08 exit0/0issues；初轮重复import失败保留`analyze-initial`。Python mobile307通过/23既有skip；发布helper30通过；PG6本机Docker离线skip，交易函数与原6实际隔离PG通过证据逐字等同，经独立SPEC复用，不声称本次PG新通过。全仓verify预检缺.env，未执行，不导入生产秘密。
- 本地官网metadata RED→GREEN：primary54通过/managed51通过；保留各自布局及iOS测试块，页面Android身份逆变字节完全等同。生产静态使用当次冻结当前布局，不把旧源码网页整页部署。
- 无USB真机，尚未确认RedmiK80覆盖后恢复；更新弹窗配置和实际手机收到是不同验收。

## 阶段计时

| 阶段 | 开始/结束（+08） | 结果与下一步 |
| --- | --- | --- |
| 受理/隔离/containment | 21:26:52可靠起点 → 21:32:40 | 撤回2205，保持iOS/服务；旧包不能给2205手机降级 |
| 兼容实现/测试/审查 | 截止21:49:22 | source接受/analyze0，原日期缺陷保留；full5:05和subset记录真实失败边界 |
| 冻结/正式构建/重建签名 | 21:49:58freeze → 21:53:29 | 实际28gate通过；后续metadata不得冒充新mobile源 |
| runtime冻结/成品审查/私有上传 | 21:54:16freeze；21:54:39上传起 | SPEC接受、QUALITY进行；完成上传后assemble/不可变/CDN/alias/metadata/后验 |

## 交接/回退

- containment备份 `/opt/starchat/docs/verification/artifacts/2026-10-08/android2206-containment`，trace android2206-containment-20261008；不可重复apply，先读状态。
- 新发布HKstage `/opt/starchat/releases/android2206-20261008-215100`，SGstage `/home/ec2-user/starchat-android2206-20261008-215100`，backup `/opt/starchat/docs/verification/artifacts/2026-10-08/android-2206-215100`，trace android2206-20261008-215100。
- 只Android3设置、2静态、latest-arm64、新CloudFront第10条精确HK路由，保留旧9路由/政策/iOS5设置/min3/35容器/schema。无main合并/push。
- 临时U:本任务映射新rollback worktree，完成后恢复原history-icons-performance-2204/StarChat；V:由构建driver清理；无新隧道。
- 下一步：QUALITY接受和私有5chunks完成→runtime→assemble/install→CloudFront Deployed/PublicHEAD→latest→静态/SettingService事务3审计→4项后验；闭合后独立调查2205空列表。

## 完成交付（最新22:06+08，覆盖上方阶段状态）

- R1–R4完成：21:57:21私有assemble精确SHA；21:58:23不可变包安装；21:59:20 CF Deployed/CORS/HEAD200；21:59:36 latest2206；21:59:46.536530 PUBLISH_PASS/trace android2206-20261008-215100；22:00:03.848369四项后验最后结束。实际三Android审计、服务器版路由Android/legacy2206及iOS2205、两端min3/35容器/schema/其他静态/CF旧9及policy均通过。
- 成品QUALITY接受，无阻断，`rollback-quality/artifact-quality-acceptance.md`；本地metadata测试换行纠正后54/51再过，iOS测试块实际字节一致。source-backfill/result-final.json为最终而非初轮result。
- metadata commit0392e41af0de46f4479e130b90fa422eb65ea492，所有1876移动输入hash与已构建fe9一致；仅精确Android registry JSON加到忽略downloads目录，无APK/秘密入Git。22:06:03 closure收据，U恢复旧history-icons-performance-2204，V构建driver已清，自己未开隧道；无main合并/push。
- [正式报告/安装](../../verification/2026-10-08-android2206-emergency-rollback.md)，官网/CloudFront实际200且尺寸82848798；已装2205应直接2206覆盖，不降级2202、不卸载、不清数据。
- R5另任务已启动：[2205根因调查](2026-10-08-android2205-empty-room-investigation.md)，22:01–22:04账号绑定诊断响应收到但sync处理未完、cache/list未完。22:04收到同账号2206一次成功入房/同步诊断，非全场景真机保证。具体根因/RED/修复待新任务证明，紧急回退本任务无需扩展修复。
- 墙钟：可靠开始21:26:52→生产后验结束22:00:03约33分12秒；后续文档/metadata收尾与独立调查分开，原用户消息前时段未知不补估。
