# 验证码、系统锁屏、聊天卡顿与历史搜索修复

## 恢复入口

- 用户授权：2026-09-27六项问题，修复后将Debug版安装到模拟器；已单独批准PHONE-only服务端修复发布。旧候选遇并行S3基线漂移后，按同次授权兼容重基，仅叠加相同phone补丁；未授权iOS分发或新启动诊断route。
- 用户设备：Redmi K80，Android0.4.16/2185；系统锁屏仍显示且尚未密码/指纹/人脸认证即能操作。用户描述旧版本流畅，收发消息前后卡顿。iOS设备及build尚未提供。
- 工作树：C:/Users/Administrator/.codex/worktrees/friend-video-followup/StarChat；起始b36a291139fd236e9cd0dad8e22d97d148bcefbb。移动源码基线干净，现有脏backend/frontend是前轮及并行任务，保留。
- [执行计划](../../superpowers/plans/2026-09-27-mobile-stability-followup.md)。Debug2186已安装、归属源码已回填、最终门禁与先规格后安全复核完成；PHONE-only兼容重基API1aa6已健康发布。遵循既有ADR0085验证码语义及设备侧E2EE搜索，不新增锁屏PIN。
- 所有权：OTP agent 手机/邮箱换绑页、控制器/专项测试和phone.py小增量；lockscreen agent 原生manifest/CallActivity/iOS生命周期、PushTapRouter/AppHome及相关测试；chat agent 会话controller/本地搜索及专属测试；root埋点读取、集成/门禁/版本/构建/文档。文件不得重叠。
- 下一步：用户在Redmi K80进行真实消息负载、房间/键盘响应及系统未认证锁屏通知验收；iOS另行完成Xcode/Swift/XCTest、同源构建分发和真机验证。不得将本轮Debug安装称为正式Android或iOS更新。

## 验收台账

| ID | 用户期望 | 已确认事实 | 测试/状态 | 交付缺口 |
| --- | --- | --- | --- | --- |
| M01 | 手机/邮箱不得重复绑定；明确校验失败不倒计时，可立即修改 | 明确拒绝释放输入；phone本人/他人预检、发码及确认事务保护、精确唯一冲突409 | Flutter39/backend64/实际PG4通过；Debug已安装；API1aa6已健康发布并实际导入phone3ce3 | 未对真实账号发验证码；未知发送保留冷却 |
| M02 | 系统未解锁不得操作聊天，通知应受OS解锁约束 | MainActivity禁锁屏覆盖；CallActivity不自动解锁；通知等resumed/active | 契约14/推送40/实际Robolectric1通过；Android已交付 | iOS未编译/分发；系统锁屏真机行为待验收 |
| M03 | 收发消息及房间/键盘交互不卡顿 | 10k/20更新旧投影200210→0；提及增量/viewport/SDK协作yield | 专项及最终20闭环、全量检查点4827通过 | Redmi真机profile待反馈；单次长SDK编码仍不能抢占 |
| M04 | 本地历史可完整检索，不靠反复loadMore/退出 | SQLCipher公开分页直读；稀疏第9000条自动20页命中；revision/取消/错误重试 | 实际本地库及稀疏/密集/撤回/解密回归通过 | 未存本地或尚未解密内容不冒称完整覆盖；关键词不上传 |
| M05 | 判断性能监控、网络检测是否异常 | 已读616网络摘要/300闭合批次；SDK处理最长15.8s；小窗口队列漏计数真实复现并修复 | 网络55请求red丢23、相关90green；Debug启用诊断 | 业务HTTP耗时非Mbps、无法归属特定K80；异常终止仍可丢最后30s未冻结计数 |
| M06 | Debug版覆盖安装模拟器 | Debug0.4.17/2186已固定签名重建、-r保留数据安装emulator-5556 | 设备SHA/版本/UID/firstInstallTime/启动读回通过 | 正式Android2185/iOS2173未由本任务分发新包 |

## 初始证据与计时

2026-09-27 18:08:01+08记录调查时钟，首次响应确切起点未记录。既有1764移动输入SHA1fce8a7d…与522依赖锁作为发布基线；新修复不复用旧全量结果冒称已通过。

