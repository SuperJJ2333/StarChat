# 客户端诊断保真修复与发布核验

2026-09-28 用户要求在网络超时、Matrix 同步、媒体加载和局部卡顿时保留可用于定位的 `version`、`platform` 等信息。兼容接收端先发布，Android `0.4.21+2190` 后发布，随后又修复了服务端日志行污染；iOS 源码已纳入相同诊断，但线上 `0.4.20+2189` 尚未更新。这里记录的是诊断能力及发布证据，不把旧版日志或本地自动化等同于新版真实设备效果。关联[任务台账](../workflow/tasks/2026-09-28-client-diagnostic-fidelity.md)和[批准计划](../superpowers/plans/2026-09-28-client-diagnostic-fidelity.md)。

## 结果与范围

| 情况 | 2190 中新增的定位记录 | 边界 |
| --- | --- | --- |
| 业务请求超时/失败 | 生产形状批次保留外层版本、平台和随机请求 ID；请求阶段、闭合错误类别、UTC 时间可关联，失败尽早进入本地有界 spool | 不上传 URL、请求/响应正文、令牌、异常文本；网络中断仍可能延迟或丢失上传 |
| Matrix 同步 | 响应等待起点、失败/重启/看门狗闭合状态；旧版持久化记录仍归原版本和平台 | 看门狗动作返回不伪作同步成功；SDK 未暴露的根因保留 `unknown` |
| 媒体 | 可由异常类型/HTTP 状态证明的网络类别、阶段及关闭结果 | 不能证明的分类仍是 `unknown`，取消与缓存 miss 不算失败；不上传附件明文、URL 或房间 ID |
| 局部卡顿 | 前台分钟窗口的安全主标签、预算/慢帧数及最大值；保留原全局帧计数 | 主标签不等于子页面；后台/无效时钟不误报前台慢事件 |
| 诊断覆盖 | 有界驱逐/拒绝计数、旧接收端 422 可选字段降级、服务端按版本/平台去重汇总 | 离线、进程终止、队列满及服务器日志轮转无法保证每次事件远端永久留存 |

兼容接收端基于生产 API `sha256:c1191a891360c4d3169fa68c7e0973fc2fccee71fe579bae10122a5eb06c3d10` 构建，只变更 `app/api/client_diagnostics.py`，首发镜像 `sha256:25fe73182d038aeb734d9ed2d7bd31d5254f971db60a07d616bd159750d06210`。14:34:09+08 切换，14:36:48–50+08 严格 TLS 的 live/ready 200、匿名受保护入口 401、配置/挂载/网络及另 28 个容器不变、新错误/traceback 0；无数据库迁移或真实已鉴权探针。[接收端发布器](artifacts/2026-09-28/client-diagnostic-fidelity/server-publish/release.py)的私有生产记录位于 `/opt/starchat/releases/client-diagnostic-fidelity-20260928-publish/release.json`，`deployed=true`、`verified=true`。该镜像随后被下文日志完整性补丁 `2b847…` 取代。

## 客户端构建和分发

[最终构建记录](artifacts/2026-09-28/client-diagnostic-fidelity/android-release/run-20260928-150108/artifact.json)：源码冻结 1793 文件/SHA256 `6b5ac7ac1c0d45eeffdd7dcec6e9453a3cd7c38244fc1c71821643fa48f341dd`；[正式 ARM64 APK](artifacts/2026-09-28/client-diagnostic-fidelity/android-release/run-20260928-150108/final.apk) 为 81,701,918 字节、SHA256 `7126f4cad482bcdab1cc239d419bd611550916c8dd68b74101af8411d9b63423`。固定用户验证的单一签名证书 SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，v2/v3、zipalign、非 debuggable、包名 `com.liuhetong.mobile`，并启用 `CHATFLOW_PERFORMANCE_METRICS=true`。常规 Flutter 源构建后按仓库工作流重建 DEX/资源/manifest；独立再解包核对 25,346 类、6 DEX、474 资源、338 native/assets 和 manifest 语义一致。前两次构建的遗漏插件源码和旧锁屏 manifest 已修复，失败记录保留于[构建目录](artifacts/2026-09-28/client-diagnostic-fidelity/android-release/README.md)，未把失败候选分发。

