# 验证码、锁屏、聊天卡顿与本地检索

## 范围与状态

用户要求修复六项问题并安装Debug。受影响设备为Redmi K80、Android0.4.16/2185；系统锁屏未认证即可进入聊天，收发消息前后明显卡顿。iOS机型/build未提供。本轮是修复及Debug交付，正式Android2185与iOS2173发布设置未改变；用户已独立批准PHONE-only服务修复。旧6d5候选准备阶段被并行S3基线漂移拦住，未部署；相同phone3ce3修复兼容重基为1aa6候选，保留当前S3代码和配置。

当前：Debug0.4.17/2186已固定签名重建并保留数据覆盖安装到emulator-5556，设备SHA一致且启动成功。源码91292717/1775冻结输入；最终规格及质量安全PASS，首轮全部Flutter4827/9skip、最终20项增量闭环、全量analyze0、完整verify0、原生Robolectric1case通过。手机号API1aa6已健康发布，phone3ce3实际导入、0090/receiver6033及28其他容器保持，两侧严格TLS/鉴权验证通过；以下旧“待完成”均为保留的阶段记录。

## 已确认根因

| 问题 | 根因及修复方向 |
| --- | --- |
| 明确拒绝仍60秒锁输入 | 手机和邮箱两页在发送前启动timer，异常处理不清除。明确409/422及已知未发送错误立即释放；未知发送保留ADR0085冷却，不自动重发 |
| 重复绑定 | 邮箱已有规范化唯一/旧号拒绝；手机缺本人同号及发码事务内复查，唯一竞争错误未精准转409。补本人/他人/发码/确认保护，DB唯一仍权威 |
| Android锁屏操作 | 主MainActivity配置showWhenLocked/turnScreenOn为true，使全Flutter聊天页可覆盖OS锁屏。禁用主界面权限、保留独立来电控制；通知等resumed且sessionReady后路由 |
| iOS通知入口 | 未在本机证明系统锁绕过；APNs/scene未等active即投递，补前台门槛及inactive交互保护，不修改钥匙串/不增应用PIN |
| 消息负载卡顿 | synthetic10000已加载历史后20单条更新造成200210次旧消息投影，indexpump及mentions重复全量处理，SDK同步处理阶段实测亦有长耗时 |
| 旧历史检索 | 房内只搜已加载timeline，每次最多600条/3页/2秒；后续60条requestHistory带UI索引/mention刷新。SDK先读本地、空时远程，非所有请求均网络；loadMore异常静默。改直接本地SQLCipher分页/增量索引，不改变显示时间线 |
| 网络埋点漏采 | 每秒spool持久化将计数冻结成小摘要，32队列被每分钟8上传的节奏耗尽；55请求repro丢23。按30秒聚合冻结，上传/stop强制结算最后窗口，固定ID/限额/上传周期保留 |

以上不证明索引物理损坏。本地分页与后台重复扫描是已经复现的算法/接线缺陷。具体实现/来源见各owner证据、下方最终闭环及冻结清单。

## 实际埋点读取

通过既有严格jumper只读，源日志在服务器闭合过滤；不导出正文、关键词、房间/账号标识、IP、凭证或原始异常。网络与性能快照时刻不同，不相加为同一采样窗口。