网络只读快照在18:08附近成功：57300扫描行、616摘要、无截断/导出上限；0.4.16+2185组1120完成尝试，1116个2xx、4个4xx、0网络错误/超时/5xx，成功p95桶上界250ms、p99上界500ms。不是用户数，不能归属RedmiK80或证明Matrix正常。0.4.15+2184组另有超时，禁止混为2185结论。原始日志不出站，只保留闭合摘要。

## 安全及交接

发送结果未知/超时的冷却沿用已批准ADR0085；明确拒绝立即回退，不自动重发。服务端绑定唯一性仍以规范化索引和事务为准；客户端预检不能替代。系统锁屏由OS负责，原生来电控制保留，不改凭据或Matrix身份。完整本地搜索仅在设备内读取，聊天内容及关键词不上传；生产诊断不读取正文或关键词。账号/JWT/维护令牌和原始异常不进入证据。

## 18:50+08 集成检查点

- SDK public subclass已接入真实MatrixClientFactory唯一构造；SQLCipher打开/PRAGMA、SDK事务和数据格式保持。10,000历史/50缓存更新的真实SQLite旧版heartbeat未执行，修复版第5次完成前执行，7专项通过；不把8ms协作预算说成单条硬上限或CPU工作减少。
- 全量Flutter 18:43:01→18:49:54+08，4827 PASS / 9条件跳过 / exit0；共享analyze 18:49:41→18:50:03 / exit0。是在最终3项审查修复前的检查点，变更后的相关回归和分析须另闭环，不冒称原结果覆盖未测试修改。
- 最终规格当前NOT PASS：扫描中revision变化可能返回旧缓冲；mentions强Event引用长期持有；lease提及更新未single-flight。chat owner接手修复及限定TDD，之后复核增量再最终质量/安全。
- PHONE-only候选6d5ceafde…8921：规格PASS、安全PASS；第一次隔离挂载包含服务器私有快照，未读取/无外传证据，但隔离缺陷真实成立。缩至两个测试文件后18:47:45→18:48:01复验Linux3+PG4通过；1068路径、29生产容器/配置不变，私有文件不导出；此前记录保留。无迁移，待独立批准，不能宣称线上已修复手机号竞争。
- D源码回填预检40个移动增量，4个原始SHA差异均仅CRLF/LF；语义基线一致。回填时须重读并对最终源hash校验，不覆盖并行工作。完整scripts/verify.ps1仍运行，尚无最终退出码。

18:59+08 重新读主目录发现 .git 为真实目录，HEAD b9eca8a4；仓库 AGENTS 的旧“无 .git”描述不作为当前事实。只在既有C工作树冻结/提交本任务移动输入，D回填不操作其index/branch，继续遵守任务证据目录及漂移检查。D phone.py仍匹配d82c5943…2a246旧基线。

## 19:03+08 最终源码门禁闭环

- 仓库verify：18:25:22→19:00:59+08 / exit0；API+worker3052PASS、93条件skip、1既有Starlette/httpx warning；移动边界127PASS/1skip；UI33组件476屏、273Python AST、0090唯一head/offline迁移、OpenAPI和compose全部PASS。只执行一次完整仓库门禁。
- Flutter检查点4827PASS/9skip后，三项规格缺口按影响范围补20专项PASS，并全量analyze再跑19:01:16→19:01:26 / exit0；不重复无变化的完整Flutter测试。最终spec closure PASS保留旧NOT PASS。所有最终移动源1775文件已记录precommit hash。
- Robolectric先被缺失chat方法阻断，再真实编译暴露fixture直接调用protected onDestroy；只改测试为controller.destroy()，21s BUILD SUCCESSFUL / 实际1case0失败。两个失败日志保留。Gradle旧弃用/嵌入Kotlin兼容告警及API28测试使用legacyflag告警已说明，不静默升级平台依赖。Windows无Xcode，iOS原生/真机仍未执行。
- 三项最终修复：扫描await/yield/发布各处revision守卫，旧缓存不继续返回、同cursor可重试；弱观察缓存4096×8并在lease撤销清理；2048-ID变更队列+single-flight最多active/trailing最新，overflow回退扫描，100重叠仅两次执行。10k历史+20追加只读20提及正文，旧撤回/解密/本机隐藏正确；readFilter每轮一次避免重复SHA键运算。
- 接下来：质量/安全最终hash报告→只冻结/提交mobile归属文件→Debug2186 x86_64常规重建固定签名及最终锁屏清单门禁→保留数据安装→D漂移保护回填。PHONE-onlyAPI仍待本次独立批准，无发布/迁移。

