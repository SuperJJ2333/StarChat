# 2199 搜索旧媒体缩略图反馈重开

## 当前状态

2200已保留数据安装，用户确认历史媒体缩略图与点击正常；Q1修复、有序源码/Android审查和最终iOS37209352829三项SUCCESS。新的日期/context失败由[独立任务](2026-10-04-search-date-context-followup.md)继续；没有正式移动发布。最终平台证据有序规格/domain与质量/security独立复核均接受。

## 历史阶段记录（下文“当前”“未启动”均为各阶段当时状态）

用户确认2199安装后“查找聊天记录→图片与视频”旧缩略图仍失败。实际adb核对2199/0.4.30/UID10090/首次安装2026-09-26保持；不能把旧SDK测试/157秒进程smoke当实际页面已修复。沿原自主修复授权执行[补充计划](../../superpowers/plans/2026-10-04-search-media-grid-followup.md)。原[任务](2026-10-04-history-anchor-media-ios.md)H2真实设备验收重开。

当前处于调查/RED阶段；明确UI preflight currentSearchMessage仅live find，窗口外结果不会调用SDK媒体读取，也无法onOpenMedia。复用既有public lookup/source hint并保持隐藏/撤回/闪照/账号/迟到读取边界。root复用隔离工作树branch codex/search-media-grid-followup-20261004，不编辑primary1372既有WIP。

2026-10-04T20:50:02+08:00只读核号：生产查询checked_at_utc=2026-10-04T12:49:58.374760+00:00，Android0.4.27+2196/iOS0.4.25+2194；最近8个CI运行无2200候选，模拟器2199。2200仍为准备编号，尚未改源码/冻结/安装。实现actor持有Flutter；最终测试强化为实际RawImage.image已解码尺寸断言，夹具排查未结束，不能把此前仅RawImage组件存在说成像素已成功显示。等待最终有效RED/GREEN与报告后有序独立双审。

最终有效RED：`widget-decoded-baseline-red.log`在原RoomPage上先通过当天图片1x1解码及图库打开，再在旧图片缺少缩略图失败；`widget-decoded-video-red.log`同一最终夹具独立证明旧视频缩略图缺失。最终夹具SHA256=77c4f9177aa048d3e6b2544bddcf0c91117a5eafd78e95a9ef43023c62efd7fd。先前遗漏trimLiveHistory、无效PNG CRC、未等待异步路由的失败仅为夹具诊断，不算产品RED/GREEN。源码已经还原最小修复；17套相关测试/analyze由actor进行，未放行交付。

root拥有`.github/workflows/ios-compatibility.yml`，在既有macOS host Flutter步骤加两个新测试，复用正常SQLite FFI运行时及mock插件；不改原生/key加载。新候选将重新进行完整iOS原生编译、iOS18/26兼容性与保留Keychain连续性，而旧同源key输入证据只用于影响判断。实际模拟器图像账户仍未直接观测；不会以安装smoke替代旧媒体显示验收。

实现5ba5dd63与版本/workflow1a3b84c4：最终相关43PASS/analyze0，root全量21:09:06–21:13:12+08为5432PASS/9skip/0fail，冻结版analyze21:14:34–21:15:01+08为0；正常pubget锁文件无变化。1870输入冻结manifest bcd3946d…及Android构建前检查通过，但未构建/上传/安装，未启动新iOS CI。源规格/domain审查接受（source-spec-review.md/eff7e4fb…）。

质量/security审查发现Q1 P2：搜索保持打开并快速滚动时，disposed cell的排队metadata lookup缺消费者存活检查，可能积压并延迟当前可见项；报告source-quality-review.md/47a2d9e9…。root确认源码触发链，暂停打包并进入fix round1/5；原actor重新持有4文件与Flutter，增加四个慢读取+实际滚动的RED，修复队列取消且保留tap共享读取。原1a3b84c4全量及manifest是历史候选证据，不等于修改后最终源通过；下一步actor定界RED/GREEN/commit/release，再对修改delta有序复审及root最终全量/平台/包门禁。2200源码版本已成对修改，最终候选仍未交付。

Q1 fix round1已提交29236bd3：真实保持搜索打开的held-four滚动RED捕获disposed grid-74仍被读取；修复后16专项PASS/46受影响PASS/analyze0，排队cell最后消费者释放立即移除，tap共享保留、实际已启动操作保持slot直到真正结束。actor释放所有权。root最终全量21:42:52–21:47:02+08为5435PASS/9skip/0fail；同源analyze复用actor最终0结果，SDK/key/native/lock无变。最新只读13:48:26UTC仍正式Android2196/iOS2194、近期CI无2200。正常pubget后1870输入新manifest30a4dcde…绑定29236bd3；旧manifest不覆写。当前等待Q1 delta有序独立复审；源码未再变化，构建/CI/安装仍未启动。

准确调查开始时间未采集；实际版本核对和源码证据来自本轮工具，后续阶段使用显式时钟，不猜总耗时。源码实现、双审、最终候选验证与保留数据debug交付待完成；本轮无正式移动发布/IPA授权。

本轮证据时间2026-10-04T20:07:23.6231060+08:00：实际安装APK SHA与2199成品e3923bc0…精确一致；用户确认点击占位同样无响应。额外同模块gallery gate：_openImageViewerWithForward只允许controller.allMessages图库内项，旧单事件VM仍需合法search-scoped single-image入口；不扩大livewindow。2200打包driver/版本边界检查已准备通过，源码版本未递增、未构建；最终核号在验收后做。


2026-10-04T23:31:42.1933295+08:00 最新结果：用户确认2200历史缩略图和点击正常；H2真实账号反馈已获得。新D1/C1日期十天前未找到、关键词跳转只有单条不可滚动见[独立跟进](2026-10-04-search-date-context-followup.md)，不把媒体修复当上下文验收。iOS run37209352829绑定574ef30，全部3job SUCCESS，含完整生产编译及iOS18/26 seed/new-process retained连续性；final run/jobs证据保留，无正式IPA。
