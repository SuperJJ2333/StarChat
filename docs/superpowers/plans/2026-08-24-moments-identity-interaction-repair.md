# 朋友圈身份与互动修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复朋友圈头像、备注名称、单信息流、即时点赞、评论和封面交互，并完成公网 Docker、双模拟器和三字段校源证据。

**Architecture:** FastAPI Moments 服务集中生成查看者相关的身份投影，严格保留 `remark`、`nickname`、`username`、`avatar_url` 来源，并给出 `display_name = remark → nickname → username`。Flutter 使用类型化模型和页面本地可回滚状态实现即时互动；封面使用独立媒体用途和持久化端点。旧 feed `mode` 参数保留兼容，但新客户端只请求 latest。

**Tech Stack:** Python 3.12、FastAPI、SQLAlchemy 2、pytest、Flutter/Dart、image_picker、flutter_test、OpenAPI、Docker Compose、ADB。

---

## 文件归属

- 后端身份/媒体：`services/business-api/app/modules/moments/{service,media}.py`、`services/business-api/app/api/moments.py`、`services/business-api/app/main.py`。
- 兼容迁移：新建 `services/business-api/migrations/versions/0026_moment_cover_media.py`，只扩展上传用途和封面对象键。
- 后端测试/契约：`tests/business_api/moments/{test_moments_api,test_moments_media}.py`、`packages/api-contracts/openapi/liuhetong-v1.yaml`。
- Flutter：`apps/mobile_flutter/lib/features/moments/{moment_models,moments_page}.dart`、`apps/mobile_flutter/lib/ui/moments/{wechat_moment_tile,wechat_moment_viewer}.dart`、`apps/mobile_flutter/lib/ui/components/user_avatar.dart`、`apps/mobile_flutter/lib/ui/foundation/avatar_cache.dart`、`apps/mobile_flutter/lib/core/business_api_client.dart`。
- Flutter 测试：`apps/mobile_flutter/test/features/moments/moments_flow_test.dart`、新建 `apps/mobile_flutter/test/ui/wechat_moment_interactions_test.dart`，并扩展 `apps/mobile_flutter/test/ui/wechat_components_test.dart`。
- UI 合同与证据：`design-demo/artifacts/figma-state.json`、`packages/ui-contracts/changliao-component-registry.json`、`docs/verification/2026-08-24-moments-identity-interaction-repair.md`、`docs/verification/2026-08-24-moments-release.md` 及当日 artifacts 子目录。

现有工作区在上述文件中已有相关未提交实现；执行时保留并验证，不回滚用户改动。

### Task 1: 权威身份投影与头像 URL

**Files:**
- Modify: `tests/business_api/moments/test_moments_api.py`
- Modify: `services/business-api/app/modules/moments/service.py`
- Modify: `services/business-api/app/api/moments.py`
- Modify: `services/business-api/app/main.py`
- Modify: `packages/api-contracts/openapi/liuhetong-v1.yaml`

- [ ] **Step 1: 写失败测试。** 创建作者 `username='alice_id'`、`nickname='Alice'`、头像对象键，以及两个查看者中仅一个具有 `remark='项目小爱'`。断言 feed/detail/comment/like_users/notification 投影均精确返回：

```python
assert author == {
    "user_id": "u1",
    "username": "alice_id",
    "nickname": "Alice",
    "remark": "项目小爱",
    "display_name": "项目小爱",
    "avatar_url": "https://media.example.test/avatars/u1/avatar.png?signed=1",
}
assert other_viewer_author["remark"] is None
assert other_viewer_author["display_name"] == "Alice"
```

- [ ] **Step 2: 运行红测。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py -q
```

预期：现有投影缺 `username`、`remark`、`display_name`，且公网同款旧实现返回空头像。

- [ ] **Step 3: 最小实现。** `_user_projection(session, user_id, viewer_id)` 分别读取 `User` 和查看者的 `ContactProfile`，计算：

```python
nickname = (user.nickname or "").strip()
username = user.username.strip()
remark = (contact.remark or "").strip() or None if contact else None
display_name = remark or nickname or username
avatar_url = storage.signed_read_url(user.avatar_object_key, 300) if user.avatar_object_key else None
```

所有 DTO 必须传递 `viewer_id`；`create_app` 将同一个 `avatar_storage` 注入 Moments router。不得把备注赋给 `nickname`。

- [ ] **Step 4: 运行绿测并导出契约。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py -q
py -3.12 scripts/export_openapi.py
py -3.12 scripts/export_openapi.py --check
```

