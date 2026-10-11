# 2026-10-11 即时通讯可靠性修复执行记录

## 授权、范围和基线

用户已明确授权继续修复，并由执行者决定产品修改、服务重启与部署。执行已评审的[修复计划](../../superpowers/plans/2026-10-11-im-reliability-remediation.md)，不重复请求上述授权。Android 厂商推送尚在审核；最终 iOS 签名与真机、长时观测属于各自依赖门禁。

基线 main `5c83a08a09b985146bc507a1608cb2153d361e48`。主集成工作树 `C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat`，分支 `codex/im-reliability`。原工作区评审文档保留。临时证据限定 `docs/verification/artifacts/2026-10-11/`，不采用技能默认根目录临时产物位置。

## 任务台账和文件所有权

| ID | 状态 | owner / 实施边界 | 下一步 |
| --- | --- | --- | --- |
| R0 | 外部身份/设备门禁待补 | root；保留现有最终包证据 | 核对可获取最终签名资料，不猜测已安装身份 |
| R1 | 已部署；真实用户恢复仍需分桶观察 | root；commit c8342ca4；固定8082 | 生产聚合后验，不读取用户恢复材料 |
| R2 | 已部署；设备到达率待测 | 46c853f4（原9d32bdfd）；精确候选51PASS | 观察真实业务与设备回执 |
| R3 | 已部署；实际媒体流量样本待补 | 53757826；精确候选15PASS、API/worker guard通过 | 线程池/对象内存仍有后续任务 |
| R4 | Android2214已发布；iOS不涉及FGS | 6999a563及最终e9d297；共享/原生/固定重建通过 | 真机Doze、后台配额与锁屏功耗待测 |
| R5 | 网关已部署；Android2214已发布；iOS仅unsigned | 服务端95fc1927；客户端ddfa73b9含远端对账/429期限/IANA DND元数据 | 最终iOS签名与APNs/Focus真机待测 |
| R6 | Android2214已发布；iOS仅unsigned | c772a503/6ee91ed7/1f527262/8242b89f；settle与registry ownership修复；最终共享通过 | 真实设备弱网与到达状态待测 |
| R7a | Android2214已发布；iOS仅unsigned | 75d2c969/1284772e；256正文/页、维护租约不跨网络等待 | 真机profile；ID元数据仍O(N) |
| R7b | Android2214已发布；iOS仅unsigned | bee0891c/4662f576；worker哈希、大seed预览、64KiB小对象例外 | 真实设备峰值内存待测 |
| R7c | Android2214已发布；iOS仅unsigned | 7454986f；启动编排修复，最终共享通过 | 真机冷温热启动分位待测 |
| R7d | Android2214已发布；iOS仅unsigned；冷查询待后续 | b888e282；热查询块索引；冷构建仍O(N) | 实机profile、cold/提及元数据另验 |
| R8a | Android2214已发布；iOS仅unsigned | 8475a0b4/8d3a38f3/3e0ce735；上传前预算/能力交集预检 | 真机大媒体与低空间待测 |
| R8其余 | 最终缓存/持久任务/SQLCipher顺序修复已集成；Android2214发布；iOS仅unsigned | 最终e9d297/f7a9共享通过，Android真实3例、iOS native20通过；历史RED保留 | 真机杀进程恢复、文件保护、低空间/长时内存待测 |
| R9 | 日志/逐条领取/代次及有界活跃续租均已部署 | worker abda33f8/db5d65ff；10:39:52–10:40:17Z settled PASS | warning已定位资金监控状态、待领域核验；长期容量、冗余、历史治理单列 |
| R10 | 有界采样器修正及独立审查已完成 | a18bb18d/7e325b4f；真实Windows/Linux边界；5分钟样本保留分母 | 7–14天端到端SLO与设备回执仍待采集 |
| R11 | 外部审核依赖 | 厂商通道申请 | 获批后按固定包名签名接入 |

并行实现使用独立工作树及不相交文件；实现者不部署。root 汇总后按规格/领域→质量安全顺序审查。历史脚本/证据不能代替当前候选门禁，未完成的测试不标通过。

## 阶段时间（UTC+08）

| 阶段 | 开始 | 结束 | 证据/结果 |
| --- | --- | --- | --- |
| 隔离与任务分配 | 2026-10-11 10:20（近似） | 进行中 | 主工作树创建成功，R2/R3/R4已分配 |
| R1 环境预检 | 2026-10-11 10:24 | 10:27 | 本机 Docker29.8.2可用；宿主 Python 无 Twisted，原生门禁改用隔离 Linux 镜像；不冒充已通过 |
| R1/R9测试与双审 | 2026-10-11 10:27 | 10:53 | R1单元16、真实PG16.9计20、旧HTTP503 RED→候选Twisted14PASS；infra925PASS+jsonschema环境缺库1失败，已有依赖环境单项补验PASS；R9三RED→三GREEN及实际轮转 |
| R1/R9生产切换 | 2026-10-11 10:53:36 | 10:54:12 | 三容器healthy，HTTPS Matrix200/APIready200/recovery未授权401，其他容器ID保持 |
| R2/R3精确候选与切换 | 约11:00 | 11:16:39 | 51/15候选专项PASS；候选/回退双角色guard；切换11:16:10–39 |
| R7c实现/验证/双审 | 约11:18 | 约11:29 | 长等待/真实main/首帧指标三组RED，最终40PASS、独立17PASS、analyze0 |
| R5b服务端构建/验证/切换 | 约11:24 | 11:29:50 | 精确server候选11PASS；SPEC/domain→QUALITY；切换11:29:46–50 |