- [网络快照](artifacts/2026-09-27/mobile-stability-followup/telemetry/network-20260927T1010.meta.json)：24h回溯、57300留存行、616有效摘要，无tail/导出截断；回溯不证明留存满24h。[报告](artifacts/2026-09-27/mobile-stability-followup/telemetry/network-report.json)按sample_id去重，两版本分开。
- **2185业务API/Wi-Fi**：67摘要、1120完成尝试；1116个2xx、4个4xx、0超时/网络错误/5xx。成功p95桶上界250ms、p99桶上界500ms。只是已上报完成尝试；漏采与未上传无法推断，无设备型号无法归属K80。4xx是业务拒绝，不等于断线。
- **2184组另有58超时/15网络错误**，不可混入2185或真实手机结论。调试模拟器和真实用户不按身份区分，不把attempts当用户数。
- [性能快照](artifacts/2026-09-27/mobile-stability-followup/telemetry/performance-20260927T1018.json)：59035行、300经部署DiagnosticBatch验证的闭合批次，无截断；非JSON/不合契约行被丢弃，不是59035请求失败。[汇总](artifacts/2026-09-27/mobile-stability-followup/telemetry/performance-summary.json)保留普通5%、慢错100%上传偏采样限制。
- **2185前台帧**：76259采样帧、947超预算（约1.24%），framework慢事件32、最高668ms。不是精确丢帧数；frame批次缺独立全局ID，失败重试可能重复。总体比例不能代表用户触发卡顿的局部窗口。
- [实际阶段差](artifacts/2026-09-27/mobile-stability-followup/telemetry/measured-stage-intervals.json)：46条Matrix同步处理，p50 899ms、样本p95 12626ms、最大15849ms；cleanup最大8ms。/sync约30秒long-poll等待本身正常，不能以其总时长判定慢网。SDK处理阶段也不自动等于纯CPU，需结合代码放大复现。两次发送本地持久化153/193ms、Matrix send483/708ms，样本太少不代表总体分位数。
- [真实受保护服务端性能快照](artifacts/2026-09-27/mobile-stability-followup/telemetry/server-performance-snapshot.json)：200/no-store，69个注册路由series；最近512个业务数据库SQL样本p95约4.07ms、max14.15ms，checked_out0，pool_wait未知。是业务PostgreSQL，不是手机SQLite或Synapse全部SQL。首次采集误用容器端口8000记录snapshot_unavailable；确认实际8082后只重读快照，未重复日志扫描。

现有“网络检测”测业务HTTP请求耗时/状态，**没有测下载带宽Mbps**，不覆盖完整Matrix/消息端到端或运营商地理归因。缺少键盘专属操作区间和设备机型归因，不能凭当前数据认定K80的完整瓶颈。监控限额本意是约束负载，实际漏采已修；30秒未冻结计数在异常终止时仍可能丢失，spool尽力而为。

## 初始测试检查点（保留阶段历史）

| 范围 | 真实结果 |
| --- | --- |
| OTP Flutter | 9PASS/15FAIL真实red；39PASS green、限定analyze0 |
| OTP backend | 4PASS/4FAIL真实red；64PASS green；真实PostgreSQL16.9 pinned7c688148…4PASS，双方唯一约束/并发/失败回滚/有效retry覆盖，两个本任务容器已清理 |
| 锁屏 | native4FAIL/router1FAIL red；原生契约及邻接14PASS、推送40PASS、限定analyze0；Robolectric首轮受尚未完整chat源码阻断exit1，最终需补；Windows未执行iOS XCTest/原生编译 |
| 网络spool | 1FAIL/1PASS red，明确55请求丢23；相关90PASS green，停止会话最后窗口保留 |
| 版本 | 成对升Debug0.4.17+2186，版本契约2PASS；实际模拟器仍Debug0.4.15/2184/x86_64（安装前读回） |
| 独立审查 | OTP/锁屏/网络首规格checkpoint PASS；聊天完成后续最终规格，再质量/安全；不能把首轮部分PASS称完整交付 |

## 下一步与授权（初始阶段记录）

聊天增量/本地分页完成后，冻结输入，完成最终专项/全量/独立复核；标准源码Debug x86_64→常规DEX/资源/manifest重建→固定75b31c签名→ABI/语义检查，保留数据覆盖安装。服务端手机号小增量候选独立准备，未批准前不切生产；iOS源码修复不表示已有2173用户收到更新。每个阶段真实起止/退出/输入hash随证据保存，初始总起点不完整、不编造总工时。

## Debug实际交付与最终源码

