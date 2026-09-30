# 移动稳定性反馈实施计划

> For agentic workers: 使用subagent-driven-development分模块执行；先red/green，先规格审查，再质量/安全审查。各owner不得同时修改同一文件。

**Goal:** 修复用户指定验证码拒绝状态、系统锁屏聊天入口、消息负载交互及本地历史搜索，报告真实埋点限制并安装Debug。

**Architecture:** 保留既有身份服务/唯一索引/OTP语义，OS系统锁屏拦住主界面并按生命周期延迟通知路由；聊天历史只在设备内检索。沿用有界PerformanceTrace/ChatDiagnostics读取性能和业务网络证据。

**Tech Stack:** Flutter3.44.9/Dart3.12.2、现有Matrix SDK/本地SQLite、Kotlin/Swift、Python3.12/FastAPI/PG16；Android固定签名常规重建。

执行依据为用户本轮明确缺陷与预期及已批准原功能规格，修复已确认回归不重复申请许可；新增产品语义或生产服务发布需单独处理。起点b36a2911，已有其他模块改动保留。

## Task 1：绑定拒绝与唯一性（OTP owner）

Files：phone_rebind_page.dart、email_rebind_page.dart、account_credentials_controller.dart及必要闭合error helper；phone_rebind_test.dart及新email失败测试；services/business-api/app/modules/identity/phone.py小增量与新专属uniqueness测试。不得覆盖其他服务源。

- [x] 失败测试：已获旧渠道证明的用户输入他人/本人已绑定目标，API409/422拒绝后，按钮恢复“获取验证码”，输入框enabled并可马上输入新目标；明确未发送的服务配置错误同样释放。真实timeout/generic未知5xx保持既有冷却，成功保持resend_after。
- [x] 最小修复：在现有错误处理使用闭合状态/代码区分明确拒绝与未知发送，取消timer及cooldown=0；不自动重发、不降低目标/IP限频、不改匿名找回受理契约。
- [x] 服务端red：本人同号PHONE_UNCHANGED/他人PHONE_TAKEN无挑战及投递；发码事务内复查proof/归属，确认竞争不返回500或转移他人归属。通过OTP公开on_issue/on_verify回调，DB唯一约束仍最终权威；只转换证实的phone唯一冲突。
- [x] 运行专属Flutter与backend回归，真实失败及green日志/输入hash/命令退出存otp/；报告必要PG并发门禁与候选服务发布缺口。

## Task 2：系统锁屏边界（lockscreen owner）

Files：android/app/src/main/AndroidManifest.xml、call/CallActivity.kt；lib/features/push/push_tap_router.dart、AppHome生命周期接线；iOS AppDelegate.swift/SceneDelegate.swift及对应路由、native contract/XCTest。其余room/search文件归chat owner。

- [x] red：主Activity的showWhenLocked/turnScreenOn必须false，通话Activity可显示专用来电控制；普通通知不能授予聊天锁屏权限。
- [x] 最小原生修复主Activity flags；通话页不自动dismiss keyguard，保留show/turn及CallKit/Telecom。路由目标仅在resumed且session ready时drain；inactive/paused排队，退出或换号清旧目标，不重复navigate。
- [x] iOS APNs投递在scene/application active后执行，inactive不接受Flutter交互，active恢复既有通道；不能把protectedDataAvailable当精确锁屏API或引入PIN/Keychain修改。
- [x] 路由生命周期red/green、原生契约和实际Robolectric/Android编译通过，最终包清单边界核对通过；模拟器具secure keyguard但PIN未知，未主动锁机或修改安全凭据。iOS编译与两端真机缺口单列。

## Task 3：消息负载与历史检索（chat owner，调查先行）

Files：matrix_e2ee_client.dart的MatrixRoomLease本地读/mention接线；room_page.dart；room_timeline_controller.dart、room_search_index_pump.dart、room_mention_store.dart、bounded_history_search.dart、chat_search_page.dart及各专属测试。AppHome归lockscreen owner，不得修改。若需新local history adapter只在Matrix公开lease边界，不改SDK vendored源。

已确认根因：RoomPage每次controller通知触发全timeline mention扫描/整tracker JSON比较；indexpump每次visible更新重扫loadedhistory及构造行模型；房内搜索只走loadedtimeline并按60条requestHistory逐页，附带同样UI/mention/index工作，catch吞掉loadMore异常。SDK自身先本地DB后远程，但碎片timeline可跳过local。这些证据不足以指称本地索引损坏或带宽必然不足。

- [x] red：合成10000历史初始索引完成后，20个单条更新不得再次读取全部旧记录；并行mention更新有界/单flight，保持真正新事件和旧事件编辑/redaction语义；窗口/键盘变化不重构所有行模型。
- [x] 最小性能修复：按实际timeline增量和已处理事件身份维护索引/mention进度，合并同一轮通知工作并缓存稳定消息模型；初次/历史插入/replacement/reset仍正确触发必要扫描，不丢未读、通知或持久状态。
- [x] red：已经存本地但未加载至UI的十天以上消息，房内关键词能直接命中，无SDK requestHistory/远程fetch；稀疏匹配、重复loadMore、取消/换账号/迟到/error-retry正确。
- [x] 使用现有SDK数据库公开读能力，通过lease的账号/房间安全adapter每批最多512条本地读取；自动续扫至结果页或exhausted，批间yield/取消；保留DM历史room归属及decryption-on-device，记录local DB与render真实区间，不暴露关键词。错误inline可重试，不再静默吞掉。未存本地的远端历史明确区分覆盖，不谎称已穷尽服务器。