## 发布与回退

R2/R3 11:16:39发布成功：Getui `sha256:0d3c204b0df4863a8826aef6b58556f0fc9c8a6c89d5ca0ec137eec81fe7f43c`，API `sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3`。schema0095保持，worker与其他容器ID未变。实际candidate内51项/15项分别通过；API初次夹具缺avatar.png导致setup错误，补齐固定夹具后15PASS，未修改candidate绕过测试。候选和回退API/worker均通过现场release guard。11:21:48聚合后验：API运行健康/零重启/零traceback，其他业务171次200/5次202/10次204；未观察到媒体样本，不能声明生产媒体延迟已达标。Getui零新日志样本，HTTP成功不冒充设备到达。

R5b Sygnal 11:29:50发布成功，镜像`sha256:90fa02ff684b44aaaa08971845c2ed21d1d838eb4fb38c9e649d69a5be360dd0`，原0.15.1镜像和runtime/config/mount保持可回退。两源文件SHA及mounted配置hash通过；空JSON返回400，未发送真实通知；HTTPS Matrix/API通过，其他容器ID保持。实际候选network-none/只读容器11策略测试通过。普通iOS pusher必须由新客户端携带策略后才启用DND，现安装旧客户端不宣称已获得新行为。旧日志硬链接完整保存，证书/私钥仅留原私有挂载。

R1/R9已部署：Synapse主/同步镜像`sha256:0e861d72f57d56367c393994959cb4e85a1c485142adef7928fe5662d565185d`；模块SHA`2210e152f422d57dc585acfd95e912d58a55596f2112efea0b8c764ce2b09ad7`。gateway镜像不变。三服务日志20m×10，旧Docker日志用同文件系统硬链接完整保留于服务器0700私有目录，未truncate。

服务器发布根`/opt/starchat/releases/im-reliability-20261011`，冻结回退Compose在`private/<service>-rollback.json`，原Synapse镜像`sha256:449fef97b26ba00d62b7c128bdff1e440a127349f89fedf0e6556721c3aa2876`。实际部署receipt为`core-deployment.json`，本地副本见artifact/core-deployment.txt。此阶段不写用户恢复数据、不改业务API/worker，不声明真实用户登录/恢复端到端已验收。

API/worker后续发布必须续期协议release guard。现场guard SHA78b2beb6…beec；probe为`business_refresh_image_probe.py`，SHAa2a74012…858f，与仓库当前文件完全一致（历史摘要d77值不用于此次发布）。生产配置/秘密仅留服务器0700目录。禁止自动重放历史财务DEAD、删除密钥或破坏性回退。设备通过声明绑定实际版本/成品SHA。

`scripts/verify.ps1`预检：工作树无`.env`，主脚本不能直接完成render；已分别完成repository/deployment/template/Compose/OpenAPI门禁，不声称整脚本exit0。全量共享候选门禁继续安排；R2/3具体报告保留两项环境失败及针对补验，不能把分次成功写成一次全绿。

## 12:40+08 阶段更新（客户端尚未发布）

当前正式两端仍为2213，不能将当前源码修复算入已安装包。Android/iOS成品构建、固定签名/回签、保留数据覆盖、真实锁屏与声音尚待；不把单元/模拟器作为实机结论。iOS旧最终包的身份连续性缺口仍保留。

R7d精确数据：旧百万未知ID冷/热10726/10926ms；新首次构建13081ms，热434ms/2624 ID；独立复核10090/320ms/2624 ID。这些是Windows合成数据而非手机指标，新冷构建没有变快。相关SQLCipher DLL与源码hash已归档，不随测试库入Git。

原生存储首审未签通过时已发现并修复两处边界：iOS目录占普通文件名、两端悬空optional链接。Android新增真实RED→17PASS；Swift新增同类XCTest待实际macOS结果。诊断CI绑定bdbaab660f521ccd686069740920aca418041861，run38112151641，2026-10-11T04:37:03Z开始。只推送专用codex/im-native-storage-20261011分支运行原生门禁，无产品分发、TestFlight上传或生产配置变更。

R8活动逻辑预算192MiB不是RSS上限；普通文件48MiB、图片/视频31.5MiB还取现有业务限制较小值。超过限制必须明确提示且不无限重试，RoomPage/pending UI由持久任务owner一并联测。当前队列驻留/相册native originalBytes入口仍待文件化，不声称OOM已经解决。

