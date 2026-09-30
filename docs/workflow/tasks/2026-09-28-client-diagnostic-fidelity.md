# 客户端诊断保真与定位

## 恢复入口

- 目标、授权与边界：用户要求据 2026-09-28 真实日志检查结果修复网络超时、同步、媒体、局部卡顿记录，确保 version/platform 等定位字段。授权范围是诊断修复及按既有顺序交付；旧设备和离线丢失不可伪称 100% 留存。
- 关联计划：[客户端诊断保真与定位计划](../../superpowers/plans/2026-09-28-client-diagnostic-fidelity.md)；基线[用户诊断检查](../../verification/2026-09-28-user-diagnostics-review.md)。
- 当前状态：兼容接收端 14:34+08 先发布；Android `0.4.21+2190` 已固定身份重建、验签并于 15:26+08 完成正式发布；16:05+08 又将接收端单行写入补丁作为现网镜像的一文件覆盖发布并验收，新镜像 `sha256:2b847ef7…89a63`。香港直连与新加坡 CDN 同一 SHA，下载页维持网络择优。iOS `0.4.20+2189` 尚待 macOS 构建及企业重签，未包含本批新诊断。
- 负责人、工作树、文件所有权、源码 commit：`/root` 集成、文档、AppHome 与 Matrix 看门狗闭合回调；`/root/network_diagnostics_gap` 采集器/报告及 infra 测试；`/root/sync_media_gap` Matrix 同步/媒体及测试；`/root/frame_receiver_gap` 诊断 spool/帧/接收协议及测试；`/root/diagnostic_triage` 新服务器侧汇总工具及测试。托管工作树 `C:\Users\Administrator\.codex\worktrees\diagnostic-fidelity\StarChat`，基线 `b9eca8a419614112b085439445b7fd031027a740`，从现行 MAIN 精确叠加 411 个源码/测试文件作为当前未提交产品状态；主目录旧改动保留。
- 最后更新时间：2026-09-28T16:36:00+08:00。
- 下一步：继续观察 Android 2190 的真实超时、同步和媒体故障批次及丢失计数，做真机安装/弱网/卡顿复验；iOS 先把本地诊断源码与远端安全整合并推到可触发 macOS CI 的分支，构建 App Store 签名候选，再经既有企业渠道重签/分发。首批 2190 帧/网络事件已到达，不能代替尚未出现的故障路径验收。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| N1 | 生产形状网络超时及 version/platform/UUID 可采集，失败尽早 spool | 已实现 | 网络采集/报告 124 项通过；生产形状 RED/GREEN | 接收端、Android 2190 已发布 | 旧客户端覆盖有限；待 2190 真实样本 |
| S1 | 同步等待阶段及旧版 spool 原版本归属正确 | 已实现 | 同步/媒体 85 项、看门狗 26 项通过 | 接收端、Android 2190 已发布 | 需升级路径与真机验证 |
| M1 | 媒体可证明错误闭合分类，unknown 不猜测 | 已实现 | 同步/媒体聚焦 85 项通过 | 接收端、Android 2190 已发布 | SDK 不暴露的阶段仍未知 |
| J1 | 前台有效卡顿窗口有安全主标签和预算/极值 | 已实现 | 核心诊断 122 项；最新 spool/chat/frame 61 项、analyze 通过 | 接收端、Android 2190 已发布 | 正式包启用 `CHATFLOW_PERFORMANCE_METRICS=true`；主标签不等于子页，待真机 |
| C1 | 有界驱逐/拒绝可见，旧接收兼容 | 已实现 | 接收端 68 项；64KiB/503/202/422专项；纯 watchdog+loss 双 422 RED 后修复并通过 | 接收端、Android 2190 已发布 | 离线/进程杀死/日志轮转非强留存；旧接收端拒绝 loss 时无法远端上报该缺口 |
| T1 | 服务器侧隐私安全的版本/阶段/主标签/丢失去重汇总 | 已实现 | triage/接收端 115 项、追加接收端/网络/triage 261 项通过；线上安全聚合复跑 | 私有汇总 v2、API 单次写入均已发布 | 原始日志留在服务器；污染行有恢复/不完整标记；checkpoint/expired 仅给总遗漏数，细网络请求由独立报告处理 |

## 版本与证据

