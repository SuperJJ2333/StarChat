# 2103 账单/转账与历史问题整合验证

状态：0.3.87-debug/2104 已于2026-09-13 03:21:25+08保留数据安装Mi6，03:22:13拉回核验通过；功能与手感待用户验收。Astra 负责设计与实际差异审查，两个执行子代理明确指定 gpt-5.6-terra。

## 问题和复现
- F1：2103 从“我→点钻→全部账单”查看流水，或点击转账消息进入收款页。与 frontend/design-demo/wechat-finance-demo.html 比较：账单分组/行图标和转账 hero/字段/账单入口不一致。根因是实际路由上的账单布局未按指定 demo 分组，转账详情采用了另一份三态 demo 的样式；不能只更新 demo 或未被路由使用的组件。本次 ledger 合并冲突是集成过程中解决的问题，不是 2103 上线缺陷的根因。
- H1：会话→查找聊天记录→日期，打开月历时客户端 loadCalendarMonth→loadThrough(月初)→每页60条逐页补历史，并全量投影搜索模型；本地和网络耗时被串行叠加。已移除日历打开/切月的扫描及全量模型投影；只读本地日期元数据，未知过去日期仍可查询。显式选日优先命中本地，未命中用 timestamp→context→最多3页继续查找，总预算13秒；取消、失败、确认空与尚未完成分开处理。
- H2：跳转旧历史后上下反向拖动，程序换窗/锚点定位中断用户手势。上一批增加手势/代次防护；本轮新增真实 held-forward 用例又发现请求完成会自动跟随新窗口、首次方向通知使刚发出的请求代次过期。修复为前向请求前 pinWindow，并先记录方向再发起请求；拖动及惯性期间不换窗，结束后有边界复核再换窗。
- H3：用户报告他人发送后约50秒才收到。真实桌面 SQLite 的50 sender基准证明历史ID列表重复写入，但不足以解释真机50秒。没有事故时间/群名/端到端trace，不归咎网络、服务器或Mi6。