后续按序：预算与原生复审→持久任务/目录索引冻结集成→一次完整共享门禁及两端原生→递增版本构建/固定Android重建验证→授权范围内分平台交付。外部签名/设备仅阻断依赖步骤；R9 7–14天资源、隔离冗余/RPO/RTO、历史财务DEAD及R11厂商资质仍为明确未完成项。

## 13:12+08 阶段更新（仍未发布客户端）

2026-10-11T05:10:51Z 只读生产设置再次确认两端 `0.4.44+2213`，Android registry SHA `08a7448114ad5d768b534b81b61668e03a71a2c26f95e894297e098838f15271`；服务器无2214文件，现有本地worktree pubspec无高于2213版本，近期CI无其他更高候选。准备后续 `0.4.45+2214`，实际冻结前仍核验源输入；尚未修改线上版本或宣称完成包。

Android原生完整JVM门禁在bdbaab66基础上89 PASS。随后为消除最低API工具链不确定性，把NOFOLLOW类型检查换成API21已有的Os.lstat；先观察到Robolectric缺失文件模型错误，再补精确host no-follow shadows，41c86084在API24/35共12专项PASS，独立SPEC→QUALITY通过。真实API28模拟器shell调用Os.lstat确认普通文件、目录、悬空链接和ENOENT，已清理本次固定临时目录。它不是app-private/备份/加密或真实手机验收。最终全原生仍绑定新候选执行。

iOS run38112151641原生源码编译成功，3个XCTest失败。使用独立run38113138721提取原xcresult而未重复构建，确认重复createDirectory(withIntermediateDirectories:false)触发Code516，另首个unavailable尚需区分保护/备份排除/容量。c8dba609只在目录缺失时创建，增加重复初始化保持内容测试、合成能力诊断和始终导出结果；run38113845125执行中。保持实际属性读回与失败拒绝，不为模拟器放宽生产策略。

缓存索引c3050684集成为43acaaca，已有134专项PASS及analyze0；root审查发现背景扫描失败时canEvict仍保持true，与承诺不符，已交owner新增RED修正。持久附件已验证跨房公平、真实SDK上传/同txid重试、页面销毁后迟到ACK，等待最终源码及独立双审，不提前将作者测试写成集成PASS。

R10采样窗口04:30:44–04:35:44UTC，business 576行=366HTTP完成+210未匹配；Synapse167=111+56，sync worker40=23+17，Getui0行。所有分母保留，HTTP200不等于真实用户恢复/设备到达。独立审查确认 `[0 dbevts]` 仅为DB fetch数量，原“idle”解释撤回，修正为长轮询且零DB fetch候选；另run_bounded的继承stdout子进程可导致close等待超出预算，需行为RED与修正后重新审查。首版10测试通过不掩盖上述新发现。

R9隔离真实Worker/consumer合成时钟复现：单慢301秒或49×7秒使预领尾部被其他consumer接管后仍被旧worker执行；另单active301秒过期是独立缺陷。已批准R9a仅worker逐条临执行claim，保留topic/退避/维护/幂等；R9b续租/fencing另审，不改变金融handler、schema或重放历史DEAD。对单个handler的调用重复不能据此推断业务重复记账。

Android最终XML复核修正计数：41c86084全套95项为94PASS/1条件skip（历史DeltaApplier签名APK夹具未提供），无失败/错误，存储12全部执行。此前“89PASS”也是含该skip总数，准确为88PASS/1skip。已在原生报告同步纠正，原始日志保留。

## 13:52+08 集成与剩余门禁

R8缓存失败校准修正896e8e77已集成为f87f72cc，root独立规格→质量审查通过，集成13项PASS。初始/坏索引完整校准仍O(N)，稳定运行增量写入不全目录扫描；配额只管理自身可淘汰文件，不能当整个沙盒磁盘上限。

R10产品0eea3319独立Windows18PASS/Linux17PASS+1Windows专属ABI skip，SPEC→QUALITY通过，集成为a18bb18d；真实继承stdout及EOF但进程存活边界均执行。证据修正9ee608a区分Windows CRLF和Git LF两种历史SHA，root逐行复核且在集成树执行一致性校验exit0，集成为7e325b4f；原样本、窗口、数值和分母均未修改。原“idle”指标撤回已在当前报告纠正。

R9a独立源码审查通过，70dee9dd/9e036261集成为f8579cf7/5584d294。精确旧worker镜像上仅覆盖worker.py形成候选18a88c4d，隔离容器7PASS/1已知active租约strict XFAIL/1显式PG skip；源码真实PG及相邻248PASS/1XFAIL证据复用。候选/回退API与worker协议guard通过。此时尚未切换，部署脚本的有界超时/只读SQL及不确定状态不盲目回退正在独立复审。

