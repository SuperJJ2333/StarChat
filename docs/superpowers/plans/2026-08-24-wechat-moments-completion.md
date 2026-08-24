# 微信式朋友圈完善 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将朋友圈完善为微信式好友单列信息流，交付权威身份投影、好友/标签单条可见性、互动、个人封面与动态、媒体、草稿、原生广告、通知和稳定的公网移动端发布。

**Architecture:** 保留 Moments 的现有表与路由，增加可兼容字段、迁移和专注的 DTO/受众/通知服务。可见性在服务端的单一 `VisibilityPolicy` 中执行；Flutter 仅通过扩展后的 `BusinessApiClient` 调用 API，使用 controller 管理分页、乐观互动、草稿和失败重试。发布时按朋友 ID 与标签 ID 解析并冻结受众，历史动态不被标签后续变化改写。

**Tech Stack:** Flutter/Dart、image_picker/image_cropper、FastAPI、Pydantic、SQLAlchemy 2、Alembic、PostgreSQL、pytest、OpenAPI、Docker Compose。

---

## 文件结构与归属

- 后端模型/迁移：`services/business-api/app/modules/moments/{models,service,visibility,media}.py` 与 `migrations/versions/0023_moments_social_completion.py`。
- 后端 HTTP 契约：`services/business-api/app/api/moments.py`、`packages/api-contracts/openapi/liuhetong-v1.yaml`、`tests/business_api/moments/`。
- Flutter 状态：新建 `features/moments/{moment_models,moments_controller,moment_composer_controller}.dart`；UI 按信息流、互动、媒体、个人页、选择器分文件。
- 不修改 Matrix 聊天域、身份写表或金融域；好友/标签只由 Friendship 的公开读取接口解析。

### Task 1: 可见性、标签受众冻结与授权回归

**Files:**
- Modify: `services/business-api/app/modules/moments/models.py`
- Modify: `services/business-api/app/modules/moments/visibility.py`
- Modify: `services/business-api/app/modules/moments/service.py`
- Modify: `services/business-api/app/api/moments.py`
- Create: `services/business-api/migrations/versions/0023_moments_social_completion.py`
- Modify: `tests/business_api/moments/test_moments_api.py`

- [ ] **Step 1: 写失败的参数化 API 测试。** 覆盖：PUBLIC 对陌生登录用户 404、对好友 200；SELF 仅作者；INCLUDE 同时选直接好友与标签成员；EXCLUDE 排除直接好友与标签成员；block 优先拒绝；创建时传非好友 ID 或他人 tag ID 返回 422/404；标签成员变更后旧动态的 frozen audience 不变。

```python
@pytest.mark.parametrize('visibility, viewer, expected', [
    ('PUBLIC', 'friend-1', 200), ('PUBLIC', 'stranger-1', 404),
    ('SELF', 'friend-1', 404), ('SELF', 'author-1', 200),
])
async def test_moment_visibility_is_authoritative(client, visibility, viewer, expected):
    moment = await create_moment(client, actor='author-1', visibility=visibility)
    response = await client.get(f'/api/v1/moments/{moment["id"]}', headers=bearer(viewer))
    assert response.status_code == expected
```

- [ ] **Step 2: 运行红测。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py -q
```

预期：PUBLIC 被陌生用户错误读取、tag IDs 尚未被请求模型接受，测试失败。

- [ ] **Step 3: 添加迁移与请求字段。** `Moment` 添加 JSON `include_tag_ids`、`exclude_tag_ids`（非空默认 `[]`）；迁移使用 `server_default='[]'` 后移除默认。`CreateMoment` 增加 `include_tag_ids`/`exclude_tag_ids`，两个列表最多 30 个，且 INCLUDE/EXCLUDE 不能同时提供 include/exclude 分支。

```python
include_tag_ids: list[str] = Field(default_factory=list, max_length=30)
exclude_tag_ids: list[str] = Field(default_factory=list, max_length=30)
```

- [ ] **Step 4: 实现 `resolve_audience` 与好友限定 PUBLIC。** 在 `MomentsService` 使用 `Friendship`、`ContactTag`、`ContactProfile` 查询 actor 的好友；仅接受这些好友的 direct ID，按 tag 名精确解析联系人 `tags`；对 include/exclude 产出去重、排序后的冻结 user ID。`VisibilityPolicy.can_view` 修改为 PUBLIC/FRIENDS 都需 friendship，INCLUDE 还需 friendship+frozen include，EXCLUDE 需 friendship+不在 frozen exclude；保留 author 和双向 block 优先级。

```python
resolved = sorted(set(direct_user_ids) | tag_member_ids)
if any(user_id not in friend_ids for user_id in direct_user_ids):
    raise AppError(code='MOMENT_AUDIENCE_NOT_FRIEND', message='只能选择好友', status_code=422)
