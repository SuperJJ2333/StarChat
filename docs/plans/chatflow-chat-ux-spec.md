# ChatFlow 聊天体验规格实施计划（10 项）

## Goal
按 2026-09-06 十项规格实现：视频预览缓存、@提及体系（范围/未读集合/逐条跳转/重复修复）、聊天搜索（空态/组合筛选/分页/分类/成员/日历）、GIF、任意比例图片。全部本地客户端改动；不动业务后端/资金逻辑。

## Context
- 基线：c54afe2 + 86782c1（通话/图库审计修复已入库）。
- 共享服务先行（规格"统一交付"要求）：消息定位、媒体缓存、成员排序、本地历史查询——避免各页面规则不一。
- 现状勘察：`MentionDraft.append` 为**追加式**（触发 @ 保留 → 双 @，即规格#3缺陷）；`sortMentionOptions` 中文归 #（无拼音依赖）；`chat_history_search.dart` 为纯函数雏形（无空态/游标/防抖）；媒体缓存已有 MediaCache/MediaMemoryCache（字节 LRU）但无"会话级视频预览图"专用缓存。

## Constraints
- 纯逻辑层测试先行（fake clock/可控 Future）；UI 接线后跑组件测试。
- 不新增服务端明文索引；检索/查看状态按账号隔离；持久化敏感项走既有本地加密存储模式（本期查看状态仅本地，无跨设备同步声明）。
- 拼音排序采用固定版本字典（第三方包 lpinyin，离线镜像安装；锁定版本）。

## Done when
10 项逐项：代码+测试+docs/verification 记录；未完成项如实标注状态与剩余工作。

## 实施顺序（依赖优先）
1. **#3 重复@修复**：范围式 token 替换模型（MentionToken/替换触发区间）——最小、独立、缺陷已实证。
2. **#6 统一成员排序服务**（拼音字典、A-Z+# 分组、备注→昵称→用户名、拼音全拼/首字母过滤）——供 @选择器/成员查找页共用。
3. **#1 视频预览图会话缓存**（字节 LRU 32MiB + 会话级加密磁盘 + 并发合并 + 失效规则）。
4. **#2 未读@状态机**（账号+房间+事件集合、时间线排序、可见性判定、持久化序列化、[有人@你] 摘要前缀）。
5. **#4/#5 搜索查询控制器**（默认空态、AND 组合、300ms 防抖、稳定游标分页+事件去重、安全高亮、匹配范围规则）。
6. **#10 任意比例图片布局**（contain 缩放计算、72%/320dp/45%/420dp 上限、小图不放大、占位→解码更新）。
7. **#7 月历日期定位**（月份模型、有/无消息日期状态、范围导航、定位最早一条）。
8. **#8 分类页**（链接解析/去重、文件名回退、分类过滤规则——纯逻辑 + 页面）。
9. **#9 GIF**（真实格式识别（帧数）、动画解码路径、可见性暂停、自动播放开关）。

## 10 项跟踪表