持久附件850710bd独立审查为CHANGES REQUIRED：准备全局串行阻挡后续intent、较早重试被已有晚timer阻挡、替换实例取消误删活跃copy、旧flight迟到结束未自动恢复。4个真实RED均已交owner最小修正；尚未合入候选，不用原作者35项通过掩盖新增失败。

iOS第二轮能力附件证实当前模拟器file protection读回nil，备份排除和容量读回正常；生产保护条件保持，明确区分模拟器不支持与实际手机验收。详情和原始artifact身份见[原生报告](../../verification/2026-10-11-native-media-storage.md)。Android完整原生94PASS/1条件skip可复用同源码输入；双端共享候选、Android固定重建与iOS完整插件unsigned包尚待。

## 13:56+08 R9a 已部署

13:55:31–13:55:53+08 仅business-worker切换为`sha256:18a88c4dde6e09fb75122aef1f011fd11c7a0421e61559b0548ed78c1b8b3ecf`，worker.py SHA `96f67aa7ed95a98b91650cf487033dcf8237564ac4ce17a899ded05989a2d72d`。schema0095、API及其余容器ID不变，HTTPS API/Matrix与worker健康通过。13:56:10+08 后验running/healthy、0 restart/OOM、有限500行窗口实际4行、0 traceback/ERROR；样本不作为慢任务或容量验收。

部署脚本最终SHA`dc5e6dc8f02f6f1d01d79bb635fcab6545b57b105aa048a34d1cc542c4a94b44`，独立规格→质量及11项无副作用故障分支通过；旧版本未执行。内/外层guard失败、wait/清理异常均视为不确定，停止自动回退；只有切换明确成功后后验失败才自动回退。回退镜像仍为`sha256:5a9cec63cc780e1e3cc769d3f249e120499bdfc5a37a99419302bd1c862bdbe1`；冻结配置/旧日志保存在`/opt/starchat/releases/im-worker-jit-20261011/private`。历史死信不重放，金融handler/schema不变，active handler超五分钟R9b仍未修。完整receipt和review见`artifacts/2026-10-11/im-worker-jit-deployment/`及`im-worker-lease-independent-review/`。

13:54:33+08 只读正式版本仍两端0.4.44+2213、无2214下载文件；源码候选升为0.4.45+2214（522b2e22），既有版本/隐私4专项PASS。尚未构建/上传客户端；新版本号不表示产品发布。

## 15:18+08 共享回归纠正及 R9b 第一阶段发布

9902d350 初次完整 Flutter 门禁出现媒体调度/缓存准备两个真实缺陷，以及环境/夹具问题；朋友圈视频用例十分钟超时、后继 reentrant 后人工结束运行，未声称全套完成或全绿。原始 flutter-final.log 保留在 im-reliability-release 下。补齐两个空历史 fixture 父目录、使用本任务 W 短路径后，恢复/身份三文件28 PASS；Moments legacy-ready 两个路径超长失败消失。视频草稿测试在清理阶段挂起，测试阶段探针定位 clear start 无 end；同一 real async 生命周期包含清理、保留所有断言和原延迟并加45秒边界后，两份完整 Moments 文件33 PASS，独立审查通过。旧主题变量名字面契约纠正后单文件10 PASS；原边界组400 PASS/1 FAIL/1 SKIP 的历史结果不改写。

媒体44dabcc9修复了调度前过早占用内存预算、worker hash之前未登记store flight两个问题，作者87与111项影响组通过但有重叠。独立审查额外复现 late-store 最后observer取消仍写入缓存；基线9902也存在，属尚未关闭的既有边界，已交作者补充修复，不能把作者通过视作最终共享门禁。36de3670修正不可变快照与转发实际settle测试契约，83专项/66相邻及独立双审通过；不含可执行产品行为修改。

R9b源码9920947c（root集成91d48d03）只新增必填代次Consumer接口及Worker调用，保留原schema/财务handler；root独立规格→质量及49 PASS/1 PG fixture SKIP/1既有active strict XFAIL。第一候选13f3c67b于07:04:04Z切换后启动失败，脚本确认切换完成后按设计回滚；15:08+08确认18a88c4d healthy/0 restart。根因为镜像pip安装的Consumer位于site-packages，而首候选仅覆盖/opt源码副本；首轮隔离pytest覆写PYTHONPATH隐藏了真实导入，原镜像协议守卫也未覆盖此组装。该首轮不算成功发布，记录与审查缺口均保留，不宣称队列用户可感知无延迟。

第二候选同时更新实际安装Consumer和源码副本，并保持worker同一冻结版本。默认cwd/importpath下构造main导出的Consumer(None)+Worker(empty handlers)，不执行handler/DB；旧候选RED、新候选GREEN。隔离pytest仅append工具zip、不覆写生产importpath，49 PASS/1 SKIP/1 strict XFAIL，实际argv/image/SHA/退出码在default-runtime-receipt.json；三镜像协议检查与独立19个部署边界mock通过。