```

- [ ] **Step 5: 运行绿测、迁移往返和格式检查。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py -q
py -3.12 -m pytest tests/business_api/test_migrations.py -q
```

预期：通过。

- [ ] **Step 6: 提交。**

```powershell
git add services/business-api/app/modules/moments services/business-api/app/api/moments.py services/business-api/migrations/versions/0023_moments_social_completion.py tests/business_api/moments/test_moments_api.py
git commit -m "feat(moments): enforce friend and frozen tag visibility"
```

### Task 2: 身份投影、互动状态、评论资料与游标分页

**Files:**
- Modify: `services/business-api/app/modules/moments/service.py`
- Modify: `services/business-api/app/api/moments.py`
- Modify: `tests/business_api/moments/test_moments_api.py`
- Modify: `packages/api-contracts/openapi/liuhetong-v1.yaml`

- [ ] **Step 1: 写红测。** 断言 feed/detail 的 `author` 为 `{user_id,nickname,avatar_url}`，昵称从 `User` 读取；`like_users` 含点赞者资料、`viewer_has_liked` 即时正确；评论含 `author` 与 `parent_author`；相同 created_at 使用 `(created_at,id)` 游标稳定排序，第二页无重复。

```python
assert item['author'] == {'user_id': 'u2', 'nickname': '好友二', 'avatar_url': 'https://...'}
assert item['viewer_has_liked'] is True
assert item['comments'][0]['author']['nickname'] == '评论者'
assert {row['id'] for row in first['items']}.isdisjoint({row['id'] for row in second['items']})
```

- [ ] **Step 2: 运行红测。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py -q
```

预期：缺 `author`、`like_users`、cursor，失败。

- [ ] **Step 3: 实现 DTO/分页。** 在 service 定义 `_user_projection(session,user_id)`；`dto` 返回 `author`、最多 20 项 `like_users`、`like_count`、`viewer_has_liked`、UTC created_at、location/link_url/status；`comment_dto` 接收 session 并返回 author/parent_author。`feed` 和 `search` 接收 cursor/limit（1–50），使用 base64 JSON `{created_at,id}` 过滤并返回 next_cursor；先按可见性过滤再取 page，保证推荐模式不泄露不可见记录。

- [ ] **Step 4: 更新路由与 OpenAPI。** `feed/search` 声明 cursor 和 limit；所有 DTO 使用 Pydantic response model 或更新导出的契约。运行导出而不是手工编辑 YAML。

```powershell
py -3.12 scripts/export_openapi.py
py -3.12 scripts/export_openapi.py --check
```

- [ ] **Step 5: 运行绿测。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py -q
```

预期：通过。

- [ ] **Step 6: 提交。**

```powershell
git add services/business-api/app/api/moments.py services/business-api/app/modules/moments/service.py tests/business_api/moments/test_moments_api.py packages/api-contracts/openapi/liuhetong-v1.yaml
git commit -m "feat(moments): project identities and paginate feeds"
```

### Task 3: 点赞/评论通知与个人朋友圈/删除授权

**Files:**
- Modify: `services/business-api/app/modules/moments/models.py`
- Modify: `services/business-api/app/modules/moments/service.py`
- Modify: `services/business-api/app/api/moments.py`
- Create: `services/business-api/migrations/versions/0024_moment_notifications.py`
- Modify: `tests/business_api/moments/test_moments_api.py`

- [ ] **Step 1: 写红测。** 点赞和评论非本人动态时作者获取一个不含正文的未读通知；`GET /notifications/unread-count` 正确；`POST /notifications/read` 仅标记作者自己的项；unlike/删除评论隐藏对应通知。个人页按倒序返回本人动态且作者可读取 PENDING_REVIEW，非作者不能读取非 published；删除他人动态与删除他人评论返回 403（作者可删除动态下评论）。

