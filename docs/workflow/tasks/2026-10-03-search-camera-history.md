# 搜索、系统相机与三天历史任务

启动可靠观察2026-10-03 23:08:16+08；记录2026-10-03T23:14:02.877150+08:00。用户报告正式Android0.4.27/2196：搜索加载文字抽动，一天前点击加载失败，要求去年消息可跳转；MagicOS8.0/荣耀50Plus/Android14拍摄/录像显示拍摄失败；新设备/同设备切账号加载最近三天群聊/私聊并正确解密。此前自主ADR/计划、debug安装、main集成授权保持。新设备是否完成密钥恢复的可选问题待答，不阻塞独立工作。

状态：调查/计划；基线main c69d07cf，已交付2197debug尚不含此三项修复。主仓1387项既有WIP保持；新managedworktree/branch codex/search-camera-history-20261003干净。产品code仅声明任务领取后改。计划../../superpowers/plans/2026-10-03-search-camera-history.md；规格../../superpowers/specs/2026-10-03-search-camera-history-design.md；证据../../verification/artifacts/2026-10-03/search-camera-history/。

初步证据：chat_search_page._historyChanged将history全部当安全失效并clear/restart；room_page._scrollToMessage仅openAnchor当前窗口后反复loadEarlier；SDK已有日期context却无显式事件locator。相机manifest无IMAGE_CAPTURE/VIDEO_CAPTURE queries；固定plugin grantUriPermissions依赖queryIntentActivities逐个grant且启动Intent不带通用URI flags。Matrix同步只sync/uploadPending，未看到72h全部房间hydrate。均为待行为复现的候选根因，不把源码推断当真机结论。

验收ID S1搜索/旧anchor，C1系统拍摄，H1三天历史+密钥恢复，D1相关最终门禁与实际debug安装。每项分别记录实现/测试/发布/物理验证。E2EE保护ADR设计及双审必做；无用户密钥不能保证历史解密，保持缺密钥状态。

下一步Task1独立规格/领域、质量/安全复核，修正重要发现后转交Task2相机；Task3 ADR设计已通过有序复审，源码尚未启动。root不编辑转交源码、不并发Flutter/Gradle。

## 调查更新

用户明确新设备“没有恢复步骤或尚未完成”；现有MatrixSecurityPage无实际导航引用，恢复按钮只unlock/maybeCacheAll而未loadAllKeys。Task3范围增加可达且完整的用户密钥恢复入口、真实匹配备份版本和恢复后重试，SAS现有不完整UI不得当作已可用转移。ADR设计正在独立审查。Task1实际SDK/Widget RED证明3次查询而应1次、旧事件anchor返回false；同组原有日期20case通过，task-1-red.log实际exit1。

2026-10-03 23:45:34+08：Task1源码提交6df1fc376c54e413a168ec6a96097bf1e5673df4，25文件聚焦224PASS、14改动文件analyze零问题；最终输入hash和实际失败迭代保留task-1-report.md。23:51+08进入独立审查，尚未称真机修复或构建新包。Task1释放Flutter/Gradle和源码所有权。

Task3设计ADR SHA256 9e831d5f7767b1ad773f108456bf2c4887e1ed44e2b49504ec57f74170d090c4 已通过领域/规格再质量安全审查。recent-history-design-review.md §6记录另一个既有问题：创建按钮仅创建秘密存储，首次在线房间密钥备份不完整。无现成密钥时不能声称恢复完成；新备份/SAS额外路径需先补具体保护设计并审查，不能替换未知或已存在备份。旧手机/现有恢复材料的可选问题保持待答，不阻塞Task1/2或既批密文补齐与真实密钥导入工作。

2026-10-04 00:00+08观察：Task1独立审查确认两项P2（用户中段向旧消息拖动未传播SDK定位取消；网络/超时被误标未找到）；actor正在fixround1，尚未转交Task2。此前224PASS并不替代这两项回归证据。Task3设计actor仅只读提出真实同账号SAS旧设备恢复的最小方案，额外路径仍需ADR修订及独立设计审查后才可启用；没有新增备份/信任写入或服务器操作。

用户最新确认：旧手机和恢复材料“两者都没有或不确定”。保持已批Task3密文补齐和现有有效备份的真实恢复范围；SAS提案只归档、不作为已实施能力，不扩大当前保护改动。检查实际本机密钥/已有备份后分别显示可解密、缺密钥、备份不可用/未知；材料确实全部丢失的旧密文无法从登录密码重建，保留数据，不假称恢复完成。