追加独立SDK owner调查：vendored Matrix现有storeEventUpdate每事件编码整个fragment数组，10000历史/50新消息实测50写/6.46MB、action65.6ms（WindowsFFI，不代表K80全部15.8s）；底层本已一个SQLbatch，仅合并rawSQL不消除编码。保留SDK/SQLite/E2EE逻辑，通过新cooperative_matrix_database.dart公共子类在原store完成后每8ms或16事件让出event loop，原事务zone/lock/batch不变，root在chat owner释放matrix_e2ee_client.dart后接线工厂。

- [x] 新实际SQLite test预热fragment/new-event负缓存，在同一真实transaction内Timer.run heartbeat；原SDK action结束前0tick为red，公共adapter产生tick为green。验证完整事件/fragment、replay、close/reopen与异zone事务仍等待，现有stale-send自愈回归保留。
- [x] 不复制storeEventUpdate、不改vendor/schema、不延迟commit或发布未持久状态。协作yield改善主线程响应，不冒称降低所有SQL/CPU；单次超长编码仍不可被打断。原生编译/全量冻结包含新adapter。

- [x] trace RoomTimelineController刷新、RoomSearchIndexPump、ChatSearchPage、BoundedHistorySearch、LocalMessageSearchRepository及SDK数据库公开分页；记录具体热路径和旧结果游标问题。
- [x] 用合成历史在本机证明加载timeline预算限制/重复扫描和过期结果，不使用用户真实正文。root依据调查追加确切文件与最小根因修复方案后实施。
- [x] 结果必须包含本地与远程覆盖区别、取消/revision/session隔离、重复点击/迟到结果/退出再搜、旧十天历史；不以只加默认分页预算掩盖问题。
- [x] 性能测试以固定合成输入给出扫描/通知/耗时数量，不用mock速度冒充Redmi真机帧率。保留原诊断及消息发送/Outbox/E2EE语义。

## Task 4：实测诊断与接线（root）

- [x] 读取现有runbook及已上线版本；collect_network_diagnostics.py --since-hours24 --tail100000，通过既有jumper远端闭合过滤，日志不出站。
- [x] network_report.py去重分版本，616摘要/两组、无截断；记录bucket上界/覆盖和4xx≠网络故障。
- [x] 远端已部署DiagnosticBatch验证只导出闭合operations/events/frames聚合；读取受维护鉴权保护性能快照，凭据仅容器内使用、不输出。记录真实版本/阶段/慢帧/SQL及数据缺口。
- [x] 对比源码采样与上传限额/帧归因，若诊断热路径产生工作放大，以失败用例修复现有采集器，不新增逐消息上传。

已确认诊断缺陷：2185的network_request/incomplete1154对应真实droppedAttempts，并非网络断线。spool每秒持久化时调用persisted并冻结不可变摘要，32队列/每分钟8上传被小窗口耗尽；red55请求丢23。root拥有core/network_diagnostics.dart、core/chat_diagnostics.dart及network_spool_window_test.dart，按30秒窗口聚合持久化，上传/stop强制结算最后窗口，既有冻结ID/重试不变。green90专项通过；最多30秒未冻结网络计数在意外杀进程时仍可能丢失，明确为尽力而为。不提高限额/上传频率/不修改服务端契约。

## Task 5：集成、门禁与Debug交付（root）

- [x] 检查owner修改不重叠、依赖锁未变、migrationhead/OpenAPI/平台契约；专项green后规格复核→质量安全复核。改动相关完整Flutter/analyze与scripts/verify.ps1环境预检后一次适用全量，真实失败闭环、不反复等价跑。
- [x] 读取ADB在线设备/安装build/ABI及磁盘，选择递增未占用Debugbuild；冻结移动输入。构建只在既定R短路径及E输出，使用原稳定Debug签名，source→Apktool→DEX/resources/manifest→zipalign→签名→独立类/资产/清单/ABI检查。
- [x] 保留数据-r覆盖安装到现有模拟器debug包；设备读回SHA/证书/version/进程及最小功能场景。不得卸载/清数据，不把Debug当正式网站/iOS发布。
- [x] 按task台账回填范围内源码、证据和文档到D目录，守护旧基线漂移；更新current-state索引并保留SG/S3等并行内容。最终说明根因、实测统计、已安装build、服务器候选/iOS真机缺口和下一条动作。

## 最终平台验收及服务发布

- [ ] Redmi K80真实消息负载、房间/键盘响应和未认证OS锁屏通知点击验收；不以合成数据冒充真机帧率。
- [ ] iOS Xcode/Swift/XCTest、同源包分发及系统锁屏真机验收；Windows未执行，现有2173用户尚未收到本轮补丁。
- [x] 已批准同一PHONE-only修复兼容重基到当前S3 API后，完成规格→安全、单API发布及读回；实际1aa6健康、phone3ce3，当前S3/worker/0090/receiver保留，旧6d5未部署。
