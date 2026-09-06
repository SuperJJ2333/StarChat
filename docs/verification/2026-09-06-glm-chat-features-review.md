# GLM 聊天十项改造审查

日期：2026-09-06。范围：当前工作区代码，对照用户十项要求及本任务上一轮开发说明。结论：不能按十项功能完成验收。没有修改生产代码、部署或打包。

## 判断依据

独立模型及算法已有实现，表中七组测试共 88 项通过；加既有 @ 面板 7 项，共 95 项通过。但生产房间仍调用旧搜索页、旧媒体组件和页级缓存。模型单测不能证明路由、输入框监听、真实媒体解码、加密磁盘和持久化已经接入。

当前检索未发现本次十项交付对应的批准实施计划或此前 red/green 验证记录；不据此推断作者从未执行测试。本报告的实际执行证据列在末尾。

## 规格符合性

| 项目 | 当前判断 | 实际差距 |
|---|---|---|
| 1 视频预览缓存 | 未完成接入 | VideoPosterSessionCache 无生产调用；房间仍持有旧 MediaMemoryCache，无本项加密磁盘后端 |
| 2 未读 @ | 未完成接入且模型有 bug | Tracker 与摘要前缀无页面调用；没有已查看事件记忆，重复同步会复活提醒 |
| 3 重复 @ | 有模型，接线错误 | 输入触发使用旧文本；程序插入二次编辑；发送先清空再取收件人 |
| 4 默认空态 | 不符合 | 实际入口打开旧页，初始展示全部传入记录 |
| 5 关键词结果 | 部分旧功能可用，未达到规格 | 实际页还匹配发送者、无头像/逐条时间/高亮，只搜索当前消息快照；新控制器无生产接入 |
| 6 成员拼音 | 部分完成 | @ 面板接入拼音服务，其余成员列表和真实查找页未迁移；查找按展示名合并同名成员 |
| 7 月历 | 不符合 | 真实入口仍日期滚轮；新页硬编码月份、未传有消息日期，只弹提示不定位 |
| 8 媒体/文件/链接 | 未完成 | 实际入口是统一文字列表；新分类页面仍用固定占位图、空文件大小、首个链接 |
| 9 GIF | 未完成真实链路 | 模型接收调用者给出的格式/帧数，没有实际识别接线；GIF仍可能经过JPEG缩略图 |
| 10 图片完整适配 | 未完成接入 | 真实气泡仍200×150与BoxFit.cover；新contain组件未用于真实消息 |

## 缺陷与修复要求

### R1 [P1] @ 输入触发检查旧文本

位置：`apps/mobile_flutter/lib/features/matrix/room_page.dart:276-303`，尤其290先triggerAt、293才写入next；`mention_composer_model.dart:40-43`检查旧text。空输入框输入@时直接越界返回，pendingTriggerStart仍null，面板不打开。此外applyEdit在118行清除pendingTriggerStart，继续输入查询词也丢失触发范围。

修复：以新文本计算编辑、光标及触发范围，保持合法的@查询区间，直到选中、光标离开或触发字符被删除。回归必须驱动真实TextEditingController。

### R2 [P1] 发送先清空文本，导致结构化提醒丢失

位置：`room_page.dart:726-741`。input.clear同步触发监听器，applyEdit移除全部token；731行读取recipientUserIds已为空。普通文本仍发送，但失去m.mentions。旧mentionDraft回退不能恢复新模型创建的token。

修复：先取得正文、回复关系和收件人不可变快照，再执行清空/发送生命周期，并验证最终发送payload包含正确用户ID。最小接线复现已失败。

### R3 [P1] 程序插入提及被监听器二次编辑

位置：`room_page.dart:340-364`、`1974-1984`。先变更模型再input.text赋值，同步监听器仍拿旧_lastComposerText计算差分，重复平移刚创建的token。长按头像插入后实际recipientUserIds为空，即使尚未发送。

修复：统一程序文本更新事务，避免将同次编辑应用两次；分别覆盖面板选择、长按头像、已有文本中插入。此缺陷与R2独立。

### R4 [P1] 新未读 @ 没有生产接线

生产lib检索UnreadMentionTracker和mentionPrefixForSummary仅有定义/类内部引用，未由房间或会话列表调用。JSON encode/decode只是序列化，不是账号隔离存储后端；没有真实加载/保存、50%可见500ms、点击跳转后消费、前缀颜色及标签状态的集成。

修复：将同步事件、账号房间存储、可见性、定位成功/失败与两个UI入口贯通；不能用纯字符串前缀单测替代UI验收。

### R5 [P1] 搜索/日期/分类仍走旧页面