## 2026-10-04 服务端托管需求覆盖

用户随后明确要求“转变为服务器存储密钥”，安全设计以便捷使用为前提，正常用户不应处理密钥。此最新直接指令覆盖先前用户提供的禁止服务端持有恢复密钥规则，仅扩展Matrix通信恢复材料托管；业务/钱包密钥、消息/附件明文及日志禁泄露规则仍保持。正常登录后自动备份/恢复，不将手工恢复密钥或SAS作为必经步骤。服务器获得恢复密钥能力，不能继续宣称服务器无法解密托管历史。

旧版Task3的独立游标72h、账号所有权、实际写入drain、窗口内存边界仍适用；其client-only恢复部分待新ADR替换，尚未执行。原有在线备份/SSSS不重置；优选独立Matrix托管加密session归档，可迁入现有本机session，即使原生备份锁定仍可保护这些可用材料。彻底丢失且未备份的密钥不能凭此重建，状态须真实。

Task1源码0cdc678d已通过有序复审，F1/F2关闭。Task2 sole actor honor_system_camera_fix在实施；Task3 server_recovery_custody_design只读提案中，root制作新ADR/规格/计划并完成独立领域及质量安全设计审查后才转保护源码。服务器仅只读核对：Synapse1.132.0/SHA99643e454f82…、PG schema92含99_chatflow_media；主/worker/S3与Getui v1保持。精确配置hash及公开源码绑定在server-custody-*.log/pinned-synapse-source，不读取用户密钥/session内容或打印生产凭据。尚未构建新包、迁移DB或发布新服务。

2026-10-04 00:56:59+08：Task2源码41c49c7已通过独立领域/规格及质量安全复审，71Dart/8native/analyze0；Robolectric test-only deprecation如实保留，未声称荣耀真机验收。Task3服务器托管具体ADR/计划已通过有序复审，D1真实SDK格式/房间绑定和Q1每key独立灾备先于激活的设计要求闭合；报告a7eebb57...。下一步唯一implementer Task3A服务端authority/vault/OS provider与真实隔离测试，之后3B自动迁移/恢复/72h。尚无新包或生产启用。

Task3A实施起点：2026-10-04约01:01+08，唯一actor server_recovery_vault_implementation，BASE bdcdf3c3。01:14+08 root实际只读freeze生产Businessimage001ddf336b3b268b530bd9223d48cdb48ff3835ea674cbba245765905689b71c；identity.py baseline rawgitblob SHAa11669d6...完全等于生产，同模块matrix_sessions/tokens/models/matrix_login均一致，后续须再次freeze后最小增量及续期协议gate。Linux主PID1 UID/GID991，workerPID1 UID0；必须main-only最小mount+worker无凭据mount，不能以root exec假验权限。root专用internal网络和PG16.9 testDB已连通，SSH L15464→172.24.0.2:5432 session40479保持；首次internal network publish未生效的失败与修复分开记录，未触碰生产DB。官方固定Windows cryptography43.0.3/PyNaCl1.5.0轮子经官方SHA和本地传输SHA验收，独立venv用，不改业务crypto依赖。PublicSynapseauth/http代码原字节同image导出供审核；尚无newprovider/迁移/vault生产启用。记录 2026-10-04T01:17:47.4478406+08:00。

2026-10-04 02:25+08：root真实外部门禁已通过：Dart标准SDK/nativeOlm3×5互通；Linuxsystemd255+严格SSH+WindowsCurrentUserDPAPI10项中断/重试/先确认后激活、UID991只读；真实pg_dump→删除隔离primary及namespacehostcredential→仅DPAPIsealed恢复→freshDBpg_restore→3份原始SDK加密归档和Megolm原密文正确解密，混合old/new/实际rewraprollback+partialcommit均PASS。source/evidence精确hash task-3a-root-external-gate-inputs.json；初始化namespace/docker.sock失败保留，成功seed及resumedDR分开记录。生产密钥与DB未改。HTTP隔离root挂载credentials复数错误已修为credential；真实keyring/matrix/Business首次校验PASS，第二native get_user_by_req触发SynapseRequest setter重复设置断言(site202)，actor正在保留token/accountvalidity/Business二次检查的最窄修复。上下文helper按固定core规范补齐并非该断言唯一根因，失败如实保留，HTTP尚不PASS。下一步最终真实接口与logger/worker边界，3A有序独立实现双审，再3B sole implementer。

