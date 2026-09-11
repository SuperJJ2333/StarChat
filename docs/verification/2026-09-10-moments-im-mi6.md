# 朋友圈与即时通讯修复：Mi 6 Debug 交付

授权：2026-09-10 本轮五项需求；只推送 Debug 到 Mi 6。用户明确“无需你自己测试”，本轮未执行自动化测试、Flutter analyze、仓库全量门禁或真机交互验收。以下根因来自源码追踪，不能代替双端实际验收。

基线 `8ec6782e`，分支 `codex/moments-im-mi6-20260910`，隔离工作树 `.worktrees/moments-im-mi6-20260910`。未改主工作区已有文档整理内容、未部署服务器或发布正式版。

## 1. 好友资料与唯一私聊

复现：朋友圈动态头像、作者昵称、评论作者进入同一好友资料，点击发消息/语音/视频。

根因：`openMomentPerson` 使用同一个 `ContactProfilePage`，但未注入其三个动作回调；不是页面组件实例不同。搜索、资料预览下钻也有同类回调遗漏。刚从 API 查询出的好友可能未进入 Matrix→业务用户 ID 缓存，而通话入口原本没有消息入口已有的身份补载。

修改：新增 `ContactActions`，由 AppHome 将既有操作沿 Discovery、Moments、详情、个人朋友圈、资料预览、搜索、群成员入口传递；通话补载好友身份。全部动作继续使用现有 `DirectChatController` 与 `CoordinatedDirectChatGateway`。现有业务双方 ID 排序锁、单次 claim、持久 creation intent、规范 room publish 保证这些入口复用同一建房流程；同步或打开失败不回退创建替代房间。本轮不删除、合并历史已存在的重复房间，不引入新建房接口或修改服务器。

主要文件：`lib/app_home.dart`、`lib/features/contacts/contact_actions.dart`、`contacts_page.dart`、`add_friend_profile_page.dart`、`lib/features/moments/moment_person_navigation.dart` 及各级页面的参数传播、`lib/features/search/global_search_page.dart`、`lib/features/matrix/room_page.dart`。完整清单见提交差异及 profile 静态审查记录。

## 2. 自己评论的菜单

复现：点击自己的评论，再长按该评论。

根因：`interactWithMomentComment` 条件为长按或自己评论，两条手势均打开相同菜单。

修改：自己评论短按直接返回；长按保留复制/删除，按 Navigator 限制菜单单实例，结束后释放；他人评论短按仍回复。修改 `moment_comment_interaction.dart`；HTML demo 同步。原评论回归源码更新并新增重复长按场景，未运行。

## 3. 撤回

复现：自己发消息后撤回，立即再发一条/多条，切换会话、重启、重连或其他设备读取。

根因：菜单和服务窗口为 2 分钟；时间线快照仅接纳 `m.room.message`，已撤回的 `m.room.encrypted` 信封在快照重建时被过滤。SDK 时间线及三类数据库只读取旧版顶层 `redacts`，未统一读取新版 `content.redacts`；迟到的未撤回事件有覆盖持久撤回状态的风险。

修改：窗口统一 3 分钟；保留已撤回的加密事件；两种 redaction 目标位置兼容；旧载荷到达时继承持久撤回，而继续写时间线索引，避免 limited sync 清索引后占位无法恢复。私聊发送者“你撤回了一条消息”、接收者“对方撤回了一条消息”，群聊保留发起人名称；仅本机仍有撤回草稿时显示重新编辑。

主要文件：`message_interaction_service.dart`、`ui/chat/message_action.dart`、`matrix_e2ee_client.dart`、`room_page.dart`、`third_party/matrix/lib/src/timeline.dart` 及 `matrix_sdk_database.dart`、`hive_database.dart`、`hive_collections_database.dart`。新增 `sdk_recall_persistence_test.dart` 源码并修改窗口用例，未运行。仍使用 Matrix redaction，不新增本地临时提示作为权威状态，不改变 E2EE 密钥边界。

## 4. 内容哈希媒体缓存

复现：2MB GIF 收藏连续发送 10 次；同一视频由 A→B→A；同内容改文件名、同名换内容、多会话及清缓存后发送。