| # | 项目 | 状态 | 测试 |
|---|---|---|---|
| 1 视频预览缓存 | **核心逻辑完成**：VideoPosterSessionCache（32MiB 字节 LRU/会话磁盘不淘汰/并发合并/键含账号+房间+媒体+版本+规格/evict/replace/clearMemory）；UI 接线 **完成** | 10/10 |
| 2 @范围/未读/跳转 | **状态机完成**：UnreadMentionTracker（结构化判定/历史边界/时间线新→旧/持久化/已读不清空/jump 失败不消费）+ 摘要前缀；UI（红色前缀组件+↑标签+加载态+失败 toast） **完成** | 13+5/13 |
| 3 重复@修复 | **完成**：MentionComposerModel（触发范围替换/装饰@规范化/编辑同步/HTML pill 解析）+ room_page 接线（_insertMention/_handleComposerChanged/_send/appendMentionDraft） | 15/15 |
| 4 搜索空态/组合筛选 | **查询控制器完成**：默认空态不查询/AND 组合/活动标签可移除/媒体单选；搜索页面 **完成**（ChatSearchPage：空态+筛选 chips+结果行+高亮+时间） | 13+13/13 |
| 5 关键词/分页 | **完成（逻辑层）**：连续子串忽略大小写/匹配范围=可见正文/安全高亮/稳定游标+事件去重/stale 丢弃/时间格式；结果行/时间/高亮 **完成**；历史拉取服务接线待做 | 同上 |
| 6 成员拼音排序 | **完成**：MemberDirectoryService（lpinyin 固定字典/全拼排序键/A-Z+#/备注>昵称>用户名/全拼+首字母过滤/ID 稳定）+ sortMentionOptions 已替换；成员查找页 **完成**（MemberPickerPage：拼音分组+搜索+离群标记） | 8+3/8 |
| 7 日期查找月历 | **月历模型完成**：CalendarMonth/三态日期（有消息/无消息/扫描中）/导航范围/定位最早一条/本地时区；月历页面 **完成**（CalendarPickerPage：三态日期+导航钳制+日期提示） | 4+2/4 |
| 8 三分类页 | **纯逻辑完成**：链接解析+同消息去重/预览元数据回退（域名标题+URL 摘要）/文件名大小回退（不伪造）；三个分类页面 **完成**（ChatCategoryPage：媒体网格+文件列表+链接列表+空态） | 4+4/4 |
| 9 GIF | **识别与门控完成**：真实格式分类（签名+帧数）/播放门控（自动开关/下载偏好/离屏/后台/画廊页）/循环元数据（有限不强制无限）；解码识别+门控+设置开关 **完成**（AnimatedImageCell+GifAutoPlaySetting）；真实帧延迟解码接线待做 | 5+4/5 |
| 10 任意比例图片 | **布局计算完成**：contain 公式/72%+320dp/45%+420dp 上限/EXIF 方向/小图不放大/网格适配/查看器钳制；气泡与网格组件 **完成**（ContainImageBubble+ContainGridCell）；旧 EncryptedImageMessage 替换待做 | 15+3/15 |

## 进度日志
- 2026-09-06：勘察完成（重复@根因：`_insertMention`→`MentionDraft.append` 追加不替换触发 @；中文排序无拼音依赖归 #）；开始 #3。
- 2026-09-06：10 项共享逻辑层全部实现并通过专项测试（共 87 个新用例）：
  - #3 mention_composer_model.dart（15）+ room_page 接线完成
  - #6 member_directory_service.dart（8）+ wechat_mention_panel 排序替换完成
  - #1 video_poster_session_cache.dart（10）
  - #2 unread_mention_tracker.dart（13）
  - #4/5 chat_search_query_controller.dart（13）
  - #10 image_contain_layout.dart（15）
  - #7/8/9 chat_media_shared_logic.dart（14）
  - flutter analyze 0 issues；全量 flutter test 复跑中。
- **剩余工作（UI 接线层）**：#1 视频消息组件 **完成**（VideoPosterCell）；#2 会话摘要红字前缀+群聊↑标签+可见性检测+定位高亮；#4/5 搜索页面（空态+筛选标签+结果列表+防抖输入）；#6 成员查找页；#7 月历页面；#8 三分类页面；#9 GIF 解码器接线+设置开关；#10 图片气泡/网格/大图组件接线。

## 进度日志（UI 接线层）
- 2026-09-06：UI 接线层全部完成，新增 8 个组件文件 + 26 个新测试：
  - `contain_image_bubble.dart`（#10 气泡/网格 contain 布局，3 例）
  - `chat_search_page.dart`（#4/5/6/7/8 搜索页+成员选择+月历+三分类，13 例）
  - `conversation_mention_banner.dart`（#2 红色前缀+↑标签+失败 toast，5 例）
  - `video_gif_cells.dart`（#1 VideoPosterCell + #9 AnimatedImageCell+开关，8 例）
  - flutter analyze 0 issues；全量复跑中。
- **生产接线待做**（需要 room_page 消息管道上下文，属下一批）：
  ① EncryptedImageMessage→ContainImageBubble 替换；② 搜索入口挂到聊天右上角菜单；③ UnreadMentionTracker 挂到会话列表数据流；④ CalendarPickerPage 接真实日期索引；⑤ ChatCategoryPage 接消息流。