2026-10-04 02:38+08：真实native get_user_by_req不可重复设置request.requester根因已修（保留核心tokenexpiry/accountvalidity/freshuserinfo/tokenlookup/Business二次校验），transport gate实际exit0包括请求中途logout→material401；真实SQL DEBUG记录3250非recovery/0recovery、query/body/candidate sentinel无泄漏。TRACE协议错误例外及方法级安全元数据日志R2获领域/规格→质量安全设计PASS，报告最终9a90fd8f...；真实TRACEquery父级日志泄漏P1仍未关闭，actor实施R2两个include。生产nginx -T只读freeze：HTTPaccess /var/log/nginx/access.log main，error /var/log/nginx/error.log notice，/ios-call/locationoff；实际access/stdout,error/stderr映射已证明。保留非TRACE原目的地/格式/原条件和notice级别，不global405rewrite。下一步R2同真实sentinel全门禁与真实worker/broker装配，actor显式sourcecommit释放，再有序3A实现双审。

2026-10-04T03:45:32.3695902+08:00：Task3A源码5fe56e59已完成24文件提交。独立领域/规格→质量安全实现审查报告03b26f61…仅一项P1：最终Business响应期间撤销Matrix仍可能释放material，precommit第二响应期间撤销还可能落库后返回401。Root真实隔离HTTP RED复现三路（material200/private；enroll/upload401但六表及account统计变化），随后候选vault6ebcc5bd…有限本地fresh token/account检查在每次Business响应验证之后，真实GREEN三路均401/no-private/六表与revision、bytes、candidatecount不变；业务网络authority synthetic、实际Synapse logout与PG落盘真实。原有完整native R2/首个Business响应期间退出/路由与重放gate复测exit0。旧native-source-final保留，新native-source-r1-fix，生产未启用。初次启动就测试导致URLError的fixture失败保留startup-failure.log，新增45秒启动就绪检查后真GREEN独立记录。Actor真实PG新增专项与commit待交接，独立定向复审通过后Task3B自动归档/恢复/72h继续；原crypto/store/provider/双系统DR输入未变，不重复长门禁。
2026-10-04 03:50:14+08：R1修复source5c6ec924已释放，27专项PASS含12实际PG边界case；root原完整native与MobileLogin/worker装配复测PASS（r1-full-native-green/r1-composition-green）。独立reviewer已恢复定向领域/规格→质量安全复核，仅报告所有权，Task3B需等最终PASS与精确报告hash再接入。

2026-10-04 04:02:48+08：Task3A有序实现复审PASS→PASS，R1关闭，最终报告256c180e…；fresh sole actor mobile_automatic_recovery_history开始Task3B（model gpt6astra/high，按SDD protected/architecture规则），确切接受brief task-3b-brief.md。Mobile/SDK/lifecycle/store/recoveryUI/HTMLregistry及tests所有权已声明，root不共写或跑Flutter。Root继续服务器候选装配/runtime门禁准备；未启用生产。额外本机真实Olm测试缺WindowsDLL的setup failure不算RED；root在仅自己的隔离Docker中编译same22 source Olm3.2.15 Windows64测试DLL，不改APP依赖或分发二进制。

2026-10-04 04:24:57+08：Root服务器候选最小overlay已生成：API2fd052541347…/Synapse449fef97b26b…，原image分别001ddf33…/99643e45…；无生产容器切换。最终API及回退API各9项+同Worker8项（相同Worker去重，26unique检查）角色续期guard PASS，现行guard/probe SHA78b2beb6/d77a83e8匹配。最终Synapse真实installed site-packages字节（vault6ebcc5bd/原MobileLogin d164566d）验证、mainUID991/workerUID0无mastermount、finalBusiness撤销三路/完整native/真实broker worker装配PASS。原counter fixture被移到独立diagnostics-only PYTHONPATH，未覆盖productmodule；第一次缺counter启动失败137保留，修正后exit0。

