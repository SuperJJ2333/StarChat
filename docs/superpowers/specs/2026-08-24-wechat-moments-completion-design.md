# 微信式朋友圈完善设计

**状态：** 已批准
**日期：** 2026-08-24
**范围：** Flutter 朋友圈 UI、FastAPI Moments 域、OpenAPI、媒体、好友/标签可见性、通知与公网发布流程。

## 目标

将当前仅能简化浏览/发表的朋友圈补齐为微信式单列信息流。每个互动、媒体和可见性动作必须有真实业务 API 支撑；身份、好友关系、头像与昵称均来自业务域权威投影，朋友圈不进入 Matrix E2EE 域。

## 已确认产品决策

1. 信息流采用微信式单列布局：圆形头像、昵称、正文、位置/链接预览、九宫格、相对时间、点赞与评论区。
2. `PUBLIC` 的实际受众是已建立双向好友关系的用户，不对陌生登录用户开放；`SELF` 仅作者。
3. 封面图独立保存为个人朋友圈资料，不依赖某条动态；使用横向封面裁剪规则，供信息流页与个人朋友圈页复用。
4. 实施采用渐进式补齐：保留 `moments`、`moment_likes`、`moment_comments`、`moments_preferences` 和现有 API，所有新增字段/端点保持兼容。
5. 单条可见范围含：
   - 公开（好友）；
   - 私密（仅自己）；
   - 只给谁看：选择一个或多个朋友及/或标签，最终受众为所选朋友与所选标签当前成员的并集；
   - 不给谁看：先取全部好友，再排除所选朋友与所选标签当前成员的并集。
6. 标签在发布/编辑时按**标签 ID**提交并在服务端解析为发布者当前联系人投影；标签删除/改名不会扩大历史动态的授权范围。发布时把解析出的好友 ID 去重并冻结到单条动态，后续标签成员增删不追溯改写既有动态可见性。
7. “选择标签或者朋友”使用一个可搜索的统一选择器，顶部为朋友列表、下方为标签列表；选择标签时即时展示标签人数及展开后的受众数量。
8. 发布页有任意文字、图片、链接、位置或可见性变更后返回，必须显示“是否保存草稿”确认；保存草稿后下次进入完整恢复编辑状态（图片恢复为本地可访问缓存项或已完成的私人上传引用），放弃则删除草稿。
9. 支持原生广告接口。广告与正常朋友圈使用相同的信息流卡片、媒体格与互动排版，但右下角必须以小尺寸、低干扰的“广告”标识区分；广告永不伪装为用户动态，不能使用用户点赞/评论、不能进入个人朋友圈，也不能绕过用户的好友动态隐私。

## 架构

### 受众与权限

`Moment` 新增 `include_tag_ids`、`exclude_tag_ids`（审计显示来源）与冻结后的 `include_user_ids`、`exclude_user_ids`。服务层 `resolve_audience(actor, direct_ids, tag_ids)` 验证每个直接 ID 是 actor 的好友、每个 tag ID 属于 actor；从 `ContactProfile.tags` 精确拆分标签名并得到成员。禁止前端传入不属于自己的用户或标签。

`VisibilityPolicy.can_view` 对所有 feed、search、detail、like、unlike、comment、delete-comment 和 notification payload 统一执行：作者始终可看；双向 block 始终拒绝；`PUBLIC` 与 `FRIENDS` 都要求好友；`INCLUDE` 要求好友且在冻结 include 集合；`EXCLUDE` 要求好友且不在冻结 exclude 集合；`SELF` 仅作者。客户端不能绕过服务端校验。

### 身份、互动与通知

DTO 一次性投影 `author {user_id,nickname,avatar_url}`、`like_users`（有上限的头像昵称列表）、评论者与被回复者资料、`viewer_has_liked`、相对时间所需 UTC `created_at`。用户昵称/头像来自 Identity 读接口，不复制到 Moments 表。

新增 `MomentNotification`：点赞与评论写入时为非作者创建未读通知；列表/未读数/标记已读均通过 Moments 应用服务、审计和 Outbox；不包含动态正文或私密媒体内容。删除评论/取消点赞会使对应通知失效或隐藏。

### 草稿与原生广告