2026-09-28 14:47:36+08 从生产 `SettingService` 实时复核 Android `0.4.19+2188`、iOS `0.4.20+2189`，记录于 `android-release/production-versions-before-build.json`；发布前还需复核。生产 API 在本任务期间先由 `e304...` 到 `261f...` 再到 `c119...`，已弃用旧候选，基于 `c1191a89...` 构建仅一接收文件的新镜像 `25fe7318...`。2026-09-28 14:34+08 切换仅 business-api；14:36+08 验收通过：实际配置/挂载/网络不变、另 28 个容器不变、schema `0091_moment_video_posters`、严格 TLS live/ready 200 与匿名受保护入口 401、新 API 0 error/traceback；未发送真实已鉴权请求，未执行数据库迁移。服务器私有发布记录 `/opt/starchat/releases/client-diagnostic-fidelity-20260928-publish/release.json`。所有本任务非 Git 验证产物置于 `docs/verification/`。

线上 24h 日志通过服务器本地 triage 汇总：旧 Android 2188 的 10 个诊断批次均接受，0 拒绝；3705 行非诊断服务日志被忽略，非截断，`coverage_incomplete=false` 仅表示已接受批次无检测到的丢失，不代表所有真实事件都送达。仍有 `request_timeout` 25、`server5xx` 6 等旧版失败；尚无新版 frame_windows/diagnostic_loss，不能从旧日志推断新客户端效果。原始日志未下载到工作站。

Android 2190 正式包于 15:03:24+08 完成：源码冻结 1793 文件/SHA `6b5ac7ac…41dd`，最终 APK `81,701,918` 字节/SHA256 `7126f4ca…3423`，包名 `com.liuhetong.mobile`、ARM64、同一固定签名证书 `75b31c66…1fff`、v2/v3、zipalign、非 debuggable，常规 DEX/资源/manifest 重建后独立再解包比对通过。首轮缺 `VideoCompressFailure` 是任务工作树遗漏并行插件变更；补 22 个插件源文件及 5 项测试后第二轮发现 MainActivity 旧锁屏 manifest，按 MAIN 语义差异补 22 个源文件，最终 164 项 Flutter 聚焦测试通过。失败尝试与最终产物均保留在 [Android 发布证据](../../verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/README.md)。无 ADB 真机安装验证。

发布前实时读取 Android2188/iOS2189；香港不可变 2190 包与新加坡私有 S3/CloudFront 精确对象 SHA/长度相同。新加坡首次执行时发现 2190 缺旧 2188 精确缓存行为所携 CORS/Range 设置，已通过 CloudFront ETag CAS 复制旧行为到 2190 精确路径，等待 `Deployed` 后 206 Range、字节一致和 CORS 通过。香港 ARM64 别名原子切换到 2190，旧 2188 仍在；设置先以标准发布器更新 Android 三字段，再以网络发布器仅将 APK URL 恢复到既有网络择优下载页。发布后读回 Android `0.4.21+2190`、iOS 仍 `0.4.20+2189`；新旧香港直连/新加坡 CDN 的 HEAD 均 200，静态资产哈希与接收端镜像一致，发布校验 `ANDROID_2190_PUBLICATION_VERIFIED`，未下载 APK body、未用真机。标准/网络发布私有备份分别为 `/opt/starchat/docs/verification/artifacts/2026-09-28/client-diagnostic-fidelity-2190-standard-20260928T072630Z` 和 `…-network-20260928T072644Z`；元数据见[正式发布输入](../../verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/release-network.json)。

15:35+08 再跑生产 24h 服务器内聚合：扫描 21033 行、53 个接受批次（Android2188 和 iOS2189/2173）、1 个拒收诊断行、无截断或样本冲突，故 `coverage_incomplete=true`；Android2188 已接受批次有 `request_timeout` 126、`server5xx` 7，不代表新版 2190。尚无 Android2190 真实批次，也没有新帧窗口或丢失样本。服务器内结构检查确认唯一拒收发生于 14:57:18+08、2190 发布前，旧 Android2188 的完整有效诊断 JSON（20 个操作）后拼接了非 JSON 文本；原始 Docker stdout json-file 已受污染，不是 `docker logs` 合并造成，尾部来源未知。既有 `print` 的 JSON 与换行分开写入是可复现风险。

15:55:35+08 将仅服务器私有聚合工具 `05f44e3e…4acd` 原子更新到 `b54a156e…1f84`，保留旧版 0600 备份，未重启 API/客户端。新工具只恢复完整且通过现行 DTO 的 JSON 前缀，未知尾部不解析、不导出，并同时保留 `rejected_lines=1`、新增 `contaminated_lines=1`/`unparsed_suffix_lines=1` 和 `coverage_incomplete=true`。15:55+08 滚动 24h 复跑扫描 24155 行、接受 70 批（其中含污染行前缀）、无 Android2190 样本；[安全聚合](../../verification/artifacts/2026-09-28/client-diagnostic-fidelity/server-publish/triage-v2-24h.json)和[私有工具切换](../../verification/artifacts/2026-09-28/client-diagnostic-fidelity/server-publish/triage-v2-publication.json)已保存。受污染行同时计入 accepted 与 rejected，两数不能相加作为物理行数。