Root完成实际operator runtime安装（专用Python3.12/pins/pipcheck）与global系统凭据unit：新IDprimary_20261004_5c6ec924先inactive，经严格SSH sealed→WindowsCurrentUser DPAPI原路径独立保存/读回proof确认，再active。真实LoadCredentialEncrypted unit未active ring拒绝、active start/restart成功/ExecMainStatus0、真正UID991 fork能读不能写/file0400+parent0711均PASS，已enable。systemd255show属性实际[unprintable]导致首个fixture断言失败、第二次错误从crypto导入load_keyring导致reader fixture失败，两个失败保留；最终验证绑定已审unit SHAe4d78f24…并使用actual vault loader后exit0。无credential值进入日志/仓库；真实持久key/独立DPAPI不是临时测试材料，不得随隔离容器清理。生产Recovery namespace未启用、生产DB/原容器/网关配置未变；Task3B仍正在实施，下一步复核/测试与精确服务发布装配。证据身份task-3a-server-candidate-runtime-inputs.json。
## 2026-10-04 引用会话续接：Task3B外部门禁与独立审查

本会话从原会话修复钱包与搜索并发布更新的最新失败turn恢复；未重做已发布的钱包/主分支整合。原工作树ab9e6d15保持，sole actor已提交29文件并释放。Root拥有本任务记录/current-state及task-3b-wire-*验证文件；独立review_task3b只拥有review报告；独立sqlcipher_fixture_gate只拥有task-3b-sqlcipher-*验证文件。主目录既有WIP不变。

真实native candidate449fef97/gateway/PostgreSQL通过SDK archive→正常native broker新device（旧Matrix bearer401）→freshSQLite→真实Megolm解密。实际public vault中归档外层session改名与MAC篡改，consumer均0import；错误sender0import、错误version404、原有效session及解密保持。Business网络边界明确为隔离synthetic JWT authority，非真实Business会话；不将此结果称生产端到端验收。两次fixture启动失败为非秘密wire-code目录读取权限错误，修正目录0755、文件0644后通过，不是productRED。

证据task-3b-wire-archive-initial.log/restore-initial.log/restore-negative.log与task-3b-wire-exchange_test.dart。测试配置及合成密文descriptor只存本机ACL-restricted operator目录和服务器isolated/wire-private，不入仓库/日志；已创建专用wire-authority容器和本机会话5673 SSH隧道127.0.0.1:18443→isolated gateway172.24.0.4:8080。发布前或结束须仅清理本任务不用的资源，真实provider/DPAPI不得当测试材料删除。

SQLCipher4.10.0缺DLL由独立fixture builder解决，使用package固定amalgamation SHA512、官方OpenSSL3.5.4 SHA256与唯一隔离容器，不改APP依赖/产品二进制。尚未运行真实encrypted-file gate。Task3B独立审查进行中，已提出重登checkpoint窗口导致重扫、前台nonempty terminal页、匹配native backup有界迁入及replay范围问题；均待最终报告、test-first修复和有序复审。未发布新包或切生产服务。

下一步：最终独立报告→唯一implementer修复→实际SQLCipher及相关最终门禁→独立复审→Task4相关全量/原生/debug交付与main整合；服务器发布依赖保护验收通过，不能用221聚焦通过替代。
实际记录时间：2026-10-04 13:18:07 +08:00

### 2026-10-04 Task4 整批回归与第二轮定向修复（2026-10-04T14:13:29.3119116+08:00）

- Task3B fix1 source: 65eb872678045a2dbf07f9e3ac15a0dd76a94814；233专项PASS/analyze0。独立复审已接受原D1/D2/D3/Q1/Q2，新增P2第二次native元数据GET缺8秒deadline；报告task-3b-fix1-review.md，SHA256 8b8d9109470ce8902eb46d434a4fd66cd0e1293408f9bb238eefae7dfe03110f。
- root整套Flutter实跑 2026-10-04T06:07:55.1365059Z 至06:11:57.9895572Z：5383PASS、9skip、7fail、exit1，原日志task-4-flutter-full.log/json保留。六项为新内部rooms扫描守卫登记/新设备ID fixture采纳时序/未settled DB排空旧断言/三项公告fixture缺room_id；第七为未改输入moment_media_lifecycle重试控件查找，需定向隔离验证，不豁免。
- 整批review新增真实P2：recoveryRoomCounts只有windowStart，无固定windowEnd，后到实时密文可能污染72h missing统计。已核实SQL与replay边界不一致，交fix2真实DB RED/GREEN。
- task3b_fix_round1已获上述窄源文件独占修复与Flutter工具；root暂停Flutter/build/version变更。whole_candidate_review继续只读；prepare_recovery_deployment仅本地helper与只读生产，尚未授权其执行helper。当前未做生产镜像切换或2198构建。
- 后续可执行步骤：fix2最小修复并有序复审→root完整候选回归/真实wire影响验证→版本冻结2198与常规重建签名Android调试交付/同源iOS原生验证→受控服务端发布与主分支整合。
### Task4 最终源码接受与2198平台交付开始（2026-10-04 14:52+08）

