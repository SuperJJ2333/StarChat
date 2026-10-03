# 搜索、系统相机与三天历史任务

启动可靠观察2026-10-03 23:08:16+08；记录2026-10-03T23:14:02.877150+08:00。用户报告正式Android0.4.27/2196：搜索加载文字抽动，一天前点击加载失败，要求去年消息可跳转；MagicOS8.0/荣耀50Plus/Android14拍摄/录像显示拍摄失败；新设备/同设备切账号加载最近三天群聊/私聊并正确解密。此前自主ADR/计划、debug安装、main集成授权保持。新设备是否完成密钥恢复的可选问题待答，不阻塞独立工作。

状态：调查/计划；基线main c69d07cf，已交付2197debug尚不含此三项修复。主仓1387项既有WIP保持；新managedworktree/branch codex/search-camera-history-20261003干净。产品code仅声明任务领取后改。计划../../superpowers/plans/2026-10-03-search-camera-history.md；规格../../superpowers/specs/2026-10-03-search-camera-history-design.md；证据../../verification/artifacts/2026-10-03/search-camera-history/。

初步证据：chat_search_page._historyChanged将history全部当安全失效并clear/restart；room_page._scrollToMessage仅openAnchor当前窗口后反复loadEarlier；SDK已有日期context却无显式事件locator。相机manifest无IMAGE_CAPTURE/VIDEO_CAPTURE queries；固定plugin grantUriPermissions依赖queryIntentActivities逐个grant且启动Intent不带通用URI flags。Matrix同步只sync/uploadPending，未看到72h全部房间hydrate。均为待行为复现的候选根因，不把源码推断当真机结论。

验收ID S1搜索/旧anchor，C1系统拍摄，H1三天历史+密钥恢复，D1相关最终门禁与实际debug安装。每项分别记录实现/测试/发布/物理验证。E2EE保护ADR设计及双审必做；无用户密钥不能保证历史解密，保持缺密钥状态。

下一步Task1 sole implementer根因/RED/GREEN；root制作Task3 ADR与独立设计复核，准备固定工具链和平台证据。root不编辑转交源码、不并发Flutter/Gradle。