- [ ] **Step 2: 运行红测。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py -q
```

预期：notifications route/table 与 personal route 缺失。

- [ ] **Step 3: 实现通知表、端点与个人端点。** 定义 `MomentNotification(id,recipient_id,moment_id,actor_id,kind,comment_id,read_at,invalidated_at,created_at)`，唯一键 `(recipient_id,kind,moment_id,actor_id,comment_id)`；创建/撤销互动时原子更新，审计、Outbox payload 只放 ID 和 kind。增加 `GET /notifications`、`GET /notifications/unread-count`、`POST /notifications/read` 和 `GET /users/{user_id}`；所有个人动态读取经过 `VisibilityPolicy`，本人额外获得 pending 状态。

- [ ] **Step 4: 运行绿测和迁移测试。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py tests/business_api/test_migrations.py -q
```

预期：通过。

- [ ] **Step 5: 提交。**

```powershell
git add services/business-api/app/modules/moments services/business-api/app/api/moments.py services/business-api/migrations/versions/0024_moment_notifications.py tests/business_api/moments/test_moments_api.py
git commit -m "feat(moments): add notifications and personal timeline"
```

### Task 4: 图片与独立封面媒体契约

**Files:**
- Modify: `services/business-api/app/modules/moments/media.py`
- Modify: `services/business-api/app/modules/moments/models.py`
- Modify: `services/business-api/app/modules/moments/service.py`
- Modify: `services/business-api/app/api/moments.py`
- Create: `services/business-api/migrations/versions/0025_moment_cover_media.py`
- Modify: `tests/business_api/moments/test_moments_media.py`
- Modify: `packages/api-contracts/openapi/liuhetong-v1.yaml`

- [ ] **Step 1: 写红测。** 断言动态不能引用未完成/其他作者媒体；九张可完成媒体可发布；cover 上传拒绝非图片、超尺寸和不合法裁剪；cover complete 后 `PUT /cover` 仅允许本人完成的 cover，个人页和 feed header 投影同一 cover URL。

- [ ] **Step 2: 运行红测。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_media.py -q
```

预期：cover purpose/complete/put 路由不存在，动态 media ownership 未强制。

- [ ] **Step 3: 实现用途/所有权。** 为 `MomentMedia` 添加 `purpose`（`MOMENT_IMAGE`、`MOMENT_COVER`）及 crop 元数据；begin/complete 明确图片 MIME、最大数量与尺寸策略，签名 URL 通过现有受控存储生成。`create` 只接受 actor 已 `COMPLETED` 的 `MOMENT_IMAGE` `media://` 引用；cover complete 后 `set_cover` 更新 `MomentsPreference.cover_url`。

- [ ] **Step 4: 更新 OpenAPI 并运行绿测。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_media.py -q
py -3.12 scripts/export_openapi.py
py -3.12 scripts/export_openapi.py --check
```

预期：通过。

- [ ] **Step 5: 提交。**

```powershell
git add services/business-api/app/modules/moments services/business-api/app/api/moments.py services/business-api/migrations/versions/0025_moment_cover_media.py tests/business_api/moments/test_moments_media.py packages/api-contracts/openapi/liuhetong-v1.yaml
git commit -m "feat(moments): validate images and personal covers"
```

### Task 5: Flutter typed models、客户端网关与信息流控制器

**Files:**
- Create: `apps/mobile_flutter/lib/features/moments/moment_models.dart`
- Create: `apps/mobile_flutter/lib/features/moments/moments_controller.dart`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`
- Modify: `apps/mobile_flutter/test/features/moments/moments_flow_test.dart`
- Create: `apps/mobile_flutter/test/features/moments/moments_controller_test.dart`

- [ ] **Step 1: 写红测。** `MomentItem.fromJson` 解析 author/avatar/comments/like users；controller 下拉刷新替换 items、分页追加且 cursor 为空时停止、分页失败保留旧列表并可 retry；like/unlike 乐观更新与失败回滚；网络错误保留草稿。

```dart
expect(state.items.single.author.nickname, '好友二');
expect(state.items.single.viewerHasLiked, isTrue);
expect(state.nextCursor, isNull);
```

- [ ] **Step 2: 运行红测。**