07:15:57–07:16:20Z第二候选部署PASS：worker `sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a`，容器db3001d6，worker.py f88387d6、实际installed Consumer a2e60611，默认路径现场读回一致；schema0095、其他容器保持。07:18:08Z后验healthy、0 restart/OOM、API/Matrix HTTPS200；有限500行窗口实际3行、0 traceback/ERROR。回退18a88c4d；证据 `im-worker-fence-v2-deployment/`。active超过五分钟仍可能被重新领取，代次校验防止旧worker篡改新队列状态，不能代表消除重复外部副作用。

iOS完整插件unsigned候选run38118485155（9902）两个job SUCCESS，但不含后续媒体修复，需最终冻结后重建。Android native-storage2214-r1被安装前包名守卫拒绝（全局Gradle false覆盖环境变量）；调整仅测试构建系统属性后r2固定75b31重建/对齐/签名/内容/包名验证通过，APK SHA7ec5863b。5558 streaming安装长时间无进展，停止已核身份的本次adb client；确认无包后同一APK非streaming安装成功。真实原生目录保护fixture通过，SQLite持久附件fixture报libsqlite3.so未找到，作者正在核生产bootstrap与测试初始化差异。此时没有客户端发布，也未触碰5556已有测试数据。

下一步：关闭媒体late-store边界并增量独立复核；修复/解释真实Android DB初始化门禁；冻结新共享输入，运行完整Flutter/analyze及Android最终ARM64固定重建，重建iOS完整插件unsigned交付。真实手机、iOS最终企业签名/OEM审核与长时间场景验收仍单独记录，不虚构到达率、功耗或P99。

## 15:37+08 数据库初始化顺序根因已关闭于源码

Android r2 实际失败已确认是生产初始化顺序耦合：sqflite_common_ffi 每个调用 isolate 只创建一个 SQL worker，首次 factory 的 ffiInit 决定载入库；metadata 先开会查找未打包的 libsqlite3.so，Matrix 先开则偶然正常。9218be37 已集成 a37fad28，六个 metadata 默认入口统一使用现有 SQLCipher loader；未改变 schema、key、PRAGMA 或文件格式。真实 Windows DLL 两个全新 isolate 的 metadata-first RED/Matrix-first GREEN，修复后两者GREEN；11文件135 PASS、九文件analyze0，独立SPEC/domain→QUALITY通过。不能将此计为Android验收，原native r2失败证据保留。

Android原生fixture追加两种全新isolate冷启动顺序、真实channel/文件seal/默认factory、原件持久与取消、明文metadata和加密Matrix文件头、正确key重开及错key拒绝。iOS既有SQLCipher native target另增两种cold order（df1b3e92→218d2c73），不依赖或放宽模拟器文件保护；root独立静态双审通过，原生执行待最终候选CI。07:33:16Z只读复查worker仍bfde7c86/db3001d6 healthy/0 restart/OOMfalse。永久protocol guard漏检修补及缓存c3c66fbc增量双审并行进行。
## 15:53+08 原生与发布守卫进度

Android r3实际3用例通过（Flutter+4含tearDownAll），源码0fc080e5、APK0c0fbd6b，完整固定重建/签名门禁通过；5558专用包及W映射已按身份清理。见原生报告。缓存c3取消修复独立审查新增cross-source同digest共享flight回归：parent44dab两例PASS，c3控制PASS/取消FAIL，已阻止集成并交owner按聚合有效消费者修正。原7边界全部PASS也不能掩盖新增失败。

永久worker组合guard 7407f374→bd3ab547已root独立SPEC→QUALITY通过：40专项、915 infra PASS/20显式PG-DSN skip；现在线上bfde、回退18a与APIa935均通过新检查，首次坏候选13f3精确因入口构造缺接口被拒绝。原八项worker协议及九项API协议全部保留。安装器单独独立审查发现预检后source再读、恢复backup未验hash、失败临时文件残留三个边界，已RED→修源码，等待同组增量验证；未在审查通过前安装，也没有业务服务重启。Android2214分发准备已分离委派，不含虚构APK SHA或未通过门禁的发布动作。
## 15:55+08 永久发布检查已安装

07:54:59.806–07:55:11.325Z永久ops pair安装PASS，probe SHA2a6de21d、guard SHA46d98c6e。源码bd3ab547经root独立SPEC→QUALITY；安装器独立初审及增量19真实临时文件/mock边界最终PASS，精确installer SHA cc9b1de8。已保留旧字节/权限/uid/gid于`/opt/starchat/releases/im-worker-entry-guard-20261011-2a6de21d/private-guard-before`；校验后固定bytes替换、失败仅恢复本次精确身份，不读未验新source或损坏backup。actual installed guard验证线上bfde、回退18a各九项Worker与APIa935九项全部通过；全体业务容器ID保持，无服务切换/重启。历史部署脚本中的旧guard SHA是当时证据，不回写；未来部署预检使用本次新SHA。receipt在im-worker-entry-guard/installation.json。

## 16:28+08 缓存及发布独立复审的增量发现