### Task 2: Flutter 身份模型与可诊断头像

**Files:**
- Modify: `apps/mobile_flutter/lib/features/moments/moment_models.dart`
- Modify: `apps/mobile_flutter/lib/ui/moments/wechat_moment_tile.dart`
- Modify: `apps/mobile_flutter/lib/ui/components/user_avatar.dart`
- Modify: `apps/mobile_flutter/lib/ui/foundation/avatar_cache.dart`
- Modify: `apps/mobile_flutter/test/ui/wechat_components_test.dart`
- Create: `apps/mobile_flutter/test/ui/wechat_moment_interactions_test.dart`

- [ ] **Step 1: 写失败测试。** 断言 `MomentAuthor.fromJson` 保留五个身份字段，tile 只显示 `displayName`，`UserAvatar` 接收远程 URL 和 `diagnosticSource='moments-feed'`。头像 URL 缓存键忽略签名查询参数；错误诊断 URL 只保留 scheme/host/path。

```dart
expect(author.username, 'alice_id');
expect(author.nickname, 'Alice');
expect(author.remark, '项目小爱');
expect(author.displayName, '项目小爱');
expect(AvatarCache.sanitizedUrl(signedUrl), 'https://media.example.test/avatars/u1/avatar.png');
```

- [ ] **Step 2: 运行红测。**

```powershell
Set-Location apps/mobile_flutter
C:\src\flutter\bin\flutter.bat test test/ui/wechat_components_test.dart test/ui/wechat_moment_interactions_test.dart
```

- [ ] **Step 3: 最小实现。** `MomentAuthor` 增加 `username/nickname/remark/displayName/avatarUrl`；tile 的头像、作者、点赞者全部使用 `displayName`。`UserAvatar.errorBuilder` 调用单一诊断函数，日志形如：

```text
[AvatarLoadError] source=moments-feed userId=u1 url=https://host/path errorType=NetworkImageLoadException error=...
```

异常堆栈使用 `FlutterError.reportError` 上报；禁止查询参数和请求头。缓存键基于去查询参数后的稳定 URL。

- [ ] **Step 4: 运行绿测。** 重复 Step 2，预期全部通过且测试日志不包含 `token=`、`sig=`。

### Task 3: 单信息流和可回滚即时点赞

**Files:**
- Modify: `apps/mobile_flutter/lib/features/moments/moment_models.dart`
- Modify: `apps/mobile_flutter/lib/features/moments/moments_page.dart`
- Modify: `apps/mobile_flutter/lib/ui/moments/wechat_moment_tile.dart`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`
- Modify: `apps/mobile_flutter/test/features/moments/moments_flow_test.dart`
- Modify: `apps/mobile_flutter/test/ui/wechat_moment_interactions_test.dart`

- [ ] **Step 1: 写失败 widget 测试。** 断言页面无“推荐”“最新”切换；初始已赞可取消；点击未赞后同一 frame 内 heart fill 与 `like_count + 1`；API 失败后回滚并显示错误；请求进行时不能重复点击。

- [ ] **Step 2: 运行红测。**

```powershell
C:\src\flutter\bin\flutter.bat test test/features/moments/moments_flow_test.dart test/ui/wechat_moment_interactions_test.dart
```

- [ ] **Step 3: 最小实现。** 页面把 feed JSON一次解析为 `List<MomentItem>`，每个 item 的 `copyWith` 支持 `liked/likeCount/likeUsers/comments`。点击时先保存快照并本地替换，再调用 like/unlike；成功后台 refresh，失败恢复快照。API client 默认 `momentsFeed(mode: 'latest')`，UI 不渲染模式控件。

- [ ] **Step 4: 运行绿测。** 重复 Step 2。

### Task 4: 评论入口和即时评论

**Files:**
- Modify: `services/business-api/app/api/moments.py`
- Modify: `services/business-api/app/modules/moments/service.py`
- Modify: `apps/mobile_flutter/lib/features/moments/moment_models.dart`
- Modify: `apps/mobile_flutter/lib/features/moments/moments_page.dart`
- Modify: `apps/mobile_flutter/lib/ui/moments/wechat_moment_tile.dart`
- Modify: `apps/mobile_flutter/test/features/moments/moments_flow_test.dart`
- Modify: `apps/mobile_flutter/test/ui/wechat_moment_interactions_test.dart`

- [ ] **Step 1: 写失败测试。** 后端 POST comment 响应按请求查看者投影备注。Flutter 点击 `moment-comment-button` 打开输入框，空文本禁用；提交成功立即显示评论 `displayName: text`；失败保留输入内容并显示错误。

- [ ] **Step 2: 分别运行后端与 Flutter 红测。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py -q
Set-Location apps/mobile_flutter
C:\src\flutter\bin\flutter.bat test test/features/moments/moments_flow_test.dart test/ui/wechat_moment_interactions_test.dart
```