根因：已有磁盘内容地址层，但发送未登记原件、收藏每次仍加载原附件、加载器先读盘后查共享内存、外层缓存 key 与内层不一致；发送临时预览按交易/事件 ID 持久化，每次还可能重新生成静态缩略图。

修改：实际 SHA-256 内容在当前账号中统一共享字节和磁盘实体，发送前登记原件/缩略图，收藏读取接入同一缓存；取消嵌套缓存自等待及不同 key 重复持有；临时消息 seed 只留内存，正式原件由内容缓存持久化；GIF 跳过静态缩略图生成，其他图片缩略图按内容去重（48 项/8MB）；清缓存清除解码缓存、代次防旧请求回填。查看器只保留当前及相邻页面预览 Future。每条消息保留小型引用元数据，不重复保存媒体文件；消息、加密事件及引用元数据本身仍随消息数量增长。

主要文件：`media_cache.dart`、`matrix_emoji_vault.dart`、`matrix_e2ee_client.dart`、`room_image_preview_cache.dart`、`outgoing_media_thumbnail_cache.dart`、`ui/chat/contain_image_bubble.dart`、`room_page.dart`。修改 `media_content_dedup_test.dart` 源码，未执行性能/内存实测。

摘要只来自本机实际内容，并随加密消息传递；不把明文摘要、媒体或会话密钥提交业务服务器。旧消息没有可信摘要时必须先读取实际内容才能认定同一文件。

## 5. 图片图库与编辑

复现：点击会话任意图片，左右滑动，再进入编辑并操作各工具及完成菜单。

根因：原查看器只接收一张图片，没有房间图片序列、编辑文档或编辑结果发送入口。

修改：新增 `RoomImageGalleryPage`，按当前房间可见图片时间线浏览，向前触及边界按需载入历史元数据，不预下载全部图片；历史前插保持事件 ID 锚点，缩放时暂禁翻页。新增 `WeChatImageEditorPage`，画笔、emoji、文字、裁剪、马赛克，统一编辑快照撤销/重做；工具在底部、撤销重做在右上、完成在右下。完成后转发进入既有选择聊天页（每个目标重试保持 transaction ID），保存复用相册权限处理，收藏复用加密表情仓库。失败保留编辑内容。公共媒体发送与转发列表检查已加入、允许发消息、E2EE，上传前重新检查。

编辑使用 PNG 输出，不覆盖原图；工作图最长边限制 4096 像素以控制 Mi 6 内存，编辑动画图片时输出当前解码首帧静态图。原始 GIF 发送与查看仍保持动画。裁剪通过拖拽区域再“应用裁剪”，文字和表情添加后可拖动位置。

主要文件：`ui/chat/room_image_gallery.dart`、`ui/chat/wechat_image_editor.dart`、`ui/chat/encrypted_media_view.dart`、`room_page.dart`、SDK `sendEditedImageTo`。HTML demo：`frontend/index.html` 中 `chat-image-gallery-ready`、`chat-image-editor-ready`、`chat-image-editor-complete-sheet`；registry 位于 `packages/ui-contracts/changliao-component-registry.json`，新增两组件与相关状态，目录预期 338。Figma 已退役：本次只更新 HTML demo，未改远端 Figma。

## 回归与验收状态

| ID | 交付给用户的回归步骤 | 本轮状态 |
| --- | --- | --- |
| A1 | 动态头像、作者昵称、评论作者进入同一好友；三按钮分别发消息/语音/视频 | 源码贯通；未测 |
| A2 | 连点、换入口、双端同时首次发消息；核对同一规范私聊；通讯录/搜索/群成员入口 | 复用已有唯一协调机制；未测 |
| B1 | 自己评论短按无菜单、长按一个复制/删除菜单；他人评论仍可回复 | 源码修改、回归源码补充；未测 |
| C1 | 3 分钟内/边界/超过 3 分钟、本人/非本人气泡菜单 | 源码修改、回归源码补充；未测 |
| C2 | 撤回后立即发一条/多条、切换返回、杀进程、断网重连、多端读取 | SDK 持久链路修改、回归源码补充；未测 |
| D1 | GIF 十次、视频往返、改名同内容、同名异内容、跨会话/好友、清理再发送 | 缓存链路修改、回归源码补充；未实测缓存计数、帧率、内存 |
| E1 | 任意图片前后浏览、首末边界、历史加载失败重试、缩放与翻页 | 已实现；未测 |
| E2 | 五工具、拖动、裁剪、撤销/重做、取消、转发/保存/收藏成功及失败重试 | 已实现；未测 |