位置：`room_page.dart:1683-1715`仍构造GroupChatHistorySearchPage，并仅传controller.messages快照；新ChatSearchPage无生产路由调用。

旧页`group_chat_info_page.dart:1089-1112,1158-1175`无默认空态门控，正文检索还匹配sender；列表无头像、逐条时间及高亮。成员选择`1200-1217`按entry.sender去重和过滤，同名用户混在一起，只有已传入消息中的发送者。日期`1187-1195`调用滚轮WeChatDatePicker、只过滤列表而不定位当天首条；媒体/文件/链接仍统一文字行。已经直接构建该真实页面验证默认空态、正文搜索范围和禁用滚轮，三项全部失败。

修复：替换真实路由并接入完整历史数据源、用户ID成员目录和共享定位；新页同样需完成下述R6。追加尚未加载历史、同名成员、失败重试、实际点击打开媒体的页面测试。

### R6 [P1] 新页面本身有占位实现，直接切换路由仍不能交付

位置：`ui/chat/chat_search_page.dart:199-222`月历固定2025-01到2026-12，不传datesWithMessages，默认空集合导致无可选日期；返回值只触发说明弹窗。分类按钮目前过滤普通结果，并不打开定义的ChatCategoryPage。

分类网格`753-786`总是用固定33字节PNG头，不包含IDAT/IEND，不能显示真实媒体，且图片与视频均叠播放按钮。文件`798`固定传null大小，已知大小也不能显示。链接`815-818`只展示links.first，遗漏同一消息内其他不同URL。

修复：从真实消息元数据及会话媒体加载器取得尺寸、类型、字节、大小、链接列表；移除占位；接入实际日期索引、首条事件定位和每类点击动作。

### R7 [P1] 视频缓存及图片contain未接入

位置：`room_page.dart:198,915-923`继续使用页级MediaMemoryCache→controller.loadThumbnail；新VideoPosterSessionCache仅定义，无真实加密磁盘实现。`room_page.dart:2061`继续构建EncryptedImageMessage；`ui/chat/encrypted_media_view.dart:124-132`固定200×150及BoxFit.cover，因此裁切仍发生。ContainImageBubble无真实气泡实例。

修复：房间生命周期服务持有新缓存，落实磁盘加密、清理和账号隔离；媒体组件实际改用动态完整适配；以网络/首帧提取次数及四角完整测试图验收，不能只测试纯公式。

### R8 [P1] GIF测试没有验证真实识别和播放

位置：`chat_media_shared_logic.dart:164-175`接收signatureIsGif、frameCount，并不读取实际文件；播放门控函数无生产调用。`room_page.dart:975-988`非视频走缩略图生成，`media_thumbnail.dart:34-40`输出JPEG；`encrypted_media_view.dart:78-83`取得缩略图后可直接返回，气泡及初始大图展示该静态图。

修复：实际读取/解码GIF原始内容及帧数，动画链路绕开静态JPEG替代；气泡、大图、画廊均接入生命周期与开关。以真实GIF文件测试，手动传true和12帧不能证明格式识别。

### R9 [P2] 已查看 @ 重复同步后重新加入

位置：`unread_mention_tracker.dart:53-58,79,93-118`。markViewed只从pending删除，没有已查看事件集合；toJson也未存该集合。边界0→收事件A(order1)→查看A→序列化恢复→再次收到A，hasPending重新为true。新增回归已复现。

另外onReadReceiptAdvanced移动历史排除边界，会排除尚未成功解密、后来才识别出的提及；现有测试明确把这种回填排除设为预期，应重新对齐“普通已读不替代逐条查看”的规则。

修复：持久化处理/查看身份，区分初始化历史边界与普通回执，覆盖已查看重同步、延迟解密、恢复后去重。

### R10 [P2] 搜索失效与防抖/分页生命周期不完整

位置：`chat_search_query_controller.dart:93-109,118-122,152-171`。

- 清空条件走empty分支不增加epoch，旧请求完成仍发loaded，覆盖空态。
- setKeyword不失效epoch，300ms防抖期间旧请求仍被当成有效结果。
- loadMore不校验当前epoch，旧翻页在新查询后完成仍返回stale=false；还用当前条件搭配旧游标，可能混合查询。
- 取消防抖只取消Timer，旧Completer永远不完成；调用方await可悬挂。

以上四种情况新增回归均失败。修复应以条件变更即递增的查询代次和不可变条件快照管理所有请求，分页检查代次，取消时完成Future并做好dispose。

### R11 [P2] 新视频缓存清理无法取消在途写回、clearAll未清磁盘

位置：`video_poster_session_cache.dart:116-120,145-152,175-178`。evict期间的加载完成后会将已移除条目重新写回；clearAll仅clearMemory，不清磁盘。实际复现：evict后memoryEntries=1,diskHasOld=true；clearAll后仍fromDisk=true。

