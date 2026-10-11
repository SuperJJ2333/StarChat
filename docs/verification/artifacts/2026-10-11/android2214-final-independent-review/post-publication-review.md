# 独立复核：九域交付报告与实际发布回执

结论：**交付事实与通过范围一致，未发现虚报设备覆盖或性能数据**。本次仅复核本地证据和文案，没有远程查询、启动容器、改产品或重跑既有门禁。审核输入的精确 SHA 和后端独立报告 Git 身份见 [输入清单](post-publication-review-inputs.json)。该结论不是新一轮全项目代码审计或长期生产健康验收。

先按规格核对九域覆盖、发布对象和保留边界，再按质量/安全核对原始回执与证据：

- 九个实际阶段（runtime、upload、assemble、HK install、CDN install、CDN check、HK switch、publish、audit）均 PASS，全部绑定已独审的 b1abd1…8297 freeze。11 个获授权操作不等于全部执行：独立 preflight/inspect 没有被虚计成实际阶段；runtime 内含即时基线检查。
- Android 2214 alias、版本、73,336,097 字节及 APK SHA575e24…af614 与冻结实物一致。CDN 从 InProgress 到 Deployed 的两个阶段明确区分；HEAD200/CORS/长度证据成立。三条审计只涉及 Android build/version/notes，双端实际路由投影保留 iOS2213、minima3及原 URL。
- 工作站四项响应的原始 SHA/bytes/状态逐项复核，CDN响应头含长度与CORS；ready200与匿名更新401的含义准确。没有把匿名401声称为用户登录业务验收，没有声称完整APK公网回拉。自有tunnel退出有独立记录。
- 回填回执绑定真实 audit SHA；两目标文件实际 after 原始字节相同。五个保留文件的当前 raw/Git 身份均与独审和回填记录相符；admin既有生产/仓库差异维持各自身份，没有额外部署财务界面。
- worker真实 wrapper exit0、settled PASS，abda33f8镜像/db5d65ff容器、五源码SHA、schema0095、其他容器不变与切换前证据吻合。backend冻结 e40bd286 的原始九结构检查全部true，与root回执吻合；不代表长任务在生产已实测超过五分钟，亦不保证外部恰好一次。
- 最终报告逐项覆盖后台、提醒、消息链路、UI、内存、媒体、整体架构、文件管理和启动。修复/门禁与未测指标分列；5958/9/0、401/1、Android三个API28 x86_64 fixture、iOS20 native、unsigned IPA与28构建步骤的范围保持原证据口径。没有把单位/模拟器门禁或逻辑192MiB预算替代真实ROM、RSS、到达率或功耗指标。
- libcrypto既有4KiB LOAD/16KiB静态exit1、十个RELRO模数仅crypto有RW几何交集等限制准确。未把ZIP对齐当ELF兼容，未声称最终ARM64实体机通过。iOS签名/权益/旧Keychain保数据升级/APNs/Focus、OEM获批配置、弱网/省电/长时内存/低空间、7–14天SLO、链路分母和P50/P95/P99仍开放。

## 文档收束意见

1. task的历史18:18段把09:55:51–10:01:31Z写成“6分40秒”，算术应为**5分40秒**。只修派生时长，原始时间及构建回执不改。这不影响发布身份或门禁。
2. 初读时root结果报告链接的worker `REPORT.md`未归档，目录仅准备文件。已从backend冻结commit e40bd286独立读取报告和原始结果，证实结构通过的表述；请集成其精确证据后保持链接可达。
3. warning必须保留未明原因的范围：原10行窗口1个WARNING类，后续结构读取4行使用含WARN的不同筛选，不能相减称新增3个或作为warning率。已读冻结结构结果明确unknown logger、原因未明；不能因healthy、其他类别0或旧模板存在改称无害/日志全通过。root后续定位若产生新证据，更新报告时须指向该证据并保留历史观察。

以上是文档精度/归档事项，无需重跑已完成门禁或改变发布包。无需修改已冻结的发布批准 JSON；该文件只绑定发布前包，本文记录发布后的实际核对。

复核UTC：2026-10-11T10:59:02.184677+00:00


## 后续增量：warning已定位到固定资金监控枚举

Root新增 `worker-warning-static-enums-r3.json`（10:57:45Z，exit0），只输出源码固定字段：两条 maintenance_state/manual_maintenance/WAITING，以及 source_health/funding_source 的 BALANCE_UNSTABLE、RECONCILIATION_PENDING各一条，后二者status均OK。已直接读取三份来源文件并用AST验证全部输出值属于其字符串字面量，记录精确SHA；没有执行财务模块或读取金额、地址、用户/事件标识和异常正文。

源码解释的边界：manual_wallet.py 117–119根据monitor.complete决定WARNING并输出monitor.status；manual_reserve_monitor.py存在多种WAITING分支，因此不能仅凭WAITING唯一归因。diagnostics.py 205–212把not stable映射BALANCE_UNSTABLE，把RECONCILIATION_UNVERIFIED映射RECONCILIATION_PENDING，并按healthy决定WARNING。这里status=OK不表示资金来源整体健康或已完成对账。

因此，root更新为“warning已定位到资金监控等待/余额不稳定/对账未完成，业务状态仍待领域核验”的措辞有证据支持。该补充只收束日志来源分类，不关闭资金监控问题，不宣称无告警、不证明此前同时间也出现这些状态、不把它们当成租约故障，也不授权改变财务策略或状态。初始未知报告和不同筛选计数均保留；新结论不回写旧观察。root文档后续版本的SHA及归档/时长状态见输入清单中的warning_enum_followup。


最后归档核对：构建时长已更正为5分40秒，结果报告所有本地链接已可达。后端两份Markdown原始字节与e40冻结Git一致；三份JSON在root checkout出现CRLF/LF表示差异，逐项严格JSON及规范换行内容相等。输入清单明确分别保存root raw与e40 Git-blob SHA，不称它们raw相同、不改写原证据；没有产品或生产内容变化。这些文档事项已收束，剩余的是报告中明确列出的真实设备/资金监控业务/SLO等验证缺口。