- fix2 source70f36e65：259专项PASS/analyze0，有序复审PASS→PASS，报告SHA907957d6c882e500ad612096d6f370e70b910891e235d08b62fef72b91936851；原五项、secondmetadata deadline与W1固定windowEnd闭合。六旧fixture/guard失败GREEN；第七moment未改输入在最终整套中实际通过。
- root清理七测试重复公开SDK类型import，真实全包analyze7info→0，源码8d2c26cf；整套5393PASS/9skip/exit0，移动Python307PASS/23skip。pairedversion0.4.29+2198源码7e7e9a2a，版本契约3PASS；whole-final有序PASS→PASS，SHA20ab8392c03bfacfb481e06d94b9fb556eabd681cdc2f28be2cf14ce6254694c。
- 最终真实wire restore+negative1PASS/SQLCipher retained两例PASS重绑70f（其后仅imports/version，独立接受影响复用），汇总task-4-final-external-gates.md SHA0cefe36619faa867d402aaad64fc8f4ef61380bb229bce6e9e16bdbb4903a779。旧隧道已关闭的首次connect-refused仅环境前置失败，日志保留；strictjumper新forward session43800，root结束后关闭。
- 14:47:39线上只读settings仍Android2196/iOS2194。canonicalpubget lock不变；冻结1864移动输入清单SHAa3c005dc5c58cacc210feb9c8975602ea305a5196b12be7e83784f8fbeeefda7。reviewedbranch已推送；同源iOS native CI37183887834（7e7e9a2a）进行中。
- APK source→Apktool2.12.1完整常规重建→zipalign36-P16→稳定75b31...签名→签后semantics/native/assets/lock/freeze全部PASS，14:51:29完成。final.apk135737571bytes，SHA6fa1801347e38aee8abe3ae98ff7beaf644de396dd3a0e702156af124a5ddbe6，artifact/steps在android-debug/run-20261004-144800。待独立最终APK审查后保留数据install/launch120s；当前尚未安装或正式移动发布。
- 服务helper审查P1 D1（重建前Compose与实际run投影证明缺失）真实RED后修至06b469dc...，12模型/selftest/AST0且只读实际五role/candidate defaults paritytrue，等待有序复审。仍无production prepare/check/switch/approval，真实provider与schema保持。后续：helper复审→rootprivateprepare/check/receipt受控disabled→enabled；debug安装；iOS结果；主分支保留WIP整合与报告。
### Task4 平台交付与服务现场检查（2026-10-04 16:00+08）

- 同源7e7e9a2a的iOS native CI37183887834于15:13:25+08成功，完整生产原生编译及iPhone15/iOS18、iOS26三个job全部success。未生成或分发本轮正式IPA。
- 独立最终Android重建包审查PASS→PASS，task-4-android-debug-review.md SHA43aa6d34e9aaef60b64a9536ec7a54a2a270d015154beba447f31d17fc5504dc。15:54:48+08以adb install -r覆盖emulator-5556成功，0.4.29/2198；UID10090及firstInstall2026-09-26 04:06:20保持。启动Status ok，15:57:18超过120秒仍同PID16734、0fatal签名；task-4-debug-smoke-2198.json。无荣耀真机或真实新手机恢复验收。
- 服务helper经过Compose零值ulimit与gateway省略environment两个实际输入适配修复，各有RED/GREEN与独立有序复审；8be15a3e actual prepare PASS，冻结完整15配置，files.json SHAa57775a5270fd3fe658f40cd029339fb707da053d4aa3b202607fcc94ffafaa1。原服务未变。
- actual check停止于Nginx配置输入流；原失败及安全诊断保留。root匿名memfd/nsenter实际有效配置rc0/故意错误rc1控制PASS，同gateway、无diskwrite。最小helper修至f24380ccf8b62565aaa6206109062d6a01688e3bef265bb8cc0922f06f8702b5；25模型、自检、AST PASS，待最终独立复审、现场check后才能上传审批receipt和切换服务。
- 主目录与远端main只读仍c69d07cf。91个本任务已提交路径与主目录1373trackedWIP仅current-state重叠；1372个无关修改已逐文件SHA冻结，既有索引增补单独备份，合入时保留。下一步最终helper现场门禁→disabled/enabled验证→更新最终台账→main合入推送及自身资源清理。

