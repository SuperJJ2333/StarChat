# 红包/转账卡片与点钻账单

## 恢复入口

- 用户授权：2026-09-11 当前任务后连续优化红包/转账/账单，Astra 规划审查、显式 Terra 实施。无生产操作授权；用户负责真机。
- 计划：[实施及验收](../../superpowers/plans/2026-09-11-finance-chat.md)。不改变财务公式/schema/分配/E2EE，无需新增此类 ADR。
- 当前状态：B1–B5实现及本地审查完成，真实RoomPage接线、红包/收款/账单与群人数校验通过定向验证。Astra最终全Flutter2310通过/29基线失败、全analyze及ARM64源码编译通过；其余全仓失败与未验证项见最终审查。
- 工作树：`D:/pythonProject/outsource/StarChat/.worktrees/performance-20260911`；基线 a07c996a；本任务代码及测试改动未提交。
- 负责人：Astra 主审；Terra 执行。文件所有权见计划，禁止并行同文件。
- 更新：2026-09-11 Asia/Hong_Kong；调查开始精确时间未记录。
- 下一步：用户真机与多端实网验收；另行安排服务端/客户端联合发布及最终包重建签名。当前无待继续的本任务代码批次，不重做历史批次。

## 验收台账

FC01/03/04服务端投影与人数约束已有红绿证据；Flutter尚未接入，不能视为端到端完成。FC02/05/06/07/08已有分层实现，聊天接线及集成验收仍未完成。真机及微信像素比较未执行。

## 审查记录

- B1：Astra发现事务外幂等直接返回绕过支付鉴权，退回Terra修正；现保留 lock_account/consume(existing=True)，再合法返回。
- B1：恢复原F06 authority缺失后的领取拒绝断言；新增本人未领但别人领完、群普通红包终态无最佳断言。
- B1：实际代码/红基线日志/绿日志已读。45 passed / 7 skipped；PG fixture却仅1成员而创建2红包，被Astra指出并要求修正，不能把skip当已验证。
- 执行并发：新建第二Terra工具返回 agent thread limit reached；继续已显式gpt-5.6-terra的terra_final_fixtures，串行执行，无静默模型替换。
- B1 PG fixture已核对改为alice/bob两人。Astra发现本机PostgreSQL18.3工具可用，创建全新隔离实例补验：127.0.0.1:55439，database `finance_chat_audit`，临时用户 `finance_chat_test`，数据目录 `docs/verification/artifacts/2026-09-11/finance-chat/pg/data`。initdb/start/createdb/psql身份及data_directory检查均退出0。仅loopback trust临时测试，无生产连接，日志在pg/postgres.log。已交Terra补跑7个原skip；结果待回。
- 上述PG门禁实际7 passed，日志 `b2/b1-b2-postgres-v1.log`。B1本地自动化与代码审查通过，前端仍待接入。
- B2首轮23 passed不代表完整验收。Astra实际审查发现：游标把+08直接replace为UTC；naive/aware时间比较可能500；sender退回后bill_id取最新refund；中文类型搜索与note搜索错误互斥；未知conversion原因默认提现；测试有永真占位且没有真实分页/USDT隔离覆盖。已逐项交回Terra补测修正，B2未批准。
- B2修正后：Astra已读最终生产diff、T1/T2/T3实际测试、+08真实PG分页测试及通过日志。原27通过门禁+T1/T2最终4通过+T3独立1通过覆盖补项；结果不相加作唯一用例数。全服务端回归另行运行。B2审查通过。
- B3a初稿只新增2个纯逻辑测试且未留日志，卡片默认接收者文案仍旧、EXPIRED缺时间误映射available、缺widget样式/点击与最佳门槛矩阵、存在unused import；Astra逐项退回，未批准。
- B3a最终已通过审查：32个focused tests通过，4个源码文件分析No issues。Astra读实际claimed颜色/tap测试及群模式/终态/服务端到期等号/大整数精度测试，日志b3a-final-v2.log（分析）/b3a-final-v3.log（测试）。此前声称但未写的v1日志不作为证据。生产聊天页及HTML同步尚未接入。
- B4a1仅两个session延迟用例先通过，不能当数据层完成。Astra发现首次load不请求、invalidate后loading悬挂及旧epoch继续请求、畸形page部分append等问题，已交Terra补测修正。
- 全后端门禁会话83688：`PYTHONPATH=services/business-api;services/business-worker/app;. RUN_POSTGRES_TESTS=0 py -3.12 -m pytest tests/business_api tests/business_worker -q`，日志gates/backend-full.log，输入gates/backend-inputs-before.sha256。隔离PG门禁独立执行已有证据；verify.ps1前置.env和生成homeserver.yaml缺失，不直接运行完整包装脚本。