## Debug完成、生产基线并行变化

- 用户已独立批准本次PHONE-only发布（6d5旧候选，同一phone3ce3代码），在Debug构建时收到回复；Debug19:20:49→19:20:55保留数据安装成功，19:21:28设备SHA/version/UID/firstInstallTime/启动读回通过。
- 旧6d5准备器的首次CAS发现API基线变化，未备份/停止/更改生产。19:28:28+08实际API55ac98e2…db15 /ab92ed7d… healthy，worker0e011134…/864e6864…为并行S3部署的新像/配置；phone仍d82旧源，receiver6033/schema0090保留。
- 下一步在当前55ac上仅叠加已审查的相同phone3ce3，再验证差分库存、安装后Linux/PG和只读恢复兼容，按规格→安全复核后完成同一次已授权PHONE-only发布。保留S3已上线代码、当前worker及runtime配置，不切旧6d5。若phone基线或语义冲突，停止相关发布并报告。
- 旧启动诊断候选d392及任何基于e880的旧API候选已不适合直接发布；后续需基于当时实际live保留S3及phone修复重新冻结/验证。启动诊断新增route没有被本任务夹带发布。

## 19:53+08 PHONE-only实际发布闭环

- 旧6d5未部署。兼容候选1aa6c2225579392c42dc41b112d73ce0833705f3bb22b143bf77012c637e9273只在S3 API55ac上叠加相同phone3ce3；1073库存仅一项变化，1072不变。并行S3再次仅重建相同镜像容器后，刷新实际ID/自动Hostname/Compose标签路径，源码、环境值及挂载语义未变，无新构建/测试/恢复。最终切换时API48cbc→c0e9a5d3；worker c403/0e011保留。
- 切换前先规格后安全PASS；0700发布目录内新一致性备份19:50:27.501→19:50:30.278+08，28,311,225bytes/SHAf8ea41fc…；仅留服务器。单API切换19:50:30.881→19:50:45.922健康，Compose命令19:50:31.305→19:50:34.716 exit0；无迁移/worker/静态/移动版本设置修改。
- 19:52:55服务端读回：actual import phone3ce3、诊断receiver6033、0090；28其他容器含worker/PG不变，运行配置/挂载/网络保持，2健康200+4鉴权401/严格TLS，新错误0。初次postverify的Env/Binds原始列表顺序比较false-fail保留；排序后的完整条目严格等值，Mounts source/destination/type/RW/mode/propagation及其余HostConfig未变。只改只读比较器，无二次部署。
- 19:53:32→19:53:34工作站严格TLS同样2健康200+4鉴权401、ssl_verify_result0；自有jumper隧道关闭。19:53:32 watch timer active/waiting、service success、activealerts空、failures0、pendingfalse、最新1/1为2xx；不推断此前邮件送达。
- [安全发布汇总](../../verification/artifacts/2026-09-27/mobile-stability-followup/otp/server-publish/rebase/release-final.json)及[独立复核](../../verification/artifacts/2026-09-27/mobile-stability-followup/otp/server-publish/security-review-rebase.md)保留最终身份及每阶段失败/修正。未对生产真实账号发码或伪造JWT。Debug已交付，正式2185/iOS2173用户未收到本轮移动补丁；真机和iOS原生验收仍待。

## 最终交接

19:59:11+08按冻结安全清单SHA1334ce36回填187个OTP证据文件到D，逐项源/目标hash相等，76缓存/测试DB排除，私有配置/备份未导出。三份终版task/plan/verification同步，45归属源码此前回填与最终71审查输入核验通过；未操作D Git index/branch或声称已推送远端。完整证据见[安全回填](../../verification/artifacts/2026-09-27/mobile-stability-followup/gates/safe-final-evidence-backfill.json)、[链接检查](../../verification/artifacts/2026-09-27/mobile-stability-followup/gates/final-handoff-links.json)。剩余是实际设备验收与iOS原生/分发，不是等待服务端授权。精确初始起点未知，不合计并行阶段为总工时。