缓存44dab/c3/34d已在root集成为8dd1fa87/36ace392/89243647，但未构建或发布；34d共享对象需求聚合独立13边界及4公共播放场景通过。随后实际公共播放入口复现A仍卡在store-root准备且被取消、B独立有效缓存已完成、B等待准备集合时被A取消异常误伤，1 PASS/1 FAIL；最终候选未批准。审查d111a295集成30e31d16，作者最小修复及104影响组通过，待独立增量复核；不将此前局部通过当作整体通过。

Android发布准备4341d844被独立审查拒绝：静态捕获CRLF被Git归一化导致跨工作树SHA不匹配；自动回退重读未验backup可能写回损坏内容。71748829保留原live SHA并恢复Git原始捕获字节，自动回退只用预先校验的原始buffer，91a5f9f5存30项原始Git blob导出PASS证据；仍待独立复验。没有上传、云操作或生产配置写入。真实APK及最终三组门禁尚缺，准备审批不能替代成品审批。

root另外对本地2213成品SHA08a74481进行14个ARM64 ELF静态检查，libcrypto四个PT_LOAD仍4KiB，NDK readelf独立确认；候选仍选flutter_openssl_crypto0.5.0/预编译OpenSSL1.1.1q-beta-1。新增P1兼容性风险与受控源码重建/双页大小已知向量修复门禁见[原生页大小记录](../../verification/2026-10-11-android-native-page-alignment.md)。未据此宣称已有16KiB设备故障，亦未更换加密库；不属于已完成修复或API28存储验收。最终2214也须记录实际ELF结果，ZIP对齐不可替代。

08:26:10.958Z只读版本复核：两端仍0.4.44+2213，下载目录无2214文件，version-preflight-4.json保存。下一步：两个独立增量审查收束、root冻结新共享输入，完整Flutter/静态/边界门禁与最终固定签名ARM64重建；同源iOS完整插件候选重建。外部签名/真机/OEM及长期容量缺口继续保留。

## 17:04+08 最终回归的单项失败与同源 iOS 成品

缓存最终76678477及独立941fefe已集成c6003afe/5988deb4，取消准备中的A不再误伤有效B，104影响组与独立9项通过。Android发布准备717488/91a5及独立d57a/29be也已集成；14个静态捕获原始字节与live baseline逐项相符，准备审查通过但尚无实际2214发布包。永久guard安装后35容器保持健康状态的有限后验已记录。

冻结5988deb4、manifest5e5778f1（2101文件）于08:34:27Z运行final-r2：Flutter自然结束5957 PASS/9 SKIP/1 FAIL（08:42:51Z，exit1）；analyze零问题、boundaries401 PASS/1条件SKIP、三项policy PASS。完整原始失败与日志身份见shared-final-r2-summary.json，不能称全量通过。唯一失败是搜索媒体网格HTTP计数1→2；隔离trace确认初始两bubble共享HTTP1，但固定pump结束后过早离开，所有消费者取消时缓存尚未发布，后搜索正确重新下载。作者f59cf233只增加初始双bubble真实解码的有界等待及导航前HTTP1断言，搜索后原HTTP1断言保持；29影响测试通过，运行时代码与5988完全一致，独立复验进行中。

iOS run38125303494的完整arm64 device job SUCCESS，29生产插件/46框架；IPA34964622bytes、SHA0fad8d42bcab9439ff35951e44b7f0df6b284660200b23b576f6d12ce72a4d3b，下载ZIP及IPA SHA/CRC本地核验通过。原生模拟器job仍运行，不把device build当作native acceptance。该包源5988；后续test-only修改若运行时/原生/依赖/workflow闭包完全一致可按影响分析复用，无需重新编译同一运行时代码。尚未企业回签、真机覆盖或发布。

下一步：独立审查test-only修正后集成并冻结最终输入，完整共享Flutter回归；复用未改变的门禁须逐项绑定输入。刷新线上双端2213版本后执行最终ARM64常规重建/固定75b31签名，真实成品经独立评审再按阶段发布。R9b-2长handler续租及OpenSSL16KiB受控实验在隔离树推进，尚未生产部署或集成二进制。官方OEM审核/最终iOS签名/真机及长期SLO仍缺资料。

## 17:15+08 独立复验拒绝 test-only 等待修正

f59cf233独立完整文件首次0 PASS/1 FAIL，新增双bubble解码断言实际1；两轮synthetic诊断复现。一开始的“另一bubble可能未可见”猜测被实际geometry否定：old-image(60,464)-(61,465)、neighbor(60,401)-(61,402)，viewport(0,44)-(800,520)，两者route/ticker有效，defer/scrolling为false、同descriptor、总HTTP1。old持续placeholder，neighbor已解码。新增测试尚未集成；不能仅改断言为一个decoded/公共cache存在，需追首consumer真正完成时序。独立拒绝e0bfd5f4已归档，含17身份PASS及原始失败/诊断编译修正记录。作者隔离获ContainImageBubble最小诊断及必要根因修复所有权，root不改同文件。