## 版本与证据

本任务无新 APK/IPA/镜像，无发布。证据在 `docs/verification/artifacts/2026-09-11/finance-chat/`，后续记录输入 hash、命令、退出码及失败项。

## 阶段计时

| 阶段 | 开始 | 结束 | 结果 | 下一步 |
| --- | --- | --- | --- | --- |
| 根因调查/计划 | 精确起点未记录 | 计划文件创建时 | 硬编码卡片状态、身份文案、最佳条件、人数校验及账单 API 缺失已确认 | B1 |

## 交接与回退

- 保留 video_playback_arbiter.dart 无关格式改动及 Getui demo 两个生成文件。
- 不回退既有性能代码；原全量门禁失败是历史基线，本次相关失败重新调查。
- 无运行中的生产命令、无迁移、无新部署。
- 本任务临时PG（55439）已在测试后用pg_ctl仅针对任务pg/data停止，退出0，证据pg/stop.log；未停止现有postgresql-x64-18服务。后续如需再测可仅重启此隔离目录。

- 全后端门禁实际结束18:56:17+08，770.67s，11 failed/1829 passed/52 skipped；2项新增payment PIN群红包测试缺成员权威，补静态Matrix gateway及测试用户Matrix ID后完整文件8 passed（b1/payment-pin-fixture.log）。另外9项为既有钱包失败名称，未声称全绿。
- B4a1 session invalidate已亲审loadMore保留row后发事件再清空，3项测试日志invalidation-review.log通过；其余controller边界仍在实施。
- 第二显式gpt-5.6-terra子代理terra_finance_demo现创建成功，仅拥有frontend/registry，进行独立B4b；原执行代理返回未实施的待办后续调用出现agent thread limit/not_found，未将该批标记完成。

- Astra核对9项钱包失败断言与前任务日志一致：相同403/201、500/200、200/401与缺id/candidate_txid；本任务未改这些钱包写路径。新日志测试token已脱敏。不代表这些基线问题通过或已修复。
- 找到旧代理误写apps/docs下b3a-v1日志，已单文件移入合规证据目录b3a/misplaced-b3a-v1.log；仍以已亲读v2/v3最终输入为验收依据。OpenAPI --check本次退出0，证据gates/openapi-check.log。

- B4b首稿Astra审查未通过：筛选忽略控件值而跳固定预设、分页丢前页、每行指向同一账单、详情缺字段/全部账单入口。已给Terra具体修正及browser交互断言要求。catalog/component 4项绿仅证明登记，不证明交互。
- B4b二轮已补控件筛选/分页追加/选中ID与clipboard成败断言；仍待最后细节审查。发现claimed颜色HTML灰与Flutter #F2B7A8不符，交回补真实语义token。独立账单页全部账单入口、选中详情金额/状态/标题仍需修正，未批准B4b完成。
- B4b现有证据：focused catalog/component 4通过，UI登记26组件/355画板，Python登记3通过；全npm 142通过/11失败，旧admin/moment/image-editor直接失败源未改；完整browser在admin-chain失败，新finance检查已越过。需要保留最终独立finance浏览器日志，不能只靠整套越过推断完整验收。
- 显式Terra terra_finance_demo继续串行B4a1账单controller，Astra保留HTML审查待办至最终UI复核，不并发写同文件。
- B4a1六测绿后Astra发现未覆盖缺陷：loadMore retry成功不清error；invalid date先写状态导致retry仍发非法区间；search/refresh旧loadingMore旗标未清。已退回补真实失败场景和修正，六测不作为该批通过。B4b颜色token已亲读修正为#f2b7a8。
- B4a1 v2：Astra读3项真实红失败（日期被改、retry错误不清、loadingMore悬挂）及8项绿、最终源码。三项修正通过局部审查；API编码正在独立实施。页面接入时仍须覆盖手动refresh与正在loadMore交叉旗标、真实widget筛选及账号终止交互。v2日志仅包含测试，最终scoped分析待API批一并留完整命令/退出码。
- B4a1 API两测及scoped分析日志已亲读：真实MockClient GET的中文%&+、UTC日期、+/=cursor、默认limit、opaque路径ID、字符串金额符合接口。B4a2 ledger列表/详情页面开始实施，允许范围限ledger源码与测试，RoomPage尚未接入。