## 构建、安装与证据

设备观测：ADB `cbd0156b`，`MI_6/sagit`；安装前包 `com.liuhetong.mobile.debug`，`0.3.80-debug/2084`。已拉取安装前 APK 仅检查证书，未读取用户聊天数据。证书 SHA-256 `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`，与本机既有 `.android/debug.keystore` 一致；本轮保留这个独立 Debug 身份，不用不同生产签名覆盖、不生成新密钥、不卸载、不清数据。

工具：Windows/PowerShell7、Flutter3.44.9/Dart3.12.2、JDK17.0.20、Apktool2.12.1、Android build-tools36.0.0。锁文件未升级。三个 `LIUHETONG_BUSINESS_API_URL`、`LIUHETONG_MATRIX_HOMESERVER`、`LIUHETONG_GETUI_URL` 均沿用 HTTPS `liuhetong888.com`。

证据目录：`artifacts/2026-09-10/moments-im-mi6/`。首轮源码构建 `source-build.log` 退出1（Hive数据库变量作用域），已修正；后续构建/重建/安装结果在本节追加。依赖构建有现有 KGP 未来迁移、Java 过时 API/unchecked 提示，本轮未升级或压制这些依赖提示。

审查：先规格再质量/安全。Profile 由 media 交叉审查；撤回由 profile 交叉审查并修正 limited-sync 索引缺口；编辑/图库由 recall 审查并修正历史锚点、布局时重建及资源释放；缓存由 root/media 交叉审查后补发送预览/缩略图重复路径。`git diff --check` 退出0。测试及浏览器/真机验收均未运行，不能称红绿门禁通过。

## 时间与交接

首个精确记录时点：2026-09-10 23:42:10 +08:00（计划落盘，先前调查耗时未知）。调查、实现、源码审查在同一会话连续进行；原生构建/重建与文档记录部分重叠，不能相加当总墙钟。构建和安装完成时间继续追加。无外部签名等待；修正一次编译作用域错误，未重跑无关测试。下一步是完成重建与保数据安装，然后由用户进行上述验收。

### 最终安装结果（2026-09-11 00:05:44 +08:00）

- 第二轮源码构建：`source-build-final.log`，退出0；Gradle 77.4秒。常规ARM64标准Debug，独立包名，build-name/versionCode按命令覆盖为0.3.82-debug/2086，不改变正式版发布配置。
- APK重建/对齐/签名/语义核验：`package.log`，退出0；27,242个类保留，无smali类内容变化；339个原生库/资源项字节一致；清单语义一致；资源及DEX由Apktool重新生成。签名与安装前Debug证书一致，zipalign通过，仅arm64-v8a，debuggable。
- 最终包：`artifacts/2026-09-10/moments-im-mi6/ChatFlow-0.3.82-debug-2086-mi6.apk`，143,442,219字节。
- SHA-256：`565d51364454a126faefa6f090cf69fab60275f0db71e50c470114954cd7dfaf`。
- `adb -s cbd0156b install -r <final.apk>`：退出0，Success。设备读回 `com.liuhetong.mobile.debug`、`0.3.82-debug/2086`，设备base.apk SHA与最终包相同。
- firstInstallTime仍为2026-09-10 09:38:00，lastUpdateTime为2026-09-11 00:05:21；使用覆盖安装，未卸载、未清数据、未启动应用进行功能测试。
- 可精确观察区间23:42:10→00:05:44为23分34秒，含并行实现/审查/构建/文档；区间之前调查耗时未知，主动工作、工具时间不能完整拆分，不编造分项分钟。外部用户/签名等待为零。重试：源码编译失败一次，变量作用域修正后构建通过。
- 代码保留本任务独立修复分支，未推远端、未发布生产、未清理含交付APK的工作树。后续入口为本记录及任务记录；下一步由用户按回归台账验收，未执行场景仍为“待验收”。