```powershell
Set-Location apps/mobile_flutter
C:\src\flutter\bin\flutter.bat test test/features/moments/moments_controller_test.dart test/features/moments/moments_flow_test.dart
```

预期：models/controller 或 typed client 方法缺失。

- [ ] **Step 3: 实现类型化网关和控制器。** 添加 `MomentAuthor`、`MomentCommentView`、`MomentItem`、`MomentPage`、`MomentNotificationView`；client 添加 cursor feed/search、detail、like/unlike、comment/deleteComment、deleteMoment、personalTimeline、notifications、read；controller 用 `ChangeNotifier` 公开 loading/refreshing/loadingMore/error/retry 与不可变列表，所有异常显示可读错误码映射。

- [ ] **Step 4: 运行绿测与 format。**

```powershell
C:\src\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib/features/moments lib/core/business_api_client.dart test/features/moments
C:\src\flutter\bin\flutter.bat test test/features/moments/moments_controller_test.dart test/features/moments/moments_flow_test.dart
```

- [ ] **Step 5: 提交。**

```powershell
git add apps/mobile_flutter/lib/features/moments apps/mobile_flutter/lib/core/business_api_client.dart apps/mobile_flutter/test/features/moments
git commit -m "feat(moments): add typed feed controller and API gateway"
```

### Task 6: 微信式信息流、互动和大图组件

**Files:**
- Create: `apps/mobile_flutter/lib/ui/moments/wechat_moment_interactions.dart`
- Create: `apps/mobile_flutter/lib/ui/moments/wechat_moment_viewer.dart`
- Modify: `apps/mobile_flutter/lib/ui/moments/wechat_moment_tile.dart`
- Modify: `apps/mobile_flutter/lib/ui/moments/wechat_moment_image_grid.dart`
- Modify: `apps/mobile_flutter/lib/features/moments/moments_page.dart`
- Modify: `apps/mobile_flutter/test/features/moments/moments_flow_test.dart`
- Create: `apps/mobile_flutter/test/ui/wechat_moment_interactions_test.dart`

- [ ] **Step 1: 写红 widget 测试。** 断言圆形 `UserAvatar` 使用 `author.avatarUrl`、可点击头像/昵称；昵称 key `moment-author-name`；九宫格加载/失败占位与点击进入 `PageView`；相对时间；点赞按钮变化和点赞者列表；评论输入/发送；长按本人评论显示红色删除确认，非本人无删除操作。

- [ ] **Step 2: 运行红测。**

```powershell
Set-Location apps/mobile_flutter
C:\src\flutter\bin\flutter.bat test test/ui/wechat_moment_interactions_test.dart test/features/moments/moments_flow_test.dart
```

预期：相关 key、viewer 或 callback 不存在。

- [ ] **Step 3: 实现复用 UI。** tile 使用 author projection 绝不直接显示 author_id；不改变 `UserAvatar` URL 解析；通过 `GestureDetector` 实现 tap/long press，操作小菜单使用 CupertinoPopupSurface；图格保持 1/4/9 布局，Image.network 的 loading/error builder；viewer 用 `PageView` + `InteractiveViewer`；`formatMomentTime` 采用设计规格规则。

- [ ] **Step 4: 接入 `MomentsPage`。** `CustomScrollView`/refresh 控件驱动 `MomentsController.refresh/loadMore`；footer 显示加载、结束、失败重试；空态/首屏错误均有 retry；操作后从 controller 刷新实时投影。

- [ ] **Step 5: 运行绿测与 UI drift。**

```powershell
C:\src\flutter\bin\flutter.bat test test/ui/wechat_moment_interactions_test.dart test/features/moments/moments_flow_test.dart
Set-Location ../..
py -3.12 scripts/verify_ui_contract.py
```

- [ ] **Step 6: 提交。**

```powershell
git add apps/mobile_flutter/lib/ui/moments apps/mobile_flutter/lib/features/moments apps/mobile_flutter/test/ui apps/mobile_flutter/test/features/moments
git commit -m "feat(moments): deliver WeChat-style feed interactions"
```

### Task 7: 发布、多图上传、链接地点与朋友/标签受众选择器