`MomentDraft` 是作者私有的业务草稿记录，保存 text、已上传媒体引用、可见性、直接朋友/标签 ID、location、link_url 和 updated_at；它不出现在 feed、搜索、通知、个人已发布动态或任何其他用户 API。返回发表页时客户端先判断 dirty，再提供保存草稿/不保存/继续编辑。草稿图片使用应用私有缓存路径和/或作者已完成但尚未引用的 `MomentMedia`；恢复时必须重新验证文件/媒体归属并显式标记失效项。

`NativeMomentAd` 仅由业务后台/投放提供者写入；feed DTO 以 `kind: "AD"` 与 `ad` 字段标记，包含广告主展示资料、正文、受控媒体、跳转 URL、免责声明和广告 ID。客户端复用 `WeChatMomentTile`，但隐藏点赞/评论/个人主页/删除入口，并在右下角渲染“广告”。广告曝光/点击使用专用幂等事件 API，禁止携带朋友圈正文以外的敏感数据。

### 媒体与个人页

媒体上传仅允许作者已完成、可引用的 `MomentMedia`；客户端相册多选（最多 9）、本地压缩、预览删除、逐项进度/重试后才发布。服务端返回签名/受控媒体 URL；图片格使用加载、失败占位，大图使用 `InteractiveViewer`（缩放）和 `PageView`（滑动）。

新增封面上传的独立媒体用途（`MOMENT_COVER`），服务端验证类型、大小和横向裁剪元数据，保存 `MomentsPreference.cover_url`。个人朋友圈端点返回 profile、cover、作者自己的倒序动态（包括草稿、发送中与失败）；只有作者可见本地草稿/发送状态，正式发布由服务端状态权威返回。

### API

新增/扩展（均在 `/api/v1/moments`）：
- `GET /feed?mode=&cursor=&limit=`、`GET /search?...` 返回稳定游标；
- `GET /users/{user_id}` 返回可见的个人朋友圈及封面；
- `POST /cover/uploads`、`POST /cover/uploads/{id}/complete`、`PUT /cover`；
- 创建动态增加 `include_tag_ids`/`exclude_tag_ids` 与受众验证；
- `DELETE /{id}/likes`、`DELETE /{id}/comments/{comment_id}` 在 Flutter client 暴露；
- `GET /notifications`、`GET /notifications/unread-count`、`POST /notifications/read`；
- `GET/PUT/DELETE /draft`；
- `GET /feed` 可返回受标记的原生广告，`POST /ads/{ad_id}/impressions`、`POST /ads/{ad_id}/clicks`。

所有写请求要求 Idempotency-Key；删除前由客户端二次确认，服务端仍执行作者/评论归属验证。结果使用清晰的错误码，客户端保留草稿或失败队列并提供重试。

## Flutter 体验

- `MomentsPage` 用 controller 管理初始加载、下拉刷新、游标分页、网络错误与重试；点击头像/昵称进入个人页；点击互动按钮弹出微信式点赞/评论小菜单，长按本人评论弹出删除确认。
- 发布页支持文字（5000 上限）、链接 URL 预览、位置、好友/标签受众选择、可见性说明、多图压缩上传与进度。返回含编辑内容的页面必须确认保存草稿；保存后重进完整恢复。没有文字、媒体、链接或位置时禁用发表。
- 封面区域比例遵循微信横向视觉（3:1 左右），头像重叠在右下；头像圆形，昵称使用强调字重；列表间距、颜色、触感反馈复用现有 WeChat tokens。
- 时间显示：不足一分钟“刚刚”，一小时内“X分钟前”，当天“X小时前”，前一天“昨天”，同年显示月日，跨年显示年月日。

## 验收与发布

1. 服务端参数化测试覆盖 5 种可见范围、朋友/非朋友/黑名单、直接好友与标签展开、历史受众冻结、所有读取及互动入口拒绝越权。
2. Flutter widget/controller 测试覆盖头像昵称、图片状态/大图、互动切换/评论删除、封面、个人动态、草稿/失败重试、下拉/分页、新通知与选择器。
3. OpenAPI 导出/检查、UI registry/ledger/Figma Drift 检查、定向测试。仅在定位不出跨模块问题时升级全量测试。
4. 测试覆盖草稿保存/放弃/恢复和广告标记、非互动限制与曝光/点击幂等。
5. 本地变更验证后同步 `/opt/starchat` 公网服务，重建并 force-recreate API/worker；公网 ready health 必须 200。
6. 构建一次公共域名 APK，安装 `emulator-5554`、`emulator-5556`，回读两台安装 APK SHA-256 必须完全相同。