- [ ] **Step 3: 最小实现。** 路由调用 `comment_dto(session, row, user)`；客户端输入对话框维护 submitting/error，成功把返回 DTO 插入当前 item，失败不 pop、不清空 controller。tile 展示评论列表并提供稳定 key。

- [ ] **Step 4: 运行绿测。** 重复 Step 2。

### Task 5: 专用封面媒体与全屏换封面

**Files:**
- Modify: `services/business-api/app/modules/moments/media.py`
- Modify: `services/business-api/app/modules/moments/models.py`
- Modify: `services/business-api/app/modules/moments/service.py`
- Modify: `services/business-api/app/api/moments.py`
- Create: `services/business-api/migrations/versions/0026_moment_cover_media.py`
- Modify: `tests/business_api/moments/test_moments_media.py`
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart`
- Modify: `apps/mobile_flutter/lib/features/moments/moments_page.dart`
- Modify: `apps/mobile_flutter/lib/ui/moments/wechat_moment_viewer.dart`
- Modify: `apps/mobile_flutter/test/features/moments/moments_flow_test.dart`

- [ ] **Step 1: 写失败测试。** 后端断言普通媒体不能设为封面，只有本人已完成的 `MOMENT_COVER` 可 `PUT /cover`，preferences 保存稳定 `cover_object_key` 并每次读取生成 URL。Flutter 断言点击 header 打开全屏 `InteractiveViewer`，右下角存在 `moment-change-cover`；成功即时更新，失败恢复旧封面并可重试。

- [ ] **Step 2: 运行红测。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_media.py -q
Set-Location apps/mobile_flutter
C:\src\flutter\bin\flutter.bat test test/features/moments/moments_flow_test.dart
```

- [ ] **Step 3: 实现 expand-only 后端。** 上传表增加 `purpose`；偏好表增加 `cover_object_key`，保留旧 `cover_url` 兼容。新增 `/cover/uploads`、`/cover/uploads/{id}/content`、`/cover/uploads/{id}/complete`、`PUT /cover`，所有写请求带幂等键、审计与 Outbox。不得持久化临时签名 URL。

- [ ] **Step 4: 实现 Flutter。** Viewer 使用 `InteractiveViewer` + 右下 SafeArea 按钮；选图后本地 `FileImage` 预览，专用 begin→PUT→complete→setCover 成功后切换网络 URL；异常时保留旧 URL 和待重试文件。