### Task4 服务实际启用与合入准备（2026-10-04 16:11+08）

- memfd定向规格→安全PASS，报告bb4771461b9d1d681eb84b2364b167ce1a714b328cb2ad5d8152fe7054210162。最终helper f243实际check PASS，root将已真实通过的八门禁hash写入审批receipt，绑定filesa577；没有假设PASS。
- disabled阶段16:01:59–16:03:02+08 deploy/verify PASS。enabled第一次16:03:38–16:04:13 exit1保留；实际网关日志仅按固定路径聚合去敏，业务authorize401后versions502，新main16:04:07启动，符合启动readiness过渡。普通流量的sync200/502不称root匿名probe。后续完整diagnostic verify及stable deploy均PASS，无新配置修改或已匹配容器重复重建。
- 实际provider main-only只读、UID991、worker进程/8081监听/module import及无启动错误、原生route控制、公开401/no-store/private403、8TRACE405/不反射/双流无sentinel/普通日志控制均由完整verify实跑通过。运行状态08:05:53Z及08:09:06Z同ID/StartedAt/0restart，API/main/sync healthy，business-worker/Getui及其他冻结容器保持。
- 工作站strictTLS经自有jumper SOCKS四控制PASS；API真实JSONok/database ready与no-store读回另绑定response-assertions。首错误/health/ready 404是root公开前缀写错，源码实际/api/v1/health/ready已纠正，原404日志保留。08:07:19Z线上移动settings仍Android2196/iOS2194，无正式移动包/弹窗/IPA发布。
- root拥有的synthetic wire-authority已按精确name/image/tasklabel核验删除，不移除真实credential/provider/DPAPI/database备份。主分支合入前公开最终报告docs/verification/2026-10-04-search-camera-history.md；最终执行复审正在完成，随后保留主目录WIP合入推送，确切push身份见task-4-main-integration.json。

生产最终执行独立规格/领域→质量安全PASS，报告task-4-production-final-review.md SHA8994ca18390e2ab02e2e5ac6ca97c36b38011132c19b8b15f407f622e21d635b。公开APK和462项根层证据已复制主目录，final.apk实际读回SHA一致；operator secrets未复制。继续main整合，当前任务无可归档app attachment，原managed工作树留存证据。

### Task4 main整合收尾（2026-10-04 16:14+08）

4f1bf173已快进合入本地main；只有current-state旧尾部条目与stashed iOS回签记录冲突，保留iOS原记录并清除重复旧进度。1372个无关trackedWIP哈希复核一致。当前补充三项文档及仅自身旧进度删除，源码与已审7e7e9a2a输入保持，长门禁按影响复用。最后可执行步骤：提交本轮文档→git push origin main→远端SHA一致→删除已合并自身branch、关闭自身SSH；准确最终结果绑定task-4-main-integration.json，不把原后台活动分支纳入清理。

### 已完成（2026-10-04 16:21+08）

main 0038dd072fdd3cf5e50084d9a6543e01977cdfbb已推送，16:20:36远端SHA读回一致；客户端源输入仍7e7e9a2a，其后仅四项文档。本任务远端及本地临时branch已删除，原managed工作树detached保留验证材料（当前任务无归档attachment），两条自身SSH tunnel已关闭，synthetic authority已删除，真实provider/独立灾备保留。1372项WIP哈希及所有primary索引原段落均验证保留。交付2198 debug已安装/链接公开，iOS三个nativejob成功，生产恢复技术启用双审及现场门禁通过。最终主分支及清理证据分别为task-4-main-integration.json/task-4-final-cleanup.json；本次最后提交仅补充完成记录。当前授权交付完成，后续设备反馈单独记录：荣耀拍摄、新手机真实用户恢复、K80性能；没有本轮正式移动版本、弹窗或IPA发布。