- B4a2首稿已进入Astra审查：金额格式化不得截断>2位小数；结束日picker初值不能拿exclusive次日；UI显示真实错误且session-ended不可重试；收款方不依赖API不存在viewer_role；全部账单按来源正确路由；detail epoch无event不能loading悬挂；真实id/CAIBI校验与clipboard epoch守卫。已给Terra具体测试及修改要求，页面未验收。
- B4a2最终16项focused通过/scoped分析退出0，Astra读真实金额字段/平台copy失败/无event epoch异常等测试与源码；尚留“独立详情→全部账单”和“结束日期两次确定”集成补验，不把它们列为已测。
- Astra已启动只读本地HTML预览server：exec session17806 / port4395，CWD frontend；CUA后台tab1浏览器1，变量financeTab。真实点账单观察到详情仍旧标题、缺金额状态，且hidden表单被CSS grid覆盖；B4b待修。结束任务应关闭本任务tab/server，不影响其他进程。
- B3b1首稿实际新增1测试，仅验证同key/per-key；缺轮询Timer、独立可见租约、离屏队列撤销、永久sessionEnded、所有await账号守卫及真正LRU，Astra未批准并要求先重构store与测试。核心状态问题不得以“通过限定验证”声称整批完成。
- B3b1大批多次未完成，Astra拆成生命周期→租约/队列/轮询→LRU→widget/接线的小批。原Terra停止；新建显式gpt-5.6-terra `terra_finance_lifecycle`成功，仅接管store及对应test。尝试独立transfer执行者仍返回thread limit，保持单执行者串行，不将其他未知模型代理用作替代。
- B3b1-A亲审发现pending请求在dispose后的finally访问已释放notifier并重新定时；旧执行者只修该处，新增生命周期测试仍缺，且analyze有6条info，本批未批准。
- 本地HTML预览server17806已用Ctrl-C停止；只停止本任务进程。后续UI修正后再启动验证，CUA旧tab仍可存在但服务已停。
- B3b1-A新执行者补6项测试后Astra亲审仍发现：ended后新key为非ended、epoch无event且无inflight时公开入口早退不清旧detail；已要求真实红测修正。代理误将3个日志写apps/mobile_flutter/docs，被指出按具体文件移回根docs证据目录；需区分接管前已存在修正的baseline replay与真正新增失败。
- B3b1-A通过局部审查：Astra亲读统一_live守卫、await/finally、ended新key及epoch无event测试，真实新增epoch-entry红失败Expected true/false，最终7通过、源码分析退出0。早期timer红为基线回放，已区别记录。三份误放日志已按文件移回根docs。B/C继续独立lease、队列、轮询、LRU、awaitablefresh及wrapper；尚未RoomPage接线。
- 模型分工补证：主代理只读解析当前任务本地rollout中的spawn_agent参数，确认terra_viewer_lifecycle在2026-09-11T04:42:35.703Z、terra_profile_selector在2026-09-11T05:59:41.158Z均实际指定 model=gpt-5.6-terra/fork_turns=none。仅输出模型/名字/时间，未复制对话或凭证。现可安全复用terra_profile_selector执行独立HTML B4b，terra_finance_lifecycle继续Flutter store；同时仅2执行者、无共享文件冲突。此前“模型未知”限制已被实际工具记录解除。