香港直连不可变 APK 与新加坡私有 S3/CloudFront 精确 2190 对象共享上述 SHA/字节。CloudFront 新精确路径补齐与旧 2188 相同的缓存行为后，`Deployed`、206 Range 字节一致和 CORS 均通过；旧 2188 对象/路径保留。香港 `latest-arm64.apk` 原子切到 2190，Android 版本/构建更新为 `0.4.21+2190`，更新入口仍为既有网络择优下载页。正式发布的[网络元数据](artifacts/2026-09-28/client-diagnostic-fidelity/android-release/release-network.json)及[首次发布后只读复核](artifacts/2026-09-28/client-diagnostic-fidelity/android-release/final-publication-readback.json)证明：实际设置只经“Android 三字段”再经“仅 APK URL”两次允许变更，iOS 仍 `0.4.20+2189`，静态哈希一致，当时接收端镜像未漂移，香港/新加坡旧新包四次 HEAD 均 200，未下载 APK body。后续 API 补丁上线后又运行[最终发布读回](artifacts/2026-09-28/client-diagnostic-fidelity/android-release/post-receiver-publication-readback.json)，除符合预期的 API 镜像变为 `2b847…` 外，上述客户端发布状态仍通过。用户可从[官方 Android 下载页](https://www.liuhetong888.com/download?platform=android&install=1)获取新版。

香港 SettingService 只读审计按两次发布 trace 精确读回四条 `SUCCESS`：标准阶段 `app_apk_url` 为 `12b54e90-e44e-4511-b950-4a5c0eb160cc`、`app_latest_build` 为 `90935f03-5390-4413-9c8e-5d2af30430db`、`app_latest_version` 为 `e1754204-5522-445a-a6fd-735517afe856`；网络阶段仅 `app_apk_url` 为 `aadf369a-fd72-423d-ae41-5acf315a3436`。仅核验 id、result、subject_id，未导出完整审计事件。

## 测试与真实日志

诊断聚焦 RED/GREEN：网络采集/报告 124、同步/媒体 85、看门狗 26、诊断核心 122、接收端 68、服务器聚合 42；最终主目录版本/发布元数据 60 项通过，Flutter 源码对齐后 164 项聚焦测试通过且 analyze 通过。完整 `scripts/verify.ps1` 前置政策/部署/基础设施等阶段通过，业务 API/Worker 大套件为 **3232 passed、27 failed、102 skipped** 后停止；失败集中于并行源码/测试及导入环境漂移。OpenAPI 本任务诊断路径语义与生成器一致，但共享整文件文本顺序漂移导致全局 `--check` 仍失败。不得将全局门禁描述成全绿。

发布前 24h 服务器内聚合仅有旧 Android2188 的 10 个接受批次、0 拒收；所见 25 次请求超时和 6 次 5xx 都不是本批新客户端表现。15:35+08 再做服务器内 24h 聚合，扫描 21033 行、53 个接受批次、1 个拒收诊断行、无截断/去重冲突；其中已接受的 Android2188 操作有 126 次 `request_timeout`、7 次 `server5xx`，且尚无 Android2190 批次、`frame_windows` 或 `diagnostic_loss` 样本。因为 1 个拒收，聚合明确标记 `coverage_incomplete=true`；分类调查见任务台账。原始用户日志未下载到工作站，服务端[聚合工具](../../scripts/client_diagnostics_triage.py)只输出闭合字段和计数。不能据此宣称 2190 已改善网络可靠性或已覆盖全部真实用户事件。

唯一拒收行经服务器内结构核验，发生于 14:57:18+08、2190 上线前：旧 Android2188 的完整、DTO 有效诊断 JSON 含 20 条操作，后面在同一 Docker stdout 落盘行拼入非 JSON 文本；不是客户端字段不兼容，也不是 `docker logs` 的 stdout/stderr 合并所致，尾部写入者未确定。原 `print` 把 JSON 和换行分开写入，存在可复现窗口。15:55:35+08 先将服务器**私有**聚合工具原子更新到 SHA256 `b54a156e1761b2a7ef480bbac51755d8d662e8e512fdae7a84c6ffd150141f84`，保留[切换记录](artifacts/2026-09-28/client-diagnostic-fidelity/server-publish/triage-v2-publication.json)及旧版备份；不变更运行 API。它只恢复完整且通过现行 DTO 的前缀，保留污染/未解析尾部计数及 `coverage_incomplete=true`。更新后[24h 安全聚合](artifacts/2026-09-28/client-diagnostic-fidelity/server-publish/triage-v2-24h.json)扫描 24155 行、接受 70 批（含受污染行的有效前缀）、污染/未解析尾部各 1，仍无 Android2190 样本。受污染行同时计入 `accepted_batches` 与 `rejected_lines`，两者不能相加当作物理行数；`unparsed_suffix_lines` 是受影响行数，不是确认丢失批次数。接收端单次写入补丁已完成 261 项聚焦测试，但此时尚未切换运行 API；超过 Linux `PIPE_BUF=4096` 的日志行仍不能保证两个 worker 间绝对原子。

16:04:17+08 以 `25fe…` 现网镜像构建候选 `sha256:2b847ef70e0257f4ba52e663812112d7664016ff427d454c32630da1b0c89a63`，全镜像 inventory 仅接收文件从 SHA `795e…` 变为 `b5b9…`，网络隔离/只读 Linux 接收端测试与导入 exit0；29 个运行容器不变。预检冻结 Compose、29 容器和 schema `0091`；16:05:17–29+08 只切 `business-api`，16:05:40+08 生产[发布核验](artifacts/2026-09-28/client-diagnostic-fidelity/server-log-integrity/release-verification.json) exit0：API 配置/挂载/网络和另 28 容器不变，严格 TLS live/ready200、诊断/账号安全匿名401，新错误/traceback0；工作站经自有短时 SOCKS 的 TLS 200/200/401 也通过且隧道已关。无数据库迁移、真实已鉴权探针或客户端改动。私有 `0700` 发布目录 `/opt/starchat/releases/client-diagnostic-log-integrity-20260928-publish-r1/` 保留快照和受控回退；首轮工作站命令因 PowerShell URL 参数拼接错误失败，修正后严格 TLS 通过，未代表服务异常。

新 API 镜像下[服务器内聚合](artifacts/2026-09-28/client-diagnostic-fidelity/server-log-integrity/triage-post-cutover-24h.json)已成功运行，切换后早期窗口接受 2 个旧 Android2188 批次、0 拒收；Docker 容器重建后旧容器日志不在新容器的 `docker logs` 范围内，因此该“24h”查询实际只覆盖新容器启动后，不能与切换前 70 批直接比较，也不能证明完整 24 小时留存。两名 worker 的 `PIPE_BUF` 仍为 4096；16KiB 允许体的日志行可能超过原子写入保证。单次正常写入消除了旧 `print` 的明确窗口，绝对逐事件远端留存仍未达成。

16:23:54+08 的[跟进健康读回](artifacts/2026-09-28/client-diagnostic-fidelity/server-log-integrity/followup-health.json)确认新 API 健康、0 重启、另 28 容器仍原身份，自切换以来扫描 5747 行服务日志无 ERROR/CRITICAL/traceback。另一轮[新容器诊断聚合](artifacts/2026-09-28/client-diagnostic-fidelity/server-log-integrity/triage-post-cutover-followup.json)接受 11 批旧 Android2188/iOS2189，0 行污染/拒收；有 1 个操作 ID 冲突，所以 `identity_ambiguous=true` 和 `coverage_incomplete=true`，仍无 Android2190 样本。[服务器内闭合结构复核](artifacts/2026-09-28/client-diagnostic-fidelity/server-log-integrity/triage-operation-conflict-structural.json)显示它是旧 iOS2189 两个成功 `api_request` final 使用同一未索引身份，阶段/总耗时不同；日志无法区分意外 ID 复用与最终记录修订。聚合器按设计隔离两者，统计为下界；它不是网络失败或接收拒绝，应在新版本产生样本后关注是否复发。

16:31+08 [最新聚合](artifacts/2026-09-28/client-diagnostic-fidelity/server-log-integrity/triage-final-observation.json)首次出现 Android `0.4.21+2190`：新容器累计 22 个接受批次、0 行拒收/污染；前述旧 iOS 身份冲突仍让总体覆盖标志为不完整。2190 已有 1 个闭合 `network_request/network` 事件，并按 `discover`、`me`、`messages` 三个安全主标签汇总 8 个前台帧窗口，分别为 271帧/5慢、876帧/37慢、3008帧/80慢。这证明新版版本/平台归组和帧窗口实际到达，不是全体用户慢帧率。另有 10 个业务拒绝请求和 7 个取消的会话打开，不计为服务器故障；尚未收到 2190 的超时、同步失败、媒体失败或 `diagnostic_loss` 样本，不能据此推断这些故障不存在。

## 待完成的外部验证

需要升级后的真实 Android 设备产生超时/同步/媒体故障样本，核对接收成功、原始版本/平台、阶段、丢失计数和端到端可关联性；目前虽有 2190 真实帧/网络事件上报，但没有 ADB 真机安装身份或针对性弱网复现结果。iOS 诊断源码仍在本地未提交工作树；现有 macOS CI 只构建已推送 ref 的 App Store 签名候选，并不产生企业包。需先与远端安全整合、macOS 构建核验，再按既有企业渠道重签，拿到最终 IPA/身份信息后发布；Windows 上没有可发布的 2190 企业 IPA，现网 iOS 2189 不含本轮诊断。生产接收端可独立于客户端回退；旧格式仍可收，新格式可选字段按 422 降级，但退回旧接收端会失去新增覆盖字段。旧 Android 包、香港私有发布备份和新加坡旧对象均保留。