- [冻结输入](artifacts/2026-09-27/mobile-stability-followup/android-debug/frozen-mobile-input.json)：commit `91292717b93a8f28bdd4e7d4cf30900c5c2dc918` / 1775移动文件，manifestSHA `8f19de9130bc6f6556b2b544f9f17f03ba4a1219992e53ac5f0e33644866b63c`，lock52207159不变。只提交41移动归属文件，既有backend/frontend脏内容未混入该Git提交。
- [最终APK](artifacts/2026-09-27/mobile-stability-followup/android-debug/ChatFlow-0.4.17-build2186-x86_64-debug.apk)：0.4.17/2186，com.liuhetong.mobile.debug，x86_64、JIT Debug，135,262,376bytes；SHA `3a1140dff0229920cbdef0faf086e45f13b8e1bb71fd73de40afdfa7d47ca821`，签名仍75b31c66。source→常规DEX/资源/manifest重建→16K对齐→固定签名→独立decode/ELF/类代码/资产/清单等价检查通过。[构建身份](artifacts/2026-09-27/mobile-stability-followup/android-debug/artifact.json)。CHATFLOW_PERFORMANCE_METRICS=true已纳入构建参数。
- [有效锁屏清单](artifacts/2026-09-27/mobile-stability-followup/android-debug/lock-boundary.log)：最终MainActivity showWhenLocked=false/turnScreenOn=false，独立CallActivity保留来电；9个CallActivity相关smali未含自动requestDismissKeyguard。
- [设备读回](artifacts/2026-09-27/mobile-stability-followup/android-debug/install-after.json)：从2184保留数据-r覆盖到2186，version/设备APK SHA一致，UID/firstInstallTime未变，启动Status ok、进程存在。没有卸载、清数据或降级；未读取账号令牌/聊天数据。系统secure keyguard存在、未主动锁机或修改PIN；真机系统解锁行为及K80卡顿反馈仍需用户验收，不把Robolectric/清单等同OS真机证明。
- [源码回填](artifacts/2026-09-27/mobile-stability-followup/gates/source-backfill.json)：45归属路径写入D目录，旧SHA或LF/CRLF等价校验后复制；1775移动文件中3个非归属财务/通知设置文件含并行修改并保留，未声称D与冻结APK全树完全相同。D index/branch未操作。
- 当前正式Android2185与iOS0.4.7/2173分发配置没有由本任务变更。iOS源码已有active scene/通知门槛和不可交互保护，Windows未执行Xcode/Swift/XCTest或打包；现有iOS用户尚未收到本修复。

## 卡顿与搜索最终边界

[聊天证据](artifacts/2026-09-27/mobile-stability-followup/chat/investigation-and-fix.md)：10k历史/20单条变更，旧全历史展示投影200,210→0、仍20索引写；首屏40模型。提及观察弱引用4096×8、2048-ID变更及single-flight（100重叠初次+最新）、每轮隐藏filter一次；10k/20追加只读取20提及正文，旧撤回/解密/隐藏正确。修复了监测到的工作放大，未宣称所有SDK底层扫描/加密工作O(1)或已经真机无卡顿。

[本机搜索](artifacts/2026-09-27/mobile-stability-followup/chat/spec-blocker-closure-green.log)：直读设备SQLCipher，每源512行、64行yield，稀疏第9000条旧匹配自动20页找到，密集首50/次50共享一次512页；不触发远程history/profile，不修改显示时间线，不上传关键词或正文。revision在DB等待/yield/投影/发布各处守卫，过期扫描丢弃旧缓冲，同cursor重试。保留错误inline和部分未解密覆盖提示。首次搜索不再局限近几天已加载消息；未存本地/尚未解密的内容不能假称完全命中。尚无FTS全量/物理索引损坏证据，稀疏查询仍需分页扫描本地数据，不能给出所有历史检索固定耗时保证。

[SDK调度](artifacts/2026-09-27/mobile-stability-followup/sdk/cooperative-handoff.md)：真实factory接public subclass，原storeEventUpdate调用一次，8ms或16event后让出event queue；事务/锁/原提交/错误/回放/密文撤回/ACK重开测试通过。原SDK缓存burst heartbeat未执行，修复后第5次完成前执行。不改SDK、SQLCipher格式或加密流程，不减少单个fragment JSON写入，不把8ms说成硬时限。原SDKnested提前提交语义仍保留。