- 阶段计时补充：B3b1-A新增epoch-entry红日志写入19:57:08+08，最终测试19:58:14+08、分析19:58:23+08；以日志文件实测时间为证据完成时间，接管/主动编码起点未精确记录，不估算总主动用时。B/C lease红日志20:00:44+08产生，结果及输入待该批审查。
- B3b1-B/C九测绿未通过Astra审查：A生命周期测试被重写削弱；第二lease可见仍作废已有flight；离屏dirty请求完成不settle导致LRU残留；LRU测试未证明保留命中；缺慢网/403/并发ensureFresh等实际断言。wrapper红包仍伪显示领取且无retry。已拆回store/test先修，明确恢复A覆盖。允许fake_async 1.3.3显式dev依赖，仅更新lock direct分类，去掉新加lint ignore，不接受依赖升级。未接RoomPage。
- 当前主代理模型亦由当前任务rollout最新turn_context核实：2026-09-11T11:49:36.189Z，model=gpt-6-astra。协作模型分工具有实际本地记录依据。
- B4b并行审查：HTML独立copy控件用copy: action会与app.js:184全局复制重复执行，失败还可能unhandled rejection；Astra沿实际事件冒泡调用链发现，已退回改finance私有action/事件隔离并补实际app上下文测试。不能仅用模拟action记录证明无双写。
- A迁移到lease的6项覆盖已恢复，Astra亲读实际测试及15通过/scoped分析日志，批准该小批；fake_async变更仅yaml新增固定1.3.3、lock transitive→direct dev（无版本升级）。继续store慢网/403/并发/重新排队/LRU双向与完成trim五类补验，wrapper/Room仍待做。
- B3b1 Store局部审查通过：最终23测及scoped analyze已亲读；最后dirty用例修正为setVisible(force:true)且无explicit reader，断言离屏仍2次、返回才3次，防止伪覆盖。涵盖A生命周期、4并发、独立lease、慢网、403、LRU保留/淘汰/完成即时上限及实际await合并。进入wrapper独立小批，中性状态/真实retry/换key与业务角色；生产RoomPage尚未接入。

- B3b1 wrapper局部审查通过：Astra读7真实widget用例（held加载、retry、业务receiver金额、换ID旧响应、session-ended、paused/resumed）并亲跑finance+UI组合53 passed、scoped analyze No issues，证据b3b1/astra-combined.log与astra-analyze.log。后续只格式化及把换ID测试的非金额mock替换为真实金额字符串，后续门禁一并覆盖。Flutter槽转交terra_profile_selector做transfercontroller；terra_finance_lifecycle准备红包controller/详情生命周期，文件独立。
- B4b主代理实际CUA（IAB browser1/tab1，本地4395，server session59906）验证账单ID复制成功反馈、全部账单跳转后URL为caibi-ledger-all、选中转账行标题账单详情且筛选消失/金额状态时间ID齐全。发现standalone transactionDetail被误改标题收款，已要求改回账单详情并实际reload确认；收款专页caibi-transfer-receiver-accepted仍为收款。headless旧超时保留为诊断，不冒充通过；主代理实际浏览器补上成功/导航证据，未模拟剪贴板失败。
- B4b两张最终列表/详情截图已亲看（final-browser-5），包含完整字段/按钮；此为HTML fixture UI，不代表真机或微信像素一致。当前server59906仍运行供必要复核，最终须停止本任务进程。

## B3b2/B3b3 审查推进