iOS38125303494双job于09:06Z前已SUCCESS。三native targets实际13+6+1=20 PASS/0 SKIP/0 FAIL，全部首次执行exit0、无attach stall/hard timeout；两cold-order在SQLCipher六例内。该组与先前文件保护XCTest的4 PASS/4 capability SKIP分开，未声称真机保护通过。IPA与ZIP完整性本地再次校验：Runner bundle/version/build符合，46framework含SQLCipher/OpenSSL/WebRTC/Firebase；Runner无profile/签名资源，依赖内8个既有签名资源条目不能被误称为最终企业签名。摘要ios-final-r2-verified-summary.json。后续若需修运行时代码，该5988构建须作影响复核，不能直接称最终成品。

09:05:39Z线上版本只读复查：双端2213、无2214下载文件。root已集成OpenSSL静态实验文档4197721a/54e7168f，40份字节/hash一致，未集成crypto二进制/依赖；生产compatibility验收仍开放。下一步仍先关闭有效可见首consumer的pending边界，再冻结/完整回归/最终构建；客户端未发布。

## 2026-10-11T17:45:57+08:00 最终候选整合与 final-r3 冻结前检查

继续既有用户授权；root领取最终组合冻结、共享门禁、实际Android成品/发布与任务索引，agent各自拥有独立部署/评审目录。R9b-2源c3dd3142及独审cc1c3727已整合为62d0786d/20a04c9c，4源+6测试SHA逐个与作者清单相等。342作者影响用例和35独立唯一用例证据保持原范围；尚无新worker镜像部署，线上仍bfde7c86。部署准备由backend_review独立执行，worker切换安排在客户端发布后，避免破坏客户端精确容器基线。

搜索网格诊断纠正17:15假设：没有证据证明永久丢失完成通知；序列化可选缓存写入在清理阶段额外pump才完成。非规范Windows路径还触发持久化目录枚举错误。f59单独被拒绝保持，最终f186仅test的canonical路径+同10秒真实deadline内16ms I/O/帧推进经原RED环境独立SPEC→QUALITY通过。阶段诊断两次persist-done均在assert前、零error；无trace完整十场景文件1PASS，真实2053ms/104pumps/fake1664ms；双decode2、导航前后HTTP1未放宽。集成为ad38bf67/04e712f3，独审8dc15a2a→f7097dea，10份独立证据原始SHA/bytes全部核验。

最终运行时代码与5988相同，只有一个测试文件改变。final-r2 5957/9/1历史失败保留；下一步冻结final-r3并运行完整Flutter+analyze。边界用例自身虽未变，但privacy扫描包含新server代码，补跑该影响范围；policy输入未改变可复用精确范围。Android原生3项及iOS 20项/unsignedIPA通过运行时、依赖、原生、workflow闭包比较后绑定复用，不重复编译相同代码。全仓verify前置.env缺失继续明确为未执行，不能称全仓PASS。然后刷新线上版本，ARM64源码→常规重建→固定75b31签名及实际成品独审。

## 2026-10-11T18:18:37+08:00 final-r3 全量通过、Android真实成品冻结，待独立发布审查

源码候选e9d297b2b49c8b2198fb3225bf7e04ed80ab4bd8，2101 mobile输入manifest f7a9a63d118bb39994907e6d37e8179ebe3f78cb75e18db6ac0141b96b29a687。完整Flutter09:46:15–09:54:26Z自然完成，5958 PASS/9 SKIP/0 FAIL；analyze零问题，边界401 PASS/1条件skip。policy三项按18个真实依赖路径及动态前提不变复用；首份policy-reuse路径闭包不完整已保留并明确由v2取代。原生API28三项和iOS 20项/unsigned IPA通过闭包核对绑定到该候选，范围不扩大为ARM64手机或16K验收。证据在shared-final-r3-summary.json与final-gates-r3。

真实Android构建09:55:51–10:01:31Z，5分40秒；固定Apktool2.12.1重建/zipalign/75b31签名等28步骤全部exit0。最终0.4.45+2214 ARM64，73336097bytes，SHA575e24f4c841ed2388311ba19c06e23623838022ed2a438df6c56642436af614。25414 smali类/清单语义保持，274 native+assets字节保持；14 native库、实际Matrix13FUNC导出和锁定AAR strip-aware对应经独立NDK读回。libcrypto仍与2213相同且4KiB LOAD，16KiB静态子门禁exit1保留。十项RELRO末端观察与2213相同，仅crypto观察到保护尾页后续RW段交集；不据其他九项模数声称已复现崩溃，真实16K运行仍未验。Kotlin插件迁移及deprecated/unchecked旧构建advisory未抑制，作为后续维护项。