## 已确认的测试证据
证据目录：artifacts/2026-09-13/finance-history-2103/。
- F1账单/转账21项通过：metrics/f1/f1-final-run.json与f1-review-final-green.log。金额仅一个点钻单位，保留精确字符串；绿色已收状态、身份文案、双账单入口、复制、分组和筛选已覆盖。
- F1截图：visual/*-v5.png使用真实WeChatTheme，320/390宽四项通过；Astra亲看账单390及转账320。灰底/白色卡片/绿色金额和转账hero/双入口结构已检查，测试字体部分方框，不能声称中文或像素级验收。早期v2-v4未注入真实主题，不作最终证据。
- H3本机同步阶段计时24项通过：metrics/h3-review-final-green.json。仅数字与阶段枚举，无正文/用户ID/URL/密钥；Debug显式启用、有界内存，不上传。不是50秒延迟已修复的证据。
- SDK/controller/date最终38项通过：history/h1a3-monotonic-focused-green.log（命令、退出码与输入hash附末尾）。覆盖有界查询、跨日、加密未读、取消/晚到、context释放、双向请求互斥与撤回去重。
- 独立月历metadata-only选项19项通过：calendar/h1b-future-known-green.log；包括未知过去可选、未来即便标记已知仍禁用。
- Calendar/Search/真实RoomPage相邻31项通过，新增held-forward实际RoomPage用例通过并纳入最终全量；详情见calendar/held-forward-room-page.md。
- 最终全Flutter2602通过/29失败，29个失败ID与上一批钱包基线完全相同（无新增/移除），见flutter-full-integrated.log与flutter-failure-comparison-integrated.json。全套仍未全绿。
- mobile boundary70通过（mobile-integrated.log），UI contract28组件/364屏通过。
- frontend 172项中161通过/11失败，失败身份与前次history-latency的11项一致，无新增ID；frontend-final.log及frontend-failure-comparison-final.json。该套件仍未通过，未忽略旧失败。
- verify.ps1：repository/deployment/template通过；render-only因缺.env失败。没有导入生产秘密，后续门禁不能冒称已运行。
- 浏览器拒绝读取本地file URL，未绕过。HTML/CSS由工作区读取，桌面widget截图不等同浏览器或真机验收。
## Mi6验收用例（交付后执行）
1. 全部账单检查白色按日圆角组卡、类型圆图标、正负金额/状态；搜索、类型及起止日期、分页、无结果、失败重试、账单详情复制。
2. 转账待收/已收/退回三个状态；收款人显示“转账已收款”；查看说明、转账/收款时间、真实账单ID复制，两个账单入口正确。
3. 冷/热会话打开日期页和切换月份，不等待整月拉取；选5天前有消息日期可定位，选无消息日期不假装加载成功，断网只定位已有缓存并区分未缓存。
4. 日期定位后连续上滑/下滑、多次反向、拖动期间历史请求完成、返回最新及发送新消息；无强制跳动/手势锁死/重复气泡。
5. 重现接收延迟时记录版本、群名、双方发送/接收时间，并读取本机阶段数值。长轮询等待时间不是接收延迟；实际50秒问题仍需对应现场证据。

最终源码候选 e314d4f02c06349a48065fbd1adaf97429692e26，交付与未覆盖项见下文。




## 实现范围、调用链和审查结论
- 财务：`app_home._openLedgerAllBills`/点钻入口继续进入 `features/ledger/ledger_pages.dart`；RoomPage转账卡继续进入 `features/transfer/chat_transfer_detail_sheet.dart`。指定HTML已用于样式核对：按日白色圆角组卡、类型圆图标、独立金额与状态，转账绿色52圆图标/金额hero、详情行、账单复制与并排入口。金额精确字符串、账本状态与网关权限保持。`tests/mobile/test_ui_component_registry.py`仅修正实际364屏的期望值。
- 日期：`ui/chat/chat_search_page.dart`→controller→`room_history_date_capability.dart`→`matrix_e2ee_client.dart`公开能力。日历打开与切月不逐页扫描、不全量创建搜索ViewModel；未知日期没有绿色“已知有记录”标记，仍可显式选择。已缓存日期立即定位首个已加载可展示事件，远端使用SDK时间戳/context接口。有界查询耗尽提示尚未完成而非空；不是承诺所有远端查询都在固定短耗时内成功。
- 历史：`room_page.dart`区分已加载窗口与远端前向页；固定当前窗口、方向代次、拖动/惯性结束后的边缘复核。`room_timeline_controller.dart`统一返回live、发送恢复live和过期请求owner；SDK timeline/room/timeline_chunk区分fragment token，保证分页互斥、断开的历史片段不会被live limited sync清空，已载撤回仍更新。
- 同步诊断：`matrix_sync_phase_metrics.dart`经既有watchdog接线，区分response wait/processing/cleanup；不改密钥队列、不收集正文/身份。测试版显式打开本机数字记录。历史索引写放大与用户报告的50秒不能直接画等号，此版本不能宣称消除50秒延迟。

Astra亲读实际diff、调用链、原始GREEN日志与失败身份比较，按规格→质量顺序审查并多轮交Terra修正。执行者都通过工具明确指定gpt-5.6-terra，最多两个同时执行、共享文件先后移交。部分RED只保存在执行者工具记录而未归档日志，属于证据归档缺口；早期部分fixture晚于实现，不能宣称所有变更严格test-first。

## 已知差异与未验证项
- HTML是静态375宽样稿；实际采用现有Flutter主题、可点击最小尺寸与自适应布局，并非像素逐点复制。320/390桌面图已检查层级，部分测试字体方框无法判断真实字距；Mi6中文字形、手感和真实财务数据由用户验证。
- Flutter旧钱包29失败、frontend旧11失败仍存在；verify整仓因缺.env阻断，未运行生产集成或迁移。新增范围的定向测试与最终分析通过，不等于整仓全绿。
- 真机功能、断网/弱网性能、50人真实群负载、发送端/接收端时序、多端与iOS未在本轮实测。没有造生产数据、切换手机网络、清空账户或修改生产服务。
- ARM64 Debug采用固定流程源码构建→Apktool2.12.1重建→zipalign→已验证固定证书→语义/内容核对；最终安装结果以下文实际证据为准。

## Debug2104实际交付
- 源码：e314d4f02c06349a48065fbd1adaf97429692e26，分支codex/finance-history-2103-20260913；本地整合main e2870554与先前历史修复。无push/生产部署。
- APK：`artifacts/2026-09-13/finance-history-2103/candidate/debug-2104/final.apk`，144068907字节，ARM64、debuggable、包com.liuhetong.mobile，0.3.87-debug/2104。
- SHA256：`260370f68df14bdffeab5e5f98cbb97070c88c1b395c0019134b5b25239b8bc9`。
- 证书SHA256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，与设备原2103一致。
- 重建核对：27250类完整保留，smali逻辑无变更，339原生库/Flutter资产字节一致，清单语义一致；aapt/签名后zipalign/Debug专门校验通过。`build-result.json` exit0。源码中间APK不是交付包。
- 安装：Mi6 cbd0156b，`adb install -r` 03:21:13—03:21:25+08，exit0/Success；未卸载/降级/清数据。03:22:13拉回包完整SHA、证书、版本一致，见`installed-2104-verification.json`。
- 最终静态分析：root实际全项目`flutter analyze --no-pub`，No issues，见`analyze-final.json`。全Flutter2602/29旧钱包失败；导入/override测试清理后日期10项单独重跑，通过且产品未变，复用全量结果。构建依赖锁SHA与测试一致。
- 源码编译提示现有插件应用KGP、未来Flutter版本将要求迁移：本轮未升级依赖，该提示不阻止此次编译；作为后续工具链兼容事项保留。
- 本轮仅安装/包核验，未启动真机功能测试。请重点验证账单/转账样式、日期进入与选日、旧历史双向滚动，以及实际接收延迟；50秒问题仍未定因。
