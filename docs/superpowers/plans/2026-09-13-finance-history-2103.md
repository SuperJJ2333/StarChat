# 2103账单/转账Demo对齐与历史修复整合

Astra计划与代码审查，实际gpt-5.6-terra实施/测试。复用.worktrees/offline12，不覆盖root脏工作区。用户授权修复、自动化验证和固定签名Debug保留数据安装Mi6；不push/生产部署/迁移，不真机功能测试。实际设备0.3.87-debug/2103；合并main e2870554到6c5ab436，分支codex/finance-history-2103-20260913。

- I1：保留之前H2滚动/I0缓存等全部已审改动与2103输入。唯一ledger_pages冲突由finance Terra逐块合并；Astra审stage1/2/3与最终调用链。禁止整文件ours/theirs。
- F1：frontend/design-demo/wechat-finance-demo.html为用户视觉基准。确认全部账单、转账实际路由与布局。finance Terra拥有ledger_pages、caibi必要入口、transfer详情和finance卡片及相关tests/registry/HTML关联；先报告偏差，Astra批准具体最小范围再修。不修改金融业务公式、手续费、余额、授权、幂等；金额继续字符串/精确处理。验收：真实入口到目标样式，筛选/搜索/分页/复制/加载/异常正常，发送收款身份状态准确；320/390宽截图比对。
- H1：接续2026-09-12-history-latency计划。history Terra独占matrix_e2ee_client、matrix_room_timeline_adapter、room_timeline_controller、必要SDK timeline+patchdoc，随后room_page/chat_search_page与tests。先SDK fragment forward重试/limited sync/已载撤回回归，然后有界日期timestamp/context能力和日历接入；保留SDK设备解密、账号lease/代次、双向分页token、200窗口和返回live。日历首显不扫描整月、未知过去日期仍可查询，日期为空/断网未缓存不混淆。共享文件串行，步骤完成Astra审查。
- H3：原50秒接收延迟未有事故trace，不能称已修复。保留真实SQLite50 sender写放大量化结论。增加本机同步等待/处理/清理闭合枚举计时，重复processing不重置，error/销毁不拼接，debug显式启用、release默认关闭；不存ID/正文/URL/密钥、不上传、不修改密钥队列。安排空闲Terra独立实现。
- V/D：root先规格后质量审查实际diff和证据，定向RED/GREEN、全量Flutter/analyze/边界/契约，已有失败身份比较；verify预检缺.env如实标注。冻结最新版本>2103，源build→Apktool2.12.1→zipalign→固定证书→语义/哈希→保留数据安装并拉回验证。先核对设备/其他任务版本，禁止降级/卸载/清数据。

证据docs/verification/artifacts/2026-09-13/finance-history-2103/；本任务台账同日期finance-history-2103.md。保持两个执行代理上限，Flutter runner协商串行，root可做独立审查/文档。

## H1b 接口与UI接入审查门槛
先接公开日期能力，再改RoomPage/calendar。日历首显及切月只能读metadata，不触发loadThrough或全量allMessages投影；没有已知记录不等于确认无记录，未知过去日期可选、未来不可选。旧非日期搜索功能保留按需构造模型。
显式选日异步期间提供定位中/错误重试或取消反馈，成功再返回房间定位；取消、重新选日、返回上层、离开会话使代次失效并取消待采用context（SDK不可取消的网络future仍可晚到但不能更新UI/泄漏订阅）。不存在消息仅在跨日/穷尽得到确认时显示，有限扫描预算耗尽明确为未完成而非空。
forward分页与已载newer window分别判断，不把“还有远端新页”当作已有窗口调用showLater空转。可以预取但拖动/惯性滚动结束才做window shift，复用H2代次/方向/锚点保护；异步旧页不得控制新日期的exhausted/loading。发送和返回最新经同一live恢复入口；所有H2真实RoomPage回归重新覆盖。
原50秒实测仍待现场：H3仅新增本机三阶段单调计时，不能为赶交付改写密钥队列/全局数据库事务。

H1b独立准备：H3执行者空闲后拥有chat_search_page.dart和其UI tests，仅增加默认关闭的allowUnknownPastDates选项及月历metadata-only/未知过去可选/未来禁用测试；不接RoomPage，不改变现有调用默认行为。与H1a SDK/controller无共享文件，可并行；待H1a通过后再由history执行者串行接RoomPage启用此选项。生产异步定位行为仍须完整审查，不因UI选项通过就标记H1完成。

## 最终代码门禁进度
I1/F1/H1/H3实现与Astra规格、质量审查已完成；H3仅诊断不宣称50秒问题根治。全Flutter2602/29，失败身份等同旧wallet29；mobile70、UI契约28/364通过，frontend161/11基线一致，verify缺.env。静态分析新测试两条info清理后进入V/D固定签名Debug构建与Mi6安装。

V/D完成：最终全分析无问题，固定签名0.3.87-debug/2104已保留数据安装Mi6并拉回hash核对通过。真机功能/性能待用户验收，H3仅定位诊断；整仓旧失败/缺.env见报告，不宣称全绿。