**Files:**
- Create: `apps/mobile_flutter/lib/features/moments/moment_composer_controller.dart`
- Create: `apps/mobile_flutter/lib/features/moments/moment_audience_picker_page.dart`
- Modify: `apps/mobile_flutter/lib/features/moments/moments_page.dart`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`
- Modify: `apps/mobile_flutter/pubspec.yaml`
- Modify: `apps/mobile_flutter/test/features/moments/moments_flow_test.dart`
- Create: `apps/mobile_flutter/test/features/moments/moment_composer_controller_test.dart`

- [ ] **Step 1: 写红测。** composer 在无文字/图片/link/location 时禁用发表；11 个媒体项拒绝；`INCLUDE`/`EXCLUDE` 选择器显示“选择标签或者朋友”、可搜索朋友、标签及 friend_count，输出 `directUserIds/tagIds`；上传中显示 progress，任一失败保留草稿与 retry；publish 请求含 link/location 与正确的 include/exclude user/tag IDs。

- [ ] **Step 2: 运行红测。**

```powershell
Set-Location apps/mobile_flutter
C:\src\flutter\bin\flutter.bat test test/features/moments/moment_composer_controller_test.dart test/features/moments/moments_flow_test.dart
```

预期：composer controller、picker 和 upload API 缺失。

- [ ] **Step 3: 实现媒体网关与 composer。** 使用 `image_picker` 多选、现有压缩插件或 `image` isolate 压缩；每一项执行 begin→PUT content→complete 并记录百分比。为 `BusinessApiClient` 添加二进制上传、moment image/cover begin/complete、setCover、发布的 location/link/tag 字段；禁止将本地文件路径发到业务 API。

- [ ] **Step 4: 实现选择器和发布页。** 朋友来自 `listContacts()`、标签来自 `listContactTags()`；列表可搜索/字母排序、多选；标签行显示人数，提交 ID 不提交名字；可见性菜单按“公开（好友）/私密/只给谁看/不给谁看”；INCLUDE/EXCLUDE 选择器标题严格为“选择标签或者朋友”。页面展示草稿、上传、失败、可重试和成功返回信息流。

- [ ] **Step 5: 运行绿测。**

```powershell
C:\src\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib/features/moments lib/core/business_api_client.dart test/features/moments
C:\src\flutter\bin\flutter.bat test test/features/moments/moment_composer_controller_test.dart test/features/moments/moments_flow_test.dart
```

- [ ] **Step 6: 提交。**

```powershell
git add apps/mobile_flutter/lib/features/moments apps/mobile_flutter/lib/core/business_api_client.dart apps/mobile_flutter/pubspec.yaml apps/mobile_flutter/test/features/moments
git commit -m "feat(moments): compose media and tag-scoped audiences"
```

### Task 8: 个人朋友圈、独立封面与通知页

**Files:**
- Create: `apps/mobile_flutter/lib/features/moments/moment_personal_page.dart`
- Create: `apps/mobile_flutter/lib/features/moments/moment_notifications_page.dart`
- Modify: `apps/mobile_flutter/lib/features/moments/moments_page.dart`
- Modify: `apps/mobile_flutter/test/features/moments/moments_flow_test.dart`

- [ ] **Step 1: 写红 widget 测试。** 个人页 cover 使用 `coverUrl` 的 error 占位、3:1 crop、头像圆形及昵称；自己可看到 pending/failed 标签、删除操作的二次确认；他人没有删除入口；通知 badge 显示未读数、进入页面后标已读、通知不展示原正文/媒体。

- [ ] **Step 2: 运行红测。**

```powershell
Set-Location apps/mobile_flutter
C:\src\flutter\bin\flutter.bat test test/features/moments/moments_flow_test.dart
```

预期：personal/notification 页面与 keys 缺失。

- [ ] **Step 3: 实现个人页和封面流程。** 从任一 avatar/name 进入个人页；自己显示“更换封面”，采用 cover 上传 API、裁剪预览、上传失败重试；动态以 created_at 倒序；删除必须弹 CupertinoAlertDialog，确认按钮使用 destructive red；本地草稿/发送中/失败以显式 chip 处理，只有成功 publish 更新服务端信息流。

- [ ] **Step 4: 实现通知入口。** 导航栏增加互动通知入口/badge；通知列表按时间排序，进入成功标记已读；点击只进入当前可见动态 detail，不可见/失效项显示已不可用。

- [ ] **Step 5: 运行绿测。**

```powershell
C:\src\flutter\bin\flutter.bat test test/features/moments/moments_flow_test.dart
```

- [ ] **Step 6: 提交。**

```powershell
git add apps/mobile_flutter/lib/features/moments apps/mobile_flutter/test/features/moments
git commit -m "feat(moments): add personal cover and interaction notifications"
```


### Task 8A: 私有草稿保存与原生广告投影

**Files:**
- Modify: `services/business-api/app/modules/moments/models.py`
- Modify: `services/business-api/app/modules/moments/service.py`
- Modify: `services/business-api/app/api/moments.py`
- Create: `services/business-api/migrations/versions/0026_moment_drafts_native_ads.py`
- Modify: `tests/business_api/moments/test_moments_api.py`
- Modify: `apps/mobile_flutter/lib/features/moments/moment_composer_controller.dart`
- Modify: `apps/mobile_flutter/lib/features/moments/moments_page.dart`
- Modify: `apps/mobile_flutter/lib/ui/moments/wechat_moment_tile.dart`
- Modify: `apps/mobile_flutter/test/features/moments/moments_flow_test.dart`

- [ ] **Step 1: 写失败测试。** 断言 `PUT /draft` 仅作者可 `GET`、`DELETE` 后返回 404、草稿不出现在 feed；客户端 dirty composer 返回时显示“保存草稿”，保存后重进恢复文本/媒体/可见性/受众；广告 DTO 具有 `kind=AD`，tile 显示 `广告` key、没有点赞/评论/个人页入口，曝光与点击同 idempotency key 只记录一次。
- [ ] **Step 2: 运行红测。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py -q
Set-Location apps/mobile_flutter; C:\src\flutter\bin\flutter.bat test test/features/moments/moments_flow_test.dart
```