## 最终门禁与时间

规格先于质量：[规格闭环](artifacts/2026-09-27/mobile-stability-followup/reviews/spec-review-closure.md)、[质量安全](artifacts/2026-09-27/mobile-stability-followup/reviews/security-review-final.md)PASS；保留NOT PASS检查点和首次失败日志。全量Flutter4827PASS/9skip、修订cache/coalescer增量20PASS、最终全量analyze0；完整verify exit0（API/worker3052PASS/93skip，移动127PASS/1skip，AST273/0090/OpenAPI/compose/UI33组件476屏）。Robolectric实际JUnit1case0failure，protected onDestroy fixture失败仅改controller.destroy后关闭；Windows/iOS未执行状态保留。旧Starlette/httpx、Gradle/Kotlin兼容和API28 flag弃用告警保留并说明，未为本轮升级依赖。

时间均+08：verify18:25:22→19:00:59（35分37秒）；Flutter18:43:01→18:49:54（6分53秒），两次全量analyze分别22秒/10秒；native闭环19:03:09→19:03:31（22秒）；构建19:08:15→19:18:45（10分30秒）；安装/读回起止见对应stage。步骤有并行，不相加为总工时；精确首响应起点未知。手机真机性能及iOS编译/分发不是本轮已完成事实。

## 手机号API实际发布

用户独立批准的是相同PHONE-only修复。旧6d5因并行S3基线漂移被拦住且未部署；最终以当前S3 API55ac为基线的1aa6c222候选只修改phone3ce3，一项变化/1072不变。相同镜像的第二次容器重建只刷新运行ID与Docker自动字段，保留最新S3运行配置与worker0e011；不重复未变候选测试/恢复。原安装Linux3+实际PG4、138表只读恢复及回退55ac兼容证据按输入未变复用；发布前规格→安全PASS。

[发布安全汇总](artifacts/2026-09-27/mobile-stability-followup/otp/server-publish/rebase/release-final.json)：19:50:27→19:50:30一致性备份留0700服务器目录；19:50:30.881→19:50:45.922健康切换，仅API，实际c0e9a5d3/1aa6，未迁移。19:52:55 actual import phone3ce3/receiver6033/schema0090，28其他容器及worker/PG不变、环境/挂载/网络保持，新API错误0。初次Env/Binds列表顺序比较失败保留；完整条目排序严格等值及全部Mounts字段相等，只修只读比较器，无重新部署或真实挂载改变。

两侧严格TLS均2健康200和4未登录401；工作站19:53:32→19:53:34，ssl_verify_result0，自有隧道关闭。[watch读回](artifacts/2026-09-27/mobile-stability-followup/otp/server-publish/rebase/watch-post.json)：19:53:32 timer active/waiting、service success、无activealert/failure/pending，最新1/1为2xx；恢复状态不证明先前邮件已送达。没有生产发码、真实联系人或伪造会话写入，没有修改正式Android/iOS分发。新增未登录启动诊断route未夹带部署；旧d392等候选需基于当前live兼容准备。

[最终源码身份](artifacts/2026-09-27/mobile-stability-followup/gates/final-source-identity.json)：19:41:55重新核对71项质量审查输入、45归属源码在C/D均匹配，无漂移。安全证据与终版文档回填后执行本任务的链接/一致性检查，不重跑已完成且输入未变的构建及测试。

[安全证据回填](artifacts/2026-09-27/mobile-stability-followup/gates/safe-final-evidence-backfill.json)：19:59:11+08按最终冻结清单复制187文件，源及D目标hash相等，76缓存/测试DB排除，服务器私有配置和数据未复制。终版三docs同步；[本任务链接检查](artifacts/2026-09-27/mobile-stability-followup/gates/final-handoff-links.json)覆盖C/D两份文档且无失效链接。独立交接只读复核PASS，澄清本地检索只在设备内读取、内容及关键词不上传。当前未完成项仅保留真实Redmi/系统锁屏和iOS原生构建/分发验收。