16:04:17+08 候选 `sha256:2b847ef70e0257f4ba52e663812112d7664016ff427d454c32630da1b0c89a63` 准备完毕：基于当时现网 `25fe…`，整个镜像仅 `/opt/business-api/app/api/client_diagnostics.py` 的 SHA 从 `795e…` 变为 `b5b9…`，网络隔离/只读 Linux 测试与导入 exit0，29 容器不变；16:04:38+08 preflight 冻结 Compose/29容器/0091。16:05:17–29+08 仅 business-api 切换，16:05:40+08 验证：API 配置/挂载/网络、另 28 容器和 schema 不变，严格 TLS live/ready200、诊断及账号安全匿名401，新错误/traceback0，未用真实账号/迁移。工作站经自有临时 SOCKS 再验 TLS 200/200/401，隧道关闭；第一次工作站探针仅因 PowerShell 参数组装错误失败，未反映服务异常。发布记录见[服务端核验](../../verification/artifacts/2026-09-28/client-diagnostic-fidelity/server-log-integrity/release-verification.json)，服务器私有 `/opt/starchat/releases/client-diagnostic-log-integrity-20260928-publish-r1/` 保留 0700 快照和受控回退。新镜像下[服务器内聚合](../../verification/artifacts/2026-09-28/client-diagnostic-fidelity/server-log-integrity/triage-post-cutover-24h.json)已运行，最初接受 2 批旧 Android2188、0 拒收；新容器日志从切换后开始，不能把这个滚动窗口当完整 24h。发布后[Android 2190 再核验](../../verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/post-receiver-publication-readback.json)依然通过。

接收端新写入通常只需一次 stdout 写入完整 JSON+换行，短写可续写；现网 2 worker、`PIPE_BUF=4096`，允许最大 16KiB 请求，大批次跨进程不能绝对保证原子性。独立规格/质量安全复核无阻断，并明确这一限制；服务端日志轮转、客户端离线/进程终止仍不保证每次事件远端永久留存。

16:23:54+08 只读随访：API 健康/0重启、另28容器原身份，自切换以来5747行服务日志无 ERROR/CRITICAL/traceback，见[跟进健康证据](../../verification/artifacts/2026-09-28/client-diagnostic-fidelity/server-log-integrity/followup-health.json)。新容器另一轮诊断聚合接受 11 批旧 Android2188/iOS2189、0污染/拒收，但 `conflicting_operations=1`、`identity_ambiguous=true`，仍无 2190 样本。[服务器内闭合结构复核](../../verification/artifacts/2026-09-28/client-diagnostic-fidelity/server-log-integrity/triage-operation-conflict-structural.json)将冲突定位为 16:18+08 的旧 iOS2189 两个成功 `api_request` final 复用同一未索引操作身份、仅阶段时长与总时长不同；无法从日志判定 ID 意外复用还是较晚修订，聚合器隔离两者并标记下界。它不是请求失败或接收拒绝，需在新版本有真实样本后观察是否复发。

16:31+08 [最终当前容器聚合](../../verification/artifacts/2026-09-28/client-diagnostic-fidelity/server-log-integrity/triage-final-observation.json)已出现 Android `0.4.21+2190`：新容器共 22 接受批次、0 行拒收/污染，旧 iOS 身份冲突仍 1 故 `coverage_incomplete=true`。2190 组有 1 个闭合 `network_request/network` 事件、3 个主标签帧窗口聚合类别（`discover` 2窗/271帧/5慢，`me` 3窗/876帧/37慢，`messages` 3窗/3008帧/80慢），证明版本/平台归组和新帧窗口确已进入服务端；这些是已上传采样窗口，不是用户总体慢帧率。另有10个业务拒绝型 `api_request`、7个取消的会话打开，不计作服务器故障。当前样本没有 2190 的 request_timeout、Matrix 同步失败或媒体失败，也没有 `diagnostic_loss` 样本；不以缺样本推断无故障。真实设备安装身份、弱网场景和 iOS 新版仍未验收。