- [ ] **Step 3: 实现后端。** 建立 `MomentDraft` 与 `NativeMomentAd` expand-only 迁移；draft 保存完整发表 payload 但仅由 owner 读取/删除，发布成功删除 draft。广告只从受控服务读取；feed 以 `kind: 'AD'` 标记，且广告不调用 MomentLike/MomentComment。新增 impression/click 事件并做 idempotency、audit/outbox。
- [ ] **Step 4: 实现 Flutter。** composer controller 维护 dirty/snapshot，返回时 `CupertinoAlertDialog` 给“取消/不保存/保存草稿”；保存并重进恢复所有编辑状态；广告 tile 复用常规视觉，右下角 `moment-ad-label`，禁用互动与个人页，调用曝光/点击 API。
- [ ] **Step 5: 运行绿测、导出契约并提交。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py -q
Set-Location apps/mobile_flutter; C:\src\flutter\bin\flutter.bat test test/features/moments/moments_flow_test.dart
Set-Location ../..; py -3.12 scripts/export_openapi.py; py -3.12 scripts/export_openapi.py --check
git add services/business-api apps/mobile_flutter packages/api-contracts/openapi tests/business_api/moments
git commit -m "feat(moments): persist drafts and label native ads"
```

### Task 9: Figma、UI 注册表、HTML 设计演示及端到端证据

**Files:**
- Modify: `design-demo/artifacts/figma-state.json`
- Modify: `packages/ui-contracts/changliao-component-registry.json`
- Modify: `design-demo/src/components/moments.js`
- Modify: `design-demo/src/screens/moments.js`
- Modify: `tests/mobile/test_ui_component_registry.py`
- Create: `docs/verification/2026-08-24-moments-ui-review.md`

- [ ] **Step 1: Figma-first 写红契约测试。** 注册 `moments-feed-v2`、`moment-interactions`、`moment-audience-picker`、`moment-personal-cover`、`moment-notifications`、`moment-composer-draft`、`moment-native-ad`，断言每项有 Flutter file/name、HTML tag、Figma key `19:4`、props/variants/states/token 映射。

- [ ] **Step 2: 运行红测。**

```powershell
py -3.12 -m pytest tests/mobile/test_ui_component_registry.py -q
```

预期：新组件缺失。

- [ ] **Step 3: 先更新 Figma/export ledger/registry。** 通过 canonical Discovery/Moments node `19:4` 更新信息流、发表、受众选择器、封面、互动和通知 frame；复用 WeChat tokens，刷新 `figma-state.json` 与 registry；HTML 演示用同一状态和组件标签。

- [ ] **Step 4: 运行绿测与 demo 测试。**

```powershell
py -3.12 -m pytest tests/mobile/test_ui_component_registry.py -q
py -3.12 scripts/verify_ui_contract.py
Set-Location design-demo
npm test
```

预期：全部通过。

- [ ] **Step 5: 写 UI 评审与提交。** 记录 node URL、默认/按下/禁用/上传/失败/空态/删除确认/权限拒绝状态、token/layout 结论和截图路径。

```powershell
git add design-demo packages/ui-contracts tests/mobile docs/verification/2026-08-24-moments-ui-review.md
git commit -m "docs(ui): register and review Moments completion"
```

### Task 10: 定向发布验证、公网同步与双模拟器一致 APK

**Files:**
- Create: `docs/verification/2026-08-24-moments-release.md`
- Create: `docs/verification/artifacts/2026-08-24/moments-release/`

- [ ] **Step 1: 运行定向质量门。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py tests/business_api/moments/test_moments_media.py -q
Set-Location apps/mobile_flutter
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test test/features/moments/moments_controller_test.dart test/features/moments/moment_composer_controller_test.dart test/features/moments/moments_flow_test.dart test/ui/wechat_moment_interactions_test.dart
Set-Location ../..
py -3.12 scripts/export_openapi.py --check
py -3.12 scripts/verify_ui_contract.py
```