真实发布package final-package-e9d297-r3 已在本地冻结：freeze SHA b1abd1b18928d8f0306077bc64ff3d09f286b5af11c17a9344f877961abb8297、runtime SHA1be3d1abdf7da35e26e363ae786b5334e5cd279d620a6d56bb9dd33be5e7c0f5。当前仅PLAN_ONLY检查；独立SPEC→QUALITY进行中，没有2214生产发布。source回填预检发现android-release.json仅本地CRLF381B/线上捕获LF372B差异，Git blob严格等捕获；具体local raw CAS+Git before等captured方案单独待审，不修改生产before哈希。

R9b-2候选abda33f8镜像已在隔离入口检查70 PASS/1真实PG配置skip、三镜像协议通过；临时probe全清理，60个全部容器name/ID前后不变、running仍35，worker仍db300/bfde。部署准备及独立证据身份最后复核中，未切换。下一步：独立审查精确客户端package后按既有runtime→upload→assemble→HK/CDN→CAS发布→audit，再严格回填两文件；客户端发布后才执行worker守护切换。

## 18:26+08 最终证据 Git 原始字节归档校验

首次暂存发现两份最终包 JSON 被 Git CRLF 归一化，raw/index 比较主动拒绝继续；原始差异保留在 git-evidence-stage-red.json。修正包目录外的 .gitattributes 并仅对这两条路径执行 --renormalize 后，81 份暂存文件逐字节匹配工作区，身份清单为 final-r3-git-evidence-identities.json。实际冻结包文件没有修改，freeze SHA 仍为 b1abd1b18928d8f0306077bc64ff3d09f286b5af11c17a9344f877961abb8297；没有重建或重新冻结未变更的产品。属于证据归档 RED→GREEN，不是产品回归修复。独立实际包审查已完成主要读取，正式 review JSON 尚待交付，生产尚未发布2214。

## 18:46+08 Android发布、分发后验与worker有界续租上线

客户端runtime于10:29:36Z完成双主机实时基线及工具校验；5分块上传10:31:39Z、assemble10:34:48Z、HK不可变安装10:35:01Z；CF新增精确路由10:35:28Z为InProgress，10:36:32Z实查Deployed/HEAD200/CORS通过，policy保持。HK别名10:36:50Z切2214；publish10:37:12Z PUBLISH_PASS；10:37:30Z actual route/audit读回PASS，仅Android version/build/notes三条审计，iOS2213、两端minimum3及URL保持。operation为im2214-e9d297-r3-20261011，9份原始phase receipt位于实际包execution目录。公开不可变APK SHA575e24f4…af614、73336097B，无完整公网包回拉。

本地两分发文件按独立c17540评审回填。首个operator检查误把Windows反斜杠传入Git对象路径，exit128发生在全部写入之前，两目标raw未变；修正仅POSIX Git路径后，所有raw+Git双CAS、exact staged after及5本地preserved身份通过。原始operator失败说明与最终receipt均保存，生产before哈希未改写。admin-home已有本地/生产内容差异保持各层原样，没有夹带上线。

worker10:39前重新核16个远端冻结输入、旧bfde/db300 healthy/0 restart/noOOM、all60/running35身份一致。10:39:52–10:40:17Z只切business-worker为abda33f8/db5d65ff，wrapper exit0、deployment.json settled PASS、5源SHA精确、schema0095、其他容器身份不变。回退镜像bfde及私有配置/旧日志保留。独立10:42:11Z只读后验结构通过；有限10行窗口1条warning，正在另作allowlist分类，不据健康或短窗口宣称全周期无错。

工作站通过自有loopback SOCKS/jumper完成4项HTTPS检查：公开android-release exact after SHA、CDN APK HEAD200/73336097B/CORS、APIready200、未鉴权app-updates401。未使用真实用户token/伪造生产会话，实际认证route函数投影和三审计由服务器单独证明；自有tunnel已退出。iOS企业最终签名/覆盖数据、Android最终ARM64实机/16K/OEM/Doze、端到端P50/P95/P99与功耗仍明确未验。

## 18:59+08 warning已定位且保留业务待核验

独立原始10行/1warning结构快照及后续4行结构格式未识别均原样保留。root进一步仅允许从源码AST固定字符串中读回JSON的level/event/component/reason_code/status，未输出原始message、金额、地址、token或异常参数。扩大的后续窗口为maintenance_state/manual_maintenance/WAITING两条、source_health/funding_source/BALANCE_UNSTABLE与RECONCILIATION_PENDING各一条（statusOK）；枚举receipt为worker-warning-static-enums-r3.json。两窗口不同，不相减或推算发生率。

这些是资金监控等待/稳定性/对账状态，不能写成无告警或已业务正常；本轮不更改财务策略/账务/阈值/审批，不读取资金明细或重放历史DEAD。候选仅覆盖五个已评审worker/Consumer源文件，金融维护模块及运行配置保持；这也不证明同一状态在此前时间窗口已经发生。后续需单独领域运营复核，保留P1观察项。IM续租的源码/镜像/settled发布及结构后验通过范围保持；有限样本租约失败/error/traceback计数零不代表全周期无错。独立文案复核发现构建时长算术笔误，已由6分40改5分40，起止和原receipt未改动。
