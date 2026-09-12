# 2103 账单/转账与历史问题整合验证

状态：代码与回归已整合，最终静态提示清理/构建准备中，尚未生成或安装本次 Debug。Astra 负责设计与实际差异审查，两个执行子代理明确指定 gpt-5.6-terra。

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

最终候选、测试总数、文件SHA、证书、安装读回与未覆盖项：待写入。



