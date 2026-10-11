# IM可靠性修复与实际发布结果（2026-10-11）

本报告补充[九项端到端评审](2026-10-11-e2e-architecture-performance-review.md)，不改写初始评审的证据时点。用户已授权修改、重启和部署；根因复现、返工、源码及时间见[执行台账](../workflow/tasks/2026-10-11-im-reliability-implementation.md)。没有设备回执和分母的到达率、功耗、OOM率、帧率及P50/P95/P99仍未知。

## 实际交付

**Android正式已更新为0.4.45+2214**：[不可变安装包](https://www.liuhetong888.com/downloads/ChatFlow-0.4.45-build2214-arm64.apk)。com.liuhetong.mobile、ARM64、minSDK24/targetSDK36；73,336,097字节，SHA256 `575e24f4c841ed2388311ba19c06e23623838022ed2a438df6c56642436af614`，固定75b31签名；源码e9d297/mobile manifest f7a9。常规源码构建、Apktool重建、P16 ZIP对齐、签名及28个唯一步骤exit0。没有最终ARM64实体手机安装/覆盖升级结果。

iOS正式仍0.4.44+2213。同运行时2214未签名IPA已生成：34,964,622字节，SHA `0fad8d42bcab9439ff35951e44b7f0df6b284660200b23b576f6d12ce72a4d3b`；29生产插件/46框架、原生20PASS。企业签名身份、保数据升级及真实APNs/Focus待验，未发布unsigned包。

worker有界活跃续租于10:39:52–10:40:17 UTC上线，镜像abda33f8、容器db5d65ff，五个源码SHA/schema0095/其他容器保持。独立结构后验通过；原有限样本一条warning保留。后续结构化枚举定位为资金监控WAITING/BALANCE_UNSTABLE/RECONCILIATION_PENDING，业务状态待单独领域复核，不声称无告警。外部handler仍遵循至少一次及业务幂等；整进程暂停/超过续租上限不能据此保证外部动作恰好一次。

## 九项覆盖与剩余风险

| 项目 | 本轮修复/措施及证据 | 剩余风险与验证 |
| --- | --- | --- |
| 1 Android后台 | FGS超时原生释放/owner边界/恢复；源码及JVM专项、共享回归、2214成品通过 | P1：主流ROM/Doze/Standby/省电/锁屏/回收长测；厂商审核获批后配置。存活率、到达率、功耗未知 |
| 2 通知与声音 | Getui跨房节流与事件去重分离、绑定远端对账/429期限、Sygnal IANA定时DND；桥接51/网关11及生产证据 | P0：iOS最终成品身份/旧用户连续性；P1：APNs/权限/Channel/声音/Focus/DND/点击去重及OEM实体设备矩阵。服务HTTP成功不等于显示 |
| 3 收发链路 | 跨房公平、实际settle额度、离页owner、持久发送/同txid恢复；worker逐条领取、代次fence、有界续租 | 源码/真实PG与镜像证据；P1：弱网/离线/切网/多端/热点成功率、顺序和状态分位。未重放历史金融DEAD或修改财务handler |
| 4 UI与网络 | 正文有界分页/checkpoint、维护锁不跨网络等待、worker哈希/大seed预览、准备调度与取消修复；最终共享全量通过 | P1：release手机帧时间/ANR/点击/离线操作实测；首次历史索引仍有O(N)阶段 |
| 5 内存稳定性 | 逻辑活动预算、预检、调度前不预占预算、共享flight/最后消费者取消修复、metadata/Matrix SQLCipher初始化顺序统一 | 真DLL双isolate RED→GREEN、Android真实3例、iOS SQLCipher6例在20项内；P1：192MiB预算不是RSS上限，Native/图片/FD/OOM/长时泄漏待profile |
| 6 媒体与存储 | API媒体同步IO退出事件循环（候选15项/部署）；能力与预算交集预检、持久附件/原件恢复、缓存索引 | P1：低空间/杀进程/真实大媒体/失败恢复；P2：编解码、缩略图/CDN命中及流量收益待量测。普通附件现上限48MiB，图片更低 |
| 7 架构与网络 | 恢复鉴权固定8082且fail-closed；实际installed Consumer/组合协议守卫；日志轮转、有界采样器及证据绑定；均有隔离与上线记录 | P1：同宿主失败域、冗余入口、RPO/RTO恢复演练、7–14天SLO；P2：核心类拆分/SDK补丁维护。E2EE/财务权威保持 |
| 8 目录与归档 | 缓存增量索引、坏索引/扫描失败拒绝不安全淘汰、原生目录/链接防护、iOS备份/保护策略、唯一待发原件保留；证据分任务归档 | P1：iPhone保护/备份、全沙盒空间和异常残留实测；P2：旧工作树/证据保留期限及可恢复归档。未删除别人目录、旧包或生产日志 |
| 9 启动缓存 | 启动任务有界/延后、热历史块索引、SQLCipher首次打开顺序；真实入口专项/共享/原生验证 | P1：手机冷/温/热启动阶段分位与缓存命中；冷索引仍O(N)，不声称已变快。Windows合成热查询改善不当作手机指标 |

## 已量化的门禁范围

- 最终Flutter **5958 PASS / 9 SKIP / 0 FAIL**，analyze **0 issues**；边界 **401 PASS / 1条件SKIP**。原r2失败保留，不重复累加专项。`scripts/verify.ps1`因缺.env未完整执行，不称全仓PASS。
- Android native **3例通过**，仅API28 x86_64专用fixture；不是最终ARM64真机、16KB或Doze验收。iOS native **20 PASS / 0 SKIP / 0 FAIL**；旧文件保护4PASS/4能力SKIP另存，不混为手机通过。
- 最终Android包 **28唯一步骤exit0**；13个非libapp原生库与2213相同。libcrypto四个PT_LOAD仍4KiB、16KiB congruence失败，静态检查原始exit1保留。10个RELRO末尾模数观察中仅crypto有后续可写LOAD几何交集；其他九项不据此声称已复现崩溃。ZIP16KiB对齐不能替代ELF/设备验证。
- 分发9个阶段全部PASS，CF新增一个精确路由并Deployed/HEAD/CORS通过；仅三个Android设置有审计，iOS2213/minima3/URL保持。工作站四项HTTPS通过：精确metadata、CDN HEAD/长度/CORS、ready200、未鉴权更新401；没有完整包公网回拉。
- worker实际候选默认入口 **70 PASS / 1 PG配置SKIP**，三唯一镜像协议通过；源真实PG另存。实际切换settled PASS、独立结构后验通过；有限warning已定位资金监控状态但业务待复核，不隐去，不当作生产慢handler/容量SLO实测。

[原生页大小风险及受控修复门禁](2026-10-11-android-native-page-alignment.md)与[实际包独立审查](artifacts/2026-10-11/android2214-final-independent-review/quality-security.md)保留16KB P1。更换加密实现须相应ADR/领域/安全审查、已知向量、旧数据兼容及4KiB/16KiB实跑，不能直接塞入实验库。

原独立10行窗口有1条warning；后续窗口扩大后固定枚举读回WAITING两条及BALANCE_UNSTABLE/RECONCILIATION_PENDING各一条（statusOK只表示该来源运行状态，不能代表资金监控或对账健康），计数不可跨窗口比较。证据见[脱敏枚举](artifacts/2026-10-11/im-reliability-release/worker-warning-static-enums-r3.json)。本次没有改变财务模块/配置或消除相关业务状态，也不证明它们此前已出现；不读取资金明细、不为验收调阈值或重放事件。

## 后续优先级与缺失资料

- **P0**：最终回签IPA、旧安装身份/Keychain基线；严格签名/权益/topic核对；保留旧数据iPhone覆盖升级、聊天/启动/APNs/CallKit。新unsigned构建未关闭旧成品身份缺口。
- **P1**：单独复核资金监控等待/余额稳定性/待对账状态，保持既有财务fail-closed与审批/审计；受控修复crypto16KB；绑定最终SHA的ARM64/iPhone与ROM/权限/Doze/弱网/低空间/回收矩阵；厂商获批后逐通道接入；采集设备回执、链路分母/延迟/内存/功耗及7–14天资源/队列SLO，验证冗余和恢复。原评审建议数值仍是验收目标，不能当作实测。
- **P2**：首次历史索引/提及元数据、编解码/CDN效率、全应用空间统计、旧材料可恢复归档、架构拆分和构建弃用advisory治理。

需补充最终签名及旧设备资料、受控测试账号、设备/ROM/系统/页大小/权限状态、发送→存储→设备ACK/显示的脱敏trace和分母、release性能profile/ANR/OOM/能耗、大媒体/磁盘/CDN样本、长期容量与恢复演练报告。缺口只阻断对应结论，不编造数据或突破系统限制。

## 证据入口

- [共享最终摘要](artifacts/2026-10-11/im-reliability-release/shared-final-r3-summary.json)、[成品双审](artifacts/2026-10-11/android2214-final-independent-review/release-review.json)。
- [实际分发审计](artifacts/2026-10-11/android2214-release/final-package-e9d297-r3/execution/im2214-e9d297-r3-20261011/audit.json)、[两文件回填](artifacts/2026-10-11/im-reliability-release/source-backfill-result-r3.json)、[工作站公网](artifacts/2026-10-11/im-reliability-release/workstation-public-final-r3/receipt.json)。
- [worker实际切换](artifacts/2026-10-11/im-reliability-release/worker-active-lease-deployment-r3.json)、[独立后验](artifacts/2026-10-11/im-worker-active-lease-post-cutover-audit/REPORT.md)。

- [发布后独立文案/回执复核](artifacts/2026-10-11/android2214-final-independent-review/post-publication-review.md)、[最终本地一致性](artifacts/2026-10-11/im-reliability-release/final-consistency-r3.json)。