- [ ] **Step 5: 运行绿测、迁移和契约。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_media.py tests/business_api/test_migrations.py -q
py -3.12 scripts/export_openapi.py
py -3.12 scripts/export_openapi.py --check
Set-Location apps/mobile_flutter
C:\src\flutter\bin\flutter.bat test test/features/moments/moments_flow_test.dart
```

### Task 6: UI 合同、质量门与审计证据

**Files:**
- Modify: `design-demo/artifacts/figma-state.json`
- Modify: `packages/ui-contracts/changliao-component-registry.json`
- Create: `docs/verification/2026-08-24-moments-identity-interaction-repair.md`

- [ ] **Step 1: 更新既有 Moments `19:4` 注册项。** 记录单信息流、头像 error、点赞 default/pressed/loading/error、评论 input/submitting/error、封面 viewer/upload/error 状态；不创建重复页面。当前无 Figma MCP 时只更新可验证的版本化账本并在证据中记录限制，不宣称远端 Figma 已写入。

- [ ] **Step 2: 运行定向质量门。**

```powershell
py -3.12 -m pytest tests/business_api/moments/test_moments_api.py tests/business_api/moments/test_moments_media.py tests/business_api/test_migrations.py -q
Set-Location apps/mobile_flutter
C:\src\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib/core/business_api_client.dart lib/features/moments lib/ui/moments lib/ui/components/user_avatar.dart lib/ui/foundation/avatar_cache.dart test/features/moments test/ui
C:\src\flutter\bin\flutter.bat analyze
C:\src\flutter\bin\flutter.bat test test/features/moments/moments_flow_test.dart test/ui/wechat_moment_interactions_test.dart test/ui/wechat_components_test.dart
Set-Location ../..
py -3.12 scripts/export_openapi.py --check
py -3.12 scripts/verify_ui_contract.py
```

- [ ] **Step 3: 运行仓库验证。**

```powershell
pwsh.exe -NoProfile -File scripts/verify.ps1
```

- [ ] **Step 4: 写证据。** 记录每个红/绿命令、三字段数据库/API/Flutter映射、头像日志脱敏样例、Figma 工具限制、规格合规和质量/安全复核结果。

### Task 7: 公网 Docker 发布与双模拟器验证

**Files:**
- Modify: `docs/verification/2026-08-24-moments-release.md`
- Create/Modify only below: `docs/verification/artifacts/2026-08-24/moments-identity-interaction-repair/`

- [ ] **Step 1: 生成后端发布包和 SHA-256。** 只包含本计划后端、迁移和 OpenAPI 文件，产物放在批准的 artifacts 子目录。

- [ ] **Step 2: 上传并重建。** 上传到 `/opt/starchat/.moments-identity-repair.tar`，核对目标路径后解包，运行迁移并 `up -d --build`、`--force-recreate business-api business-worker`。

- [ ] **Step 3: 验证公网。** ready health HTTP 200；容器内 `_user_projection` 有六字段；数据库列和聚合计数只读校验；不得输出真实资料或签名 URL。

- [ ] **Step 4: 构建一次公共域名 APK。**

```powershell
pwsh.exe -NoProfile -File scripts/build_mobile_public_domain.ps1 -BaseUrl https://liuhetong888.com -BuildMode Debug
$apk=(Resolve-Path apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk).Path
Get-FileHash -LiteralPath $apk -Algorithm SHA256
```

- [ ] **Step 5: 安装并验证两台模拟器。** 使用同一 `$apk` 安装 `emulator-5554`、`emulator-5556`，回读 `pm path com.liuhetong.mobile` 和设备 APK SHA-256；保存必要截图到批准的 artifacts 目录。

- [ ] **Step 6: 最终审查与同步。** 运行规格合规审查，再运行质量/安全审查；确认无敏感日志、无 Matrix 资料混入、无临时 URL持久化。提交相关代码和证据，推送当前分支。

## 自检

- 需求 1：Task 1/2；需求 2：Task 1/2；需求 3：Task 3；需求 4：Task 3；需求 5：Task 4；需求 6：Task 5；需求 7：Task 6/7；需求 8：Task 1/6/7。
- 身份字段类型一致：`username/nickname/display_name` 为非空字符串，`remark/avatar_url` 可空。
- 所有生产代码前都有能因缺失行为失败的测试；封面迁移 expand-only，旧字段和旧 feed 参数保留兼容。
- 不包含占位步骤；每个写操作都有明确文件、命令和预期证据。