完整 `scripts/verify.ps1` 已执行：前置政策、部署模板、基础设施等门禁通过；业务 API/Worker 大套件 3232 passed、27 failed、102 skipped，随后停止。失败集中在并行源码/测试漂移和导入环境；不报告全绿，也不重复跑耗时约 36 分钟的等价门禁。MAIN 定向 auth/media 46 passed、诊断接收 68 passed、triage 42 passed；OpenAPI 诊断路径语义与生成器一致，但现行整文件文本顺序漂移使全局 `--check` 仍失败，此状态由并行任务共享，不能覆盖整个契约文件。

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 分类 | 结果/下一步 |
| --- | --- | --- | --- | --- |
| 只读定位与方案 | 本任务开始时刻未精确采集 | 2026-09-28T13:10:07+08:00 | 主动/并行 | 定位四个确定缺口，完成文件归属和计划；起点未知，不编造耗时 |
| 实现与聚焦验证 | 2026-09-28T13:10:07+08:00 | 2026-09-28T14:13:47+08:00 | 主动/工具/并行 | N1/S1/M1/J1/C1/T1 RED/GREEN；22个任务文件按基线SHA合入主目录，OpenAPI仅合诊断路径语义 |
| 全库验证与生产候选 | 2026-09-28T14:13:47+08:00 | 2026-09-28T14:34:09+08:00 | 工具/主动 | 全库业务套件 3232/27/102，旧候选废弃，新候选 `25fe...` 基于实时 `c119...`，仅接收文件差异 |
| 接收端生产验收 | 2026-09-28T14:34:09+08:00 | 2026-09-28T14:36:50+08:00 | 工具 | 单 API 切换、严格 TLS/401/容器/配置/新错误核验退出 0；零迁移、零真实认证探针 |
| 线上日志聚合及 Android 2190 构建 | 2026-09-28T14:36:50+08:00 | 2026-09-28T15:03:24+08:00 | 主动/工具 | 两次真实失败闭环；最终 1793 文件冻结、164 聚焦测试、固定签名重建/独立验签 PASS |
| 新加坡 CDN 与香港正式发布 | 2026-09-28T15:03:24+08:00 | 2026-09-28T15:29+08:00 | 主动/工具 | CDN 精确行为/CORS 补齐并 Deployed；不可变对象、别名、Android 三字段与网络择优下载页验收通过 |
| 发布后日志完整性修复 | 2026-09-28T15:29+08:00 | 2026-09-28T16:05:40+08:00 | 主动/工具 | 2190 发布器核验 exit0、60 项版本/发布聚焦测试；旧污染行保守恢复，接收端单次写入候选仅一文件/261聚焦通过并切换，严格 TLS/401/容器/0091/新错误均 PASS |
| 后验观察与交接 | 2026-09-28T16:05:40+08:00 | 2026-09-28T16:31+08:00 | 主动/工具 | 工作站 TLS PASS、自有隧道关闭；Android 2190 静态/版本/CDN 再核验 PASS；16:23 API 健康/0重启/新错误0；旧 iOS 身份冲突安全分类；首批 2190 网络事件与帧窗口已到达 |
| iOS 发布路径审计 | 2026-09-28T16:31+08:00 | 2026-09-28T16:36+08:00 | 只读/并行 | 当前企业包仍 2189；本地未提交源码不可直接触发 macOS CI，现有 CI 只产 App Store 签名候选；需安全整合和既有企业重签 |

从已知 13:10:07+08 到 16:36+08 约 3 小时 26 分钟；起始只读定位时间未知，不编造完整总墙钟。完整测试套件耗时约 36 分钟，已记录真实失败和重试原因。

## 交接与回退

- 已确认根因：采集器合法信封过滤、跨版本 spool 误归属；媒体和帧归因的范围见计划。
- 待办：iOS 诊断源码仍在本地未提交工作树，当前 MAIN 与远端存在大量并行差异；需安全整合/推送到 CI 可构建 ref，macOS 产出 App Store 签名候选后由既有企业渠道重签，最终 IPA 未得到前不能发布 iOS。Android2190/后续 iOS 设备与真实故障日志仍需复验；全局门禁及 OpenAPI 原失败持续记录。
- 已发布与候选：生产 API 正运行 `sha256:2b847ef7...`，仅接收端一文件写入补丁 `sha256:b5b9eaf6...`；前一兼容镜像 `25fe...` 及更早 `c119...` 均保留，旧 `4b72...` 候选未发布。Android 2190 已发布，冻结清单 SHA `6b5ac7ac…41dd`、APK SHA `7126f4ca…3423`；iOS 当前 2189 未包含新诊断。
- 生产备份/恢复：`release.py` 冻结发布前 29 容器身份、compose、0700 备份和回退配置；私有 `/opt/starchat/releases/client-diagnostic-fidelity-20260928-publish/`，仅在当前容器身份仍精确匹配时允许自动回退；不可覆盖后续并行发布。
- 运行中命令/隧道：无本任务生产隧道。
- 下次恢复先检查：本任务工作树归属文件 SHA、代理测试 RED/GREEN、当前生产 API/版本。