- [ ] **Step 2: 仅在跨模块失败无法定位时升级完整验证。**

```powershell
pwsh.exe -NoProfile -File scripts/verify.ps1
```

- [ ] **Step 3: 同步公网并强制重建。** 打包本次 backend、migration 与 OpenAPI 文件到 `docs/verification/artifacts/2026-08-24/moments-release/moments-backend.tar`，上传 `/opt/starchat/.moments-backend.tar`；解包后执行：

```powershell
ssh -p 23421 root@207.56.8.8 'set -e; cd /opt/starchat; tar -xf .moments-backend.tar; rm .moments-backend.tar; docker compose --env-file .env -f docker-compose.yml -f docker-compose.production.yml up -d --build business-api business-worker; docker compose --env-file .env -f docker-compose.yml -f docker-compose.production.yml up -d --force-recreate business-api business-worker'
Invoke-WebRequest https://liuhetong888.com/api/v1/health/ready -UseBasicParsing
```

预期：HTTP 200 且迁移成功。

- [ ] **Step 4: 构建一次并安装两台模拟器。**

```powershell
pwsh.exe -NoProfile -File scripts/build_mobile_public_domain.ps1 -BaseUrl https://liuhetong888.com -BuildMode Debug
$apk=(Resolve-Path apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk).Path
Get-FileHash -LiteralPath $apk -Algorithm SHA256
& E:\software\platform-tools\adb.exe -s emulator-5554 install --no-streaming -r $apk
& E:\software\platform-tools\adb.exe -s emulator-5556 install --no-streaming -r $apk
```

- [ ] **Step 5: 回读设备 APK 哈希并写证据。**

```powershell
& E:\software\platform-tools\adb.exe -s emulator-5554 shell 'pm path com.liuhetong.mobile'
& E:\software\platform-tools\adb.exe -s emulator-5556 shell 'pm path com.liuhetong.mobile'
```

记录实际 apk SHA-256、两个设备回读 hash、公网 health、定向命令输出、Figma node URL 和功能验证结果到 `docs/verification/2026-08-24-moments-release.md`。

- [ ] **Step 6: 提交。**

```powershell
git add docs/verification/2026-08-24-moments-release.md docs/verification/artifacts/2026-08-24/moments-release
git commit -m "docs(release): verify Moments public deployment"
```

## 自检

- 覆盖规格：身份头像/昵称（Task 2/6）、互动（Task 2/3/6）、本人动态删除（Task 3/8）、媒体/大图（Task 4/7/6）、权限与朋友/标签（Task 1/7）、封面（Task 4/8）、文本/链接/地点（Task 7）、时间/分页/错误（Task 2/5/6）、通知（Task 3/8）、草稿/广告（Task 8A）、Figma（Task 9）、公网双模拟器（Task 10）。
- 无占位内容；所有接口字段和 Flutter 调用在相应前序任务定义。
- 已保持数据库变更为 expand-only 新列/新表/新端点，不引入破坏性 OpenAPI。