- 转账controller已由Astra亲读source、10个回归测试及16项组合绿日志。load/retry在写操作期间合并等待，已成功写不被后续GET失败或observer异常反转；same-epoch失效、dispose、发送方禁止接受均有断言。页面及RoomPage仍未完成。
- 红包controller第一轮4pass不满足验收，Astra发现测试仍有错误override且未覆盖held claim跨账号；要求新增真实断言并scoped analyze。红包弹窗原status==null可领取、任意非OPEN写“已领取”亦为待修根因。
- 后续群人数前端采用独立总人数输入及发送前异步快照回调，包含发送者，和专属收款人列表分离。controller在验证开始即占用creating防双击；权威快照失败须明确提示且不能继续create/PIN。sheet初步检查 min(totalJoined,500)，controller发送前再检查变化；服务端仍最终校验。异步离开页面不得继续新建支付或notify已dispose对象。
- RoomPage接线须在详情页面与群发送接口稳定后由单个Terra串行拥有；每个房间一个FinanceCardStore，生命周期销毁。点击单飞、await后mounted/epoch检查，按key ensureFresh→viewer_claim详情/领取弹窗；onSettled及关闭仅invalidate该key，不timeline.refresh。
- Fresh frontend npm test 141 passed/12 failed，gates/frontend-review.log。新增失败token-contract批准列表缺新red-packet-muted，与现有light/dark/registry一致但测试未同步；已明确退回HTML所有者Terra修正并保留完整强度。其他11项名称与前次一致，未声称全绿。

- B3b2 receipt局部通过：Astra亲读5个widget测试及controller完整代码；21项transfer组合通过，4-file analyze无问题，见b3b2-transfer/b3b2-receipt-final-gate.log及b3b2-receipt-analyze.log。字段实际使用created_at/accepted_at并按本地时间格式；失败后terminal保留且可retry、真实bill_id/list导航、epoch无event阻断旧路由、小屏2倍文字有覆盖。RoomPage尚未接线。
- 红包终态已新增COMPLETED/EXPIRED非本人领取及claim成功GET失败3个widget，b3b2/terra-redpacket-terminal-green.log 9通过；剩余ended/有效retry/server_time到期和详情状态仍在修。原terra_finance_lifecycle暂停，当前两个执行者为已核实gpt-5.6-terra的terra_profile_selector与terra_viewer_lifecycle，不超过两个。原D2c历史任务不恢复。

- B3b2红包页局部审查通过：Astra已亲读最终controller/dialog/detail diff及真实held联系人/已领取金额失效测试，目录30 passed（已含controller 6）与6-file analyze No issues，证据b3b2/terra-redpacket-final.log、terra-redpacket-analyze.log。正确区分本人已领取/全局已领完与可信到期；error重试实际GET；失效清旧金额并阻断旧账号导航；已成功claim后GET失败仍保留金额并触发单次onClaimed。生产Room接线仍待完成。
- 批次进入B3b3：terra_profile_selector独占finance_message_entry/RoomPage卡片分支，使用真实API+JWT fixture验证已领直达/未领弹窗/真实账单/快速双击/账号失效。terra_viewer_lifecycle独占chat_red_packet_controller/sheet/test准备群人数前端，RoomPage成员接线待接口稳定交回profile串行完成。Flutter槽由主代理统一分配，当前给profile；viewer仅准备tests/source。

## 最终审查收尾（2026-09-11 Asia/Hong_Kong）

- RoomPage入口/群人数及真实claim/accept回卡组合94通过，6文件分析通过。红包30、转账21、群人数22、账单补验12的分批证据有重叠。
- Astra重读实际入口、API路由、RoomPage、HTML/token diff与测试证据；最终全Flutter2310/29，同29基线失败逐项一致，无新增失败。Python mobile69/1以git show a07c996a重现原正则截断。
- HTML金融Node7、浏览器3及UI契约26/355通过；npm143/11为既有失败。Android源码编译退出0，未做发行包重建/安装，版本2085仅供编译验证。
- [最终报告](../../verification/2026-09-11-finance-chat-review.md)包含复现、根因、FC01–08、文件、命令和缺口。早期待完成描述仅为历史阶段记录，当前状态以恢复入口为准。

### 最终门禁时间与关闭状态

- 2026-09-11 21:17–21:28 +08:00：主代理完整Flutter回归77秒，analyze7.3秒；正常pub get后Android源码Gradle编译73.5秒。各命令实际退出码已写gates日志。
- 主代理独立执行仓库/部署policy通过，文档链接无断链、diff --check通过；完整输入清单由gates/finalize-evidence.py生成。
- 本任务4395 HTML服务器已停止，55439隔离PG已停止，均以本机监听检查确认；未结束或重启其他服务。
- 所有执行者停止源代码修改；后续只需用户真机/多端验收及另行授权发布，不将既有失败和缺环境门禁写成通过。