修复：条目/会话generation检查、失效在途任务结果，并提供真正的磁盘会话清理接口；验证撤回、替换、退出账号期间的异步完成行为。当前未接生产，不能据此宣称已发生跨账号泄露。

### R12 [P2] 拼音排序仅迁移 @ 面板

生产member_directory_service唯一导入方为wechat_mention_panel。`group_chat_info_page.dart:724-727`仍只按解析后展示名单字段contains，无拼音和统一排序；`784-786`移除成员沿原顺序。真实历史成员筛选还有R5的展示名合并问题。pubspec.yaml:54使用lpinyin:^2.0.3，亦不符合严格固定版本声明（锁文件可锁当前解析版本，但manifest仍允许升级）。

修复：迁移所有应按名字排序的选人列表，保留群头像等其他业务顺序需单独明确；按用户ID查询，统一备注/昵称/用户名过滤；固定依赖版本。

### R13 [P2] 新contain组件约束变更不重新布局

位置：`ui/chat/contain_image_bubble.dart:110-127`仅bytes变化时清除_layout，maxWidth/maxHeight变化不重算。接入后旋屏或可用视口变化仍使用旧尺寸，违反横竖屏适配。修复比较尺寸约束、正确管理ImageStream监听生命周期，补同一字节不同约束的组件测试。当前为代码审查确认，未做真机复现。

## 质量、安全与验证

没有看到本批代码新增服务端明文聊天搜索。也不能将“磁盘回调接口”和“JSON编码接口”当成已验证的加密及账号隔离存储。上述实现欠缺应在接入前解决，避免触碰既有E2EE边界。

实际执行（Flutter工作目录均为apps/mobile_flutter；使用PowerShell7与UTF-8）：

1. 表中七个test文件＋test/ui/wechat_mention_panel_test.dart：95通过，exit0。日志：[existing-tests.log](artifacts/2026-09-06/glm-chat-review/existing-tests.log)。
2. test/ui/chat/chat_search_page_test.dart＋contain_image_bubble_test.dart：15通过、1失败，exit1。失败是测试find.text('大小未知')精确查找，而UI文本为“大小未知 · 发送者”；属于断言与组合文本不一致，不能据此说界面没显示大小未知。另有R6真实元数据缺失独立问题。日志：[new-ui-tests.log](artifacts/2026-09-06/glm-chat-review/new-ui-tests.log)。
3. 新增搜索/未读@回归5个：全部在目标行为断言失败，exit1。[源码](artifacts/2026-09-06/glm-chat-review/search_mention_regression_test.dart)、[日志](artifacts/2026-09-06/glm-chat-review/search-mention-regression.log)。
4. 新增真实历史页组件回归3个：全部在目标行为断言失败，exit1。[源码](artifacts/2026-09-06/glm-chat-review/history_page_regression_test.dart)、[日志](artifacts/2026-09-06/glm-chat-review/history-page-regression.log)。
5. 新增@接线最小复现3个：全部失败。使用真实TextEditingController，复制RoomPage事件顺序，非完整RoomPage E2E。[证据](artifacts/2026-09-06/glm-review-mentions/review-evidence.md)、[源码](artifacts/2026-09-06/glm-review-mentions/mention_wiring_regression_test.dart)。
6. 缓存生命周期脚本已运行并复现R11。[源码](artifacts/2026-09-06/glm-review/video_cache_lifecycle_repro.dart)。
7. flutter analyze --no-pub针对七个模型＋room_page＋两个新UI文件：exit1，chat_search_page.dart:9重复import警告，:164弃用minSize提示；无编译error。日志：[analyze.log](artifacts/2026-09-06/glm-chat-review/analyze.log)。

以上不重复计数：原有测试共111个，110通过、1失败；新增缺陷回归11个，11失败。缓存脚本另计。不是APK或生产环境实测。

未执行全仓verify.ps1、APK编译或真机E2E。本次为审查，不修改行为；verify脚本还会重建本地配置，未为此次只读生产审查运行。不能宣称全仓门禁通过。复现代码和日志均位于docs/verification目录，不修改生产代码或既有测试。

## 推荐处理顺序

1. 先修R1-R3，恢复真实@输入与发送。
2. 补R9-R11逻辑回归，再实现持久化/缓存生命周期。
3. 打通真实路由与媒体组件，消除R4-R8及占位路径；统一成员列表和图片约束更新。
4. 用真实Matrix历史、GIF和视频文件进行页面/设备验收，补可见性、网络计数、账号切换及断网恢复。
5. 修复UI测试和分析警告，按批准计划运行项目门禁，保存red/green及真机证据后再标记十项完成。
