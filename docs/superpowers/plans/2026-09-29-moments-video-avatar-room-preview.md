# Android 2191 媒体发送、头像与会话预览 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让朋友圈视频可靠地在后台发送并有首帧封面，让业务头像重签后继续命中缓存，让会话中已缓存的图片和视频预览再次进房时尽早显示。

**Architecture:** 保留现有朋友圈持久化任务、上传 ID 和幂等发布；仅为媒体 PUT 分配按字节数计算的时限，并在发布前强制确认封面。头像由业务 API 为同一私有对象签名 URL 附加稳定 `v`，客户端按账号和头像版本缓存；会话预览复用现有加密磁盘缓存，增加有界的跨房间内存首帧和可见窗口预热。服务端候选以当次实际运行镜像为基线，不从当前落后的共享源码直接整体重建。

**Tech Stack:** Flutter/Dart、`http`、`flutter_image_compress`、Matrix 加密媒体缓存、FastAPI/Pydantic、pytest、PowerShell 7、Android 固定签名重建。

---

依据：[批准规格](../specs/2026-09-29-moments-video-avatar-room-preview-design.md)、[产品规范](../specs/2026-08-12-starchat-product-modernization-design.md)、[移动工作流](../../runbooks/mobile-delivery-workflow.md)、[生产工作流](../../runbooks/admin-production-workflow.md)。本计划只覆盖该规格的三模块；钱包与其余 UI 由并行计划负责。本任务以 Android Debug 0.4.22（2191）为缺陷基线，不能将新 Debug、服务候选和线上发布混为一项完成状态。

## 文件结构与所有权

| 文件 | 单一职责 |
| --- | --- |
| `apps/mobile_flutter/lib/core/business_api_client.dart`、新建 `test/core/business_api_media_put_test.dart` | 媒体 PUT 单次/总时限及同 upload ID 的鉴权重试；普通业务请求时限保持不变 |
| `apps/mobile_flutter/lib/features/moments/moment_publish_coordinator.dart`、`test/features/moments/moment_publish_coordinator_test.dart`、新建 `test/features/moments/moment_poster_policy_test.dart` | 视频抽帧/压缩、封面必需、后台任务阶段、失败与重试 |
| `apps/mobile_flutter/lib/core/chat_diagnostics.dart`、`test/core/chat_diagnostics_test.dart` | 有界的朋友圈发送阶段与原因上报；现有匿名化、离线队列及账号代次不变 |
| `services/business-api/app/api/client_diagnostics.py`、`tests/business_api/test_client_diagnostics.py` | 诊断接收端固定枚举与旧版本兼容；不接收任意文本 |
| `packages/api-contracts/openapi/liuhetong-v1.yaml` | 根集成者在当前生产 0091/S3 源码已与候选对齐、媒体与钱包服务代码稳定后串行导出合并契约，媒体代理不并行编辑；若对齐未完成，停止服务端契约/候选发布 |
| `services/business-api/app/integrations/private_storage.py`、`tests/business_api/identity/test_profile_api.py`、`tests/business_api/moments/test_moments_api.py` | 在头像对象签名 URL 的共同出口加稳定版本；媒体、封面 URL 的签名语义不变 |
| `apps/mobile_flutter/lib/ui/foundation/avatar_cache.dart`、`apps/mobile_flutter/lib/features/matrix/profile_repository.dart`、`test/ui/wechat_components_test.dart`、`test/features/matrix/profile_repository_test.dart`、`test/features/matrix/avatar_cold_start_test.dart` | 头像 URL 只作下载地址，缓存/失效按稳定 `v` 与账号边界 |
| `apps/mobile_flutter/lib/features/matrix/video_poster_session_cache.dart`、`video_poster_pipeline.dart`、`room_page.dart`、`room_image_preview_cache.dart`、`apps/mobile_flutter/lib/ui/chat/wechat_video_message.dart`、对应 `test/features/matrix/` 用例 | 复用已验证的小首帧、可见窗口预热和来源计数；不触及完整视频预取或闪照普通缓存 |
| `docs/verification/artifacts/2026-09-29/android-2191-media-preview/` | 输入 SHA、红绿测试、生产基线差异、构建及设备证据；媒体代理独占此目录 |
| `docs/workflow/tasks/2026-09-29-android-2191-followup.md` | 根任务在三个模块合并后串行记录阶段、构建和设备状态，媒体代理不并行编辑 |

文件所有权不得与并行任务冲突。`docs/verification/artifacts/...` 仅放验证产物；不得把真实媒体、账号、签名 URL、令牌、恢复密钥或原始异常写入仓库。Flutter 工具使用 `C:/src/flutter/bin/flutter.bat` 和 `C:/src/flutter/bin/dart.bat`；所有终端命令由 `pwsh.exe` 执行，并先设置无 BOM UTF-8、`PYTHONUTF8=1`、`PYTHONIOENCODING=utf-8`。如仓库根目录存在 `.codegraph/`，定位代码先用 CodeGraph；当前工作树无该目录。

## Task 1: 锁定基线并证明失败路径

**Files:**
- Test: `apps/mobile_flutter/test/core/business_api_media_put_test.dart`
- Test: `apps/mobile_flutter/test/features/moments/moment_publish_coordinator_test.dart`
- Evidence: `docs/verification/artifacts/2026-09-29/android-2191-media-preview/baseline.md`

- [ ] **Step 1: 固定输入。** 记录工作树 commit、未提交文件、`pubspec.lock` 与当前运行 Business API 不可变镜像 SHA；只读核对 `0091` 封面路由、私有 S3 主写/本地回退、头像读取路由以及未授权 401。`docs/workflow/current-state.md` 的上一时点镜像不是本次基线。命令示例：

```powershell
git rev-parse HEAD
git status --short
Get-FileHash -Algorithm SHA256 -LiteralPath 'apps/mobile_flutter/pubspec.lock'
pwsh -NoProfile -File scripts/starchat-server.ps1 -Action Command -RemoteCommand 'docker ps --filter name=starchat-business-api --format "{{.Image}} {{.ID}}"'
```

预期：源 SHA 与镜像身份均可写入证据；若与规格中的 `sha256:0bdf751c…5042993` 不同，重新只读核对，不能沿用旧结论。

- [ ] **Step 2: 先建失败测试。** 在 `business_api_media_put_test.dart` 写 `MockClient`：媒体 PUT 在第 9 秒返回 204，普通 GET 在第 9 秒才返回 200；断言前者应该成功、后者仍应 `TimeoutException`。用现有 `SecureSessionStore` 假存储创建会话，不使用生产凭证。再在 `moment_publish_coordinator_test.dart` 写封面缺失分支：视频 PUT/complete 成功但抽帧不可用，断言 `/moments` 调用数为 0、任务为 `failed`、队列目录与 upload ID 仍在。

```dart
test('slow valid video PUT uses a media budget; ordinary GET stays short', () async {
  final client = MockClient((request) async {
    await Future<void>.delayed(const Duration(seconds: 9));
    return request.method == 'PUT'
        ? http.Response('', 204)
        : http.Response('{}', 200);
  });
  final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: await testMomentSession(), client: client);
  final lease = await api.captureMomentPublishSession();
  await api.putMomentTask(lease, 'upload-1', Uint8List(64 * 1024), 'video/mp4');
  await expectLater(api.getJson('/profile'), throwsA(isA<TimeoutException>()));
});
```

`testMomentSession()` 在新测试文件中创建 `SecureSessionStore`，使用该文件内的内存 `SecureKeyValueStore` 保存测试用 access/refresh token 与 `@a:example.test`，沿用 `moment_publish_coordinator_test.dart` 顶部的 `_Store` 实现；不得共享生产会话或真实凭证。

- [ ] **Step 3: 运行红灯。** 从 `apps/mobile_flutter` 运行：

```powershell
& 'C:/src/flutter/bin/flutter.bat' test test/core/business_api_media_put_test.dart test/features/moments/moment_publish_coordinator_test.dart --plain-name 'slow valid video PUT uses a media budget; ordinary GET stays short'
```

预期：媒体 PUT 因现有 8 秒 `_httpTimeout` 失败；记录实际退出码。封面测试单独 `--plain-name` 运行，预期旧实现会调用 `/moments` 或任务成功。模拟器与用户实际视频尚未证明命中这两条路径，结论继续标记为代码级根因候选。

## Task 2: 媒体 PUT 独立时限与不确定回执

**Files:**
- Modify: `apps/mobile_flutter/lib/core/business_api_client.dart:1972-1986,2823-2945`
- Test: `apps/mobile_flutter/test/core/business_api_media_put_test.dart`
- Test: `apps/mobile_flutter/test/features/moments/moment_publish_coordinator_test.dart`

- [ ] **Step 1: 添加时限边界红灯。** 断言 0.5 MiB、20 MiB 与异常大的输入分别得到 30、335、360 秒；同一媒体首次 401 后刷新再试时总预算至少容纳两个单次上限加 20 秒，切换账号仍拒绝续传。把首次 PUT 已被服务端接受但客户端收不到回执的用例加入队列测试：下次重试沿用同一个 upload ID，`MOMENT_MEDIA_COMPLETED` 视为已写入，再 complete，`/moments` 只调用一次。

```dart
expect(momentMediaPutTimeout(512 * 1024), const Duration(seconds: 30));
expect(momentMediaPutTimeout(20 * 1024 * 1024), const Duration(seconds: 335));
expect(momentMediaPutTimeout(40 * 1024 * 1024), const Duration(seconds: 360));
```

- [ ] **Step 2: 运行红灯。** 命令：

```powershell
& 'C:/src/flutter/bin/flutter.bat' test test/core/business_api_media_put_test.dart test/features/moments/moment_publish_coordinator_test.dart
```

预期：纯函数尚不存在、9 秒媒体 PUT 超时；不能把任意其他失败记作目标红灯。

- [ ] **Step 3: 最小实现。** 在 `business_api_client.dart` 添加纯函数及专用参数；`_authorized` 的默认调用仍使用 8/20 秒。`putMomentTask` 仅给媒体 PUT 传两个预算，不对 `/moments` 发布、begin、complete 增时：

```dart
Duration momentMediaPutTimeout(int byteCount) {
  final seconds = ((byteCount + 65535) ~/ 65536) + 15;
  return Duration(seconds: seconds.clamp(30, 360));
}

final mediaTimeout = momentMediaPutTimeout(bytes.length);
final response = await _authorized(
  (headers) => _client.put(
    _uri('/moments/media/uploads/$uploadId/content'),
    headers: {...headers, 'Content-Type': mimeType}, body: bytes),
  timeout: mediaTimeout,
  totalTimeout: mediaTimeout * 2 + const Duration(seconds: 20),
  expectedMomentSession: session,
);

// In the existing _authorized named parameters:
Duration totalTimeout = _authorizedTotalTimeout,
// Replace the existing deadline initializer:
final deadline = DateTime.now().add(totalTimeout);
```

上面 `_authorized` 片段表示仅替换签名与 `deadline` 初始化；原函数其余主体原样保留，不能用片段覆盖既有鉴权与诊断逻辑。上传超时不主动创建新 upload ID；`MomentPublishCoordinator._uploadAttempt` 已持久化 ID，重试按现有 `MOMENT_MEDIA_COMPLETED` 与 complete 状态校验推进。只有 `MEDIA_UPLOAD_EXPIRED`/`MOMENT_MEDIA_EXPIRED` 才换 generation。

- [ ] **Step 4: 运行绿灯及边界回归。** 运行 Task 2 两个测试文件；预期新增用例及旧的授权刷新、会话代次用例通过。用 20 MiB 的限速本地 PUT 替身测到客户端预算上限，反向代理与运行服务的请求读取上限须在生产候选阶段另核对，不能凭 `MockClient` 宣称端到端成功。

- [ ] **Step 5: 提交独立变更。** 只暂存本任务文件，提交 `fix: bound Moments media PUT separately from business requests`，记录 commit SHA 和红绿命令。

## Task 3: 首帧封面、失败保留及任务阶段

**Files:**
- Modify: `apps/mobile_flutter/lib/features/moments/moment_publish_coordinator.dart:23-52,278-418,450-605`
- Modify: `apps/mobile_flutter/lib/features/moments/moment_composer_page.dart:789-827`（只核对同源预览传递，不改导航语义）
- Test: `apps/mobile_flutter/test/features/moments/moment_publish_coordinator_test.dart`
- Create: `apps/mobile_flutter/test/features/moments/moment_poster_policy_test.dart`
- Test: `apps/mobile_flutter/test/ui/moment_video_poster_delivery_test.dart`

- [ ] **Step 1: 先写抽帧与封面门禁红灯。** 用可注入的抽帧函数返回不同时间点测试首选 0ms、随后 200/500/1000/2000ms；输入 700 KiB 但可解码并压缩到 512 KiB 以下时得到 JPEG；超过安全像素上限或所有帧无效时返回失败。测试已有相册预览只作为同一个 `MomentPublishMedia` 随源文件进入队列的回退来源，不能把另一文件的预览绑定到该视频。测试封面 begin/PUT/complete 任一非 404 失败时 `/moments` 不调用、任务与视频上传结果保留、重试复用结果，成功时 `video_poster_media_ids` 与 `video_urls` 一一对应。

```dart
expect(await prepareMomentVideoPoster(video,
    extract: (_, positions) async {
      expect(positions, [0, 200, 500, 1000, 2000]);
      return firstFrameBytes;
    }), isNotNull);
expect(job.state, MomentPublishState.failed);
expect(publishCalls, 0);
expect(job.media.single['result'], isNotNull);
```

- [ ] **Step 2: 运行红灯。** 命令：

```powershell
& 'C:/src/flutter/bin/flutter.bat' test test/features/moments/moment_poster_policy_test.dart test/features/moments/moment_publish_coordinator_test.dart test/ui/moment_video_poster_delivery_test.dart
```

预期：0ms 首帧/大输入压缩/封面必需测试失败，现有视频/历史无封面回归保持现状。

- [ ] **Step 3: 实施最小封面策略。** `prepareMomentVideoPoster` 先从已转码 MP4 抽帧；只有抽帧全失败时才使用该任务随源文件复制的选择器预览。先解码尺寸并拒绝 `width * height > 16 * 1024 * 1024`，再缩到最长边 480，以 JPEG 压缩并检查输出 512 KiB；绝不在解码前凭输入大于 512 KiB 拒绝。

```dart
typedef MomentPosterExtractor = Future<Uint8List?> Function(
    File file, List<int> positionsMs);

Future<Uint8List?> prepareMomentVideoPoster(File video,
    {Uint8List? source, MomentPosterExtractor? extract}) async {
  Uint8List? frame;
  try {
    frame = await (extract == null
        ? extractVideoPoster(video.path,
            positionsMs: const [0, 200, 500, 1000, 2000])
        : extract(video, const [0, 200, 500, 1000, 2000]));
  } catch (_) {
    // The selected asset's own preview remains eligible below.
  }
  final bytes = frame?.isNotEmpty == true ? frame! : source;
  if (bytes == null || bytes.isEmpty) return null;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        if (descriptor.width * descriptor.height > 16 * 1024 * 1024) {
          return null;
        }
        final target = targetDimensions(descriptor.width, descriptor.height, 480);
        final jpeg = await FlutterImageCompress.compressWithList(bytes,
            minWidth: target.width, minHeight: target.height,
            quality: 80, format: CompressFormat.jpeg);
        return jpeg.isNotEmpty && jpeg.length <= 512 * 1024 ? jpeg : null;
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  } catch (_) {
    return null;
  }
}
```

实现时保留对平台解码异常的有限捕获并返回封面失败类别，不记录原始异常或字节；无效像素尺寸、解码失败、压缩超限分别记固定枚举。现有 `enqueue` 的 512 KiB 预览源限制只约束暂存空间，不能阻止已转码视频自身抽帧。

- [ ] **Step 4: 阻止无封面新动态。** `_prepare` 没有小封面时抛固定的 `MomentImageException('视频封面生成失败，内容已保留，请重试')`，不要吞错并发布 `null`。`_work` 在视频完成后必须完成该视频封面、确认 `id`，才构造发布 body；封面路由 404 与 5xx 均保留任务并提示“视频封面暂不可用，请稍后重试”，不能降级为无封面发布。已经存在的历史无封面动态仍由 `MomentMediaCache.resolveVideoPoster` 使用本地已缓存视频或中性占位；禁止为封面下载整段视频。

```dart
final poster = File('${root.path}/${job.id}/media-$i.poster');
if (!await poster.exists()) {
  throw const MomentImageException('视频封面生成失败，内容已保留，请重试');
}
final posterResult = await _upload(
    job, media, poster, 'poster-$i', 'image/jpeg', true);
final posterId = posterResult['id'];
if (posterId is! String || posterId.isEmpty) {
  throw const MomentImageException('视频封面暂不可用，请稍后重试');
}
posterIds.add(posterId);
```

注意 `_prepare` 当前先转码再删除任务内原始副本。封面失败前仍须保留该任务的源视频或已转码可重试文件；只在封面成功写盘并持久化 `prepared=true` 后才删除任务副本。重试已完成视频只 complete/续签，不重新 PUT 或多次发布。

- [ ] **Step 5: 运行绿灯并提交。** 运行 Task 3 三个文件及 `moment_background_publish_test.dart`、`moment_video_test.dart`；预期新旧用例通过。提交 `fix: require a verified first-frame poster for new Moments video`。

## Task 4: 有界阶段诊断与接收端契约

**Files:**
- Modify: `apps/mobile_flutter/lib/core/chat_diagnostics.dart:13-60`
- Modify: `apps/mobile_flutter/lib/features/moments/moment_publish_coordinator.dart:278-418`
- Modify: `services/business-api/app/api/client_diagnostics.py:24-48`
- Test: `apps/mobile_flutter/test/core/chat_diagnostics_test.dart`
- Test: `apps/mobile_flutter/test/features/moments/moment_publish_coordinator_test.dart`
- Test: `tests/business_api/test_client_diagnostics.py`

- [ ] **Step 1: 写两侧封闭枚举红灯。** 客户端失败事件仅包含 `moment_prepare`、`moment_video_put`、`moment_video_complete`、`moment_poster_extract`、`moment_poster_put`、`moment_poster_complete`、`moment_publish` 阶段，以及 `timeout/network/rejected/size/format/unknown` 原因、HTTP 状态、耗时和 existing performance `size_bucket`。现有批次顶层 `version` 即 App build，不另传设备/文件名。服务端对这几个固定字符串接受，对额外 `file_name`、URL、异常正文、任意阶段拒绝 422。客户端账号切换后旧任务不得上报。正式客户端须在接收端候选发布后才启用新阶段；旧接收端 422 要仅停用本扩展并保留旧诊断批次，不能无界重试。

```python
def test_moment_stage_is_closed_and_private(endpoint):
    client, _, headers = endpoint
    data = payload()
    data['events'][0].update(stage='moment_poster_put', error='timeout', status=504)
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 202
    data['events'][0]['file_name'] = 'a.mp4'
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 422
    del data['events'][0]['file_name']
    data['events'][0]['stage'] = 'anything'
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 422
```

复用同文件现有 `endpoint` fixture 与 `payload()`，不创建真实用户数据。

- [ ] **Step 2: 运行红灯。** 命令：

```powershell
& 'C:/src/flutter/bin/flutter.bat' test test/core/chat_diagnostics_test.dart test/features/moments/moment_publish_coordinator_test.dart
python -m pytest tests/business_api/test_client_diagnostics.py -q
```

预期：新阶段/原因当前不在双方枚举；记录实际失败行。后端从仓库根目录运行并按仓库测试配置设置 `PYTHONPATH`，不要导入生产 `.env`。

- [ ] **Step 3: 实施封闭的客户端与服务端枚举。** 在 `ChatDiagnosticStage` 加 7 个值及 `wireName` 映射；`ChatDiagnosticError` 加 `size`、`format`。业务 API 的 `DiagnosticEvent.stage` 与 `.error` 只加相同字符串；保留 `extra='forbid'`、长度、速率、用户鉴权及日志脱敏。队列在每阶段入口启动 `Stopwatch`，成功只更新既有 `PerformanceTrace` 阶段；失败通过单一 `recordMomentFailure(stage, error, elapsed, status, sizeBucket)` 映射到固定枚举。大小分桶只经现有 `PerformanceTrace.setMedia(size: ...)`，不把原始字节数或自由文本塞进事件。

```dart
void recordMomentFailure(ChatDiagnosticStage stage,
    ChatDiagnosticError reason, Duration elapsed, {int? status}) {
  ChatDiagnostics.instance.record(
      stage: stage, error: reason, elapsed: elapsed, status: status);
}
```

`TimeoutException`、`SocketException`、`BusinessApiException.statusCode`、`GroupVideoTooLargeException`、`VideoCompressionException` 逐一映射；不读取 `error.toString()` 用于遥测。`MomentPublishJob.message` 按固定阶段文案展示，失败继续落盘并允许原任务重试。接收端与客户端各加一条旧批次兼容测试，确认没有新枚举的既有诊断 JSON 字节形状未变。

- [ ] **Step 4: 运行绿灯并做隐私审查。** 运行 Task 4 三个定向文件、`test/core/chat_diagnostics_spool_test.dart` 及 `tests/business_api/test_network_request_diagnostics.py`；预期均通过。检查测试抓到的 HTTP JSON 与 server stdout 只有固定枚举/状态/耗时/桶/build，没有文件名、路径、令牌或媒体 URL。提交 `feat: classify bounded Moments publication failures`。

## Task 5: 头像稳定版本的服务端契约与源基线

**Files:**
- Modify: `services/business-api/app/integrations/private_storage.py:55-70` 及当前运行镜像中同一签名职责的 S3 实现
- Test: `tests/business_api/identity/test_profile_api.py`
- Test: `tests/business_api/moments/test_moments_api.py`
- Evidence: `docs/verification/artifacts/2026-09-29/android-2191-media-preview/server-baseline.md`

- [ ] **Step 1: 比对运行镜像与仓库源。** 从实际运行镜像只读提取 `app/api/moments.py`、`app/modules/moments/service.py`、`app/modules/moments/media.py`、`app/modules/identity/profile.py`、`app/integrations/private_storage.py` 及所需 S3 配置到本次验证目录，逐文件 SHA/diff；核对 0091 路由、feed `video_poster_urls`/`video_poster_cache_keys`、S3 主写与本地只读回退。当前仓库 `services/business-api/app/api/moments.py` 尚无线上 0091 路由；不能从仓库源直接整体构建覆盖线上。若还发现其他生产差异，先按生产工作流把当前镜像完整源基线归档/审查并合入候选，再做头像补丁；任何未知差异阻止服务候选，不阻止客户端任务。

- [ ] **Step 2: 写头像合同红灯。** 对同一 `avatars/` 对象键连续调用两次签名，应有不同令牌路径但同一 32 位十六进制 `v`；更换键后 `v` 变化；自己资料、好友公开资料和朋友圈作者头像投影自动一致。`moments/` 媒体/封面与非头像对象仍没有新 `v`；`v` 不含对象键，头像内容路由原签名/当前引用验证仍有效。已有未带 `v` 的 URL 与旧客户端仍可读取。私人 S3 主写/本地回退测试必须在运行基线候选上保留。

```python
first = storage.signed_read_url('avatars/u/one.jpg', 300)
second = storage.signed_read_url('avatars/u/one.jpg', 300)
assert urlsplit(first).path != urlsplit(second).path
assert parse_qs(urlsplit(first).query)['v'] == parse_qs(urlsplit(second).query)['v']
assert parse_qs(urlsplit(first).query)['v'] != parse_qs(
    urlsplit(storage.signed_read_url('avatars/u/two.jpg', 300)).query)['v']
assert 'v' not in parse_qs(urlsplit(
    storage.signed_read_url('moments/u/poster.jpg', 300)).query)
```

- [ ] **Step 3: 运行红灯。** 命令：

```powershell
python -m pytest tests/business_api/identity/test_profile_api.py tests/business_api/moments/test_moments_api.py -q
```

预期：头像签名 URL 无 `v`。运行时导入必须指向已对齐的候选源树；如果仍指向落后的共享源，该测试不能作为 0091/S3 保留证据。

- [ ] **Step 4: 在签名 URL 的共同出口按对象前缀添加版本。** `signed_read_url` 先签发原 token，仅当 `object_key.startswith('avatars/')` 时加 `v`。当前运行镜像的 S3 主写/本地回退实现若另有同职责函数，也应用同一条件；如果它生成需要查询串参与验签的直连 S3 URL，须在签名前纳入 `v` 或统一用已有业务 API 头像读取 URL，不能事后破坏 AWS 签名。头像读取路由忽略 `v`、照常验证 token 与当前头像引用；朋友圈媒体/封面签名结果逐字保持原语义。

```python
def signed_read_url(self, object_key: str, expires_in: int) -> str:
    token = self.sign_key(object_key)
    query = f'expires_in={expires_in}'
    if object_key.startswith('avatars/'):
        query += f'&v={sha256(object_key.encode("utf-8")).hexdigest()[:32]}'
    return (
        f'{self._public_base_url}/api/v1/profile/avatar/content/'
        f'{quote(token, safe="")}?{query}'
    )
```

上段仅替换现有 `LocalPrivateObjectStorage.signed_read_url` 的函数体；文件已有 `sha256` 和 `quote` 导入。核对搜索/好友/朋友圈作者头像都经此出口；S3 实现按当前运行源码的实际函数逐文件叠加相同条件。`read_avatar` 对额外查询 `v` 不参与授权；仍验证原 token 与对象当前引用。

- [ ] **Step 5: 运行绿灯与候选差异门禁。** 运行 Task 5 两个测试文件、头像内容鉴权/缓存头测试、0091 视频封面测试以及 S3 双读测试。导出 OpenAPI，并把候选与**当前运行镜像**比较：除预期诊断枚举与头像 URL 值外，路由、响应字段、0091、S3 配置和鉴权不变。无迁移。完成域审查与质量/安全审查后冻结镜像 digest；服务端发布还需按 `app-release-deployment.md` 第 6 条单独取得该候选授权。提交 `fix: version avatar URLs by private object identity`，不要先切生产。

## Task 6: 客户端头像命中与失效

**Files:**
- Modify: `apps/mobile_flutter/lib/ui/foundation/avatar_cache.dart:38-69`
- Modify: `apps/mobile_flutter/lib/features/matrix/profile_repository.dart:862-879`
- Test: `apps/mobile_flutter/test/ui/wechat_components_test.dart`
- Test: `apps/mobile_flutter/test/features/matrix/profile_repository_test.dart`
- Test: `apps/mobile_flutter/test/features/matrix/avatar_cold_start_test.dart`

- [ ] **Step 1: 写重签/换图/换账号红灯。** 两条 `/profile/avatar/content/<不同随机令牌>?expires_in=300&v=同值` URL 对同一身份生成同一缓存键；一次冷重启重新建立 provider 仍命中磁盘而不请求网络。安静刷新仅换令牌不调用 `AvatarCache.invalidateUser`；`v` 变化与删除头像必须逐出旧条目。切换账号后旧 `lastSuccessful` 与签名 URL 不能显示在新账号；保留 `mxc` 头像既有键语义。

```dart
final first = AvatarCache.cacheKey(
    userId: 'account-a:user-1',
    avatarUrl: 'https://api.test/profile/avatar/content/token-a?expires_in=300&v=abcdef0123456789abcdef0123456789');
final renewed = AvatarCache.cacheKey(
    userId: 'account-a:user-1',
    avatarUrl: 'https://api.test/profile/avatar/content/token-b?expires_in=300&v=abcdef0123456789abcdef0123456789');
expect(renewed, first);
```

- [ ] **Step 2: 运行红灯。** 命令：

```powershell
& 'C:/src/flutter/bin/flutter.bat' test test/ui/wechat_components_test.dart test/features/matrix/profile_repository_test.dart test/features/matrix/avatar_cold_start_test.dart
```

预期：缓存键纯函数已支持 `v`，但联系人刷新仍因 `before.avatarUrl != contact.avatarUrl` 逐出；冷启动网络次数或账号隔离测试失败，不能把纯函数已绿误称全部修复。

- [ ] **Step 3: 按版本失效。** `AvatarCache.avatarVersion` 继续优先使用 `v/version`，没有参数的老服务 URL 仍按原规范化 URL 计算，避免新客户端对无版本的真正换图错误复用。`ProfileRepository` 把原始 URL 判等替换为版本和 `avatarIsKnown` 判等；新签名 URL 始终写入联系人快照供 cache miss 下载。现有账号会话退出时清除旧 `lastSuccessful` 与对应账户缓存身份，不能只改 `UserAvatar.avatarCacheKey` 外壳。

```dart
bool _avatarIdentityChanged(ContactSummary? before, ContactSummary after) {
  if (before == null || before.avatarIsKnown != after.avatarIsKnown) return true;
  final oldUrl = before.avatarUrl;
  final newUrl = after.avatarUrl;
  if (oldUrl == null || newUrl == null) return oldUrl != newUrl;
  return AvatarCache.avatarVersion(oldUrl) != AvatarCache.avatarVersion(newUrl);
}
```

在 `_invalidateChangedContactAvatars` 中以该函数替代 URL 直接比较；`AvatarCache.cacheKey` 的 `userId` 必须是当前账号范围内的身份，而非仅昵称或会变化的签名 URL。为账号切换处补清理调用，不在全局共享头像 provider 中保留新账号不可访问的旧签名 URL。

- [ ] **Step 4: 运行绿灯并提交。** 跑 Task 6 三个文件、`test/ui/user_avatar_identity_test.dart` 与 `test/features/matrix/shared_identity_repository_test.dart`；预期同版本重签零逐出、真实换图一次逐出、跨账号零泄漏。提交 `fix: retain avatar bytes across signed URL renewal`。

## Task 7: 会话首帧预热、复用与来源证据

**Files:**
- Modify: `apps/mobile_flutter/lib/features/matrix/room_image_preview_cache.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/video_poster_session_cache.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/video_poster_pipeline.dart`
- Modify: `apps/mobile_flutter/lib/features/matrix/room_page.dart:594-668,2118-2250,3885-4000,4215-4300,4958-4968`
- Modify: `apps/mobile_flutter/lib/ui/chat/wechat_video_message.dart:50-150`
- Test: `apps/mobile_flutter/test/features/matrix/room_image_preview_cache_test.dart`
- Test: `apps/mobile_flutter/test/features/matrix/video_poster_session_cache_test.dart`
- Test: `apps/mobile_flutter/test/features/matrix/video_poster_pipeline_test.dart`
- Test: `apps/mobile_flutter/test/features/matrix/room_page_flash_integration_test.dart`

- [ ] **Step 1: 写断网重进与占位红灯。** 第一次进入显示可见区已验证图片/视频的小预览，退出后断网重进；断言首帧命中当前账号内存或加密磁盘、Matrix 下载计数不增长。冷启动没有解码字节时显示明确图片/视频占位，不出现透明空框。闪照及不可持久化媒体不进入跨房间 LRU；资源压力/登出/账号切换后小预览清空。为 legacy 图片、可信内容 hash 图片、视频 poster 分别计数，避免把异步磁盘命中误报成重复联网。

```dart
expect(reopened.get('event'), previewBytes);
expect(networkLoads, 0);
expect(posterCache.peek(posterKey), posterBytes);
clearMediaMemoryCaches();
expect(posterCache.peek(posterKey), isNull);
```

- [ ] **Step 2: 运行红灯。** 命令：

```powershell
& 'C:/src/flutter/bin/flutter.bat' test test/features/matrix/room_image_preview_cache_test.dart test/features/matrix/video_poster_session_cache_test.dart test/features/matrix/video_poster_pipeline_test.dart test/features/matrix/room_page_flash_integration_test.dart
```

预期：图片既有会话池部分用例已经通过；视频跨房首帧与来源计数失败，不能把已有图片缓存重复实现。

- [ ] **Step 3: 小首帧复用及预热。** 保留 `RoomImagePreviewCache` 现有 32 MiB 完成项池；给 `VideoPosterSessionCache` 增同等语义但更小的 16 MiB 完成项 LRU，键仍为账号+房间+媒体 ID+版本+规格，并提供同步 `peek`。`VideoPosterPipeline` 命中/产出后写入池；`VideoMessageCard` 接收 `initialPosterBytes`，如果同步可得则首帧直接显示。`RoomPage` 获得首个可见窗口后，只对该窗口和现有 `kVideoPosterWarmExtent` 所覆盖的近期项排队 `readCached`/`resolve`；已有 decoded 图片走 `_cachedImagePreview` 即时绘制。预热不调用完整视频下载、不扫描全历史、不绕过 `MediaMessageAccessPolicy`。

```dart
final initialPoster = videoPosterCache.peek(
    videoPosterPipeline.keyFor(message.id));
VideoMessageCard(
  duration: message.duration,
  onOpen: () => unawaited(_openVideoViewer(message)),
  posterIdentity: message.id,
  initialPosterBytes: initialPoster,
  posterLoader: () => _loadVideoPoster(message.id),
);
```

两个 `VideoMessageCard` 调用点都传同一 `initialPosterBytes`，并保留现有 `onOpen`、`posterRevision` 等参数。`peek` 返回已验证且复制/不可修改的小封面字节；销毁单房间的临时 poster 磁盘不能清掉当前账号完成项池。`clearMediaMemoryCaches` 的注册清理器必须同时清掉该池，防止账号串图和内存压力后旧解码数据复活。

- [ ] **Step 4: 加来源计数与视觉回归。** 在 `RoomImagePreviewCache` 区分 `memoryHits`、`diskHits`、`sourceLoads`；在 `VideoPosterPipeline` 复用现有 `memoryHits/diskHits/serverHits/localFrameGenerations/placeholders/downloadBytes`。只有 Matrix 真实请求/SDK 加载回调才计为远端来源；`readCached` 磁盘命中不计网络。现有图片 `ContainImageBubble` 的 `CupertinoIcons.photo` 占位及视频 `videocam_fill` 占位保留，并给页面固定背景/尺寸以避免冷启动纯空白。所有诊断只记录枚举、耗时、桶和计数，不记录事件 ID/房间 ID/内容。

```dart
if (bytes != null) {
  diskHits++;
  return retained;
}
sourceLoads++;
bytes = await source();
```

计数增量应放在各自真实分支，不能因异步并发的第二个调用重复加数。`VideoPosterPipeline.downloadBytes` 仍恒为 0；播放后本地抽帧允许生成并缓存。

- [ ] **Step 5: 运行绿灯与设备对照。** 跑 Task 7 四个文件、`test/features/matrix/chat_image_preview_test.dart`、`test/ui/chat/video_poster_visibility_test.dart` 和媒体缓存清理测试。模拟器用已有媒体的房间断网重复进出，记录首帧 P50/P95、来源计数与网络请求数；再打开未缓存媒体，确认占位后加载。真实 Redmi K80 的同类卡顿及首帧仍需用户设备或脱敏时间线，模拟器通过不能替代。提交 `fix: reuse bounded room media first frames`。

## Task 8: 联合验证、候选与交付

**Files:**
- Update: `docs/workflow/tasks/2026-09-29-android-2191-followup.md`
- Create: `docs/verification/artifacts/2026-09-29/android-2191-media-preview/candidate-report.md`

- [ ] **Step 1: 预检并运行影响范围门禁。** 检查 Flutter/SDK、Python 导入路径、`.env` 是否存在、磁盘、`emulator-5556`、迁移唯一 head、OpenAPI 与候选源 SHA。执行定向测试、`flutter analyze lib test`、适用的 Flutter 全量与 `pwsh -NoProfile -File scripts/verify.ps1`；复用同 SHA 已完成的等价门禁，任何失败写真实退出码和首个有效错误。先规格符合性审查，再质量/安全审查。

```powershell
& 'C:/src/flutter/bin/flutter.bat' analyze lib test
& 'C:/src/flutter/bin/flutter.bat' test --timeout 120s
pwsh -NoProfile -File scripts/verify.ps1
```

- [ ] **Step 2: 服务候选发布门禁。** 若 Task 5 服务补丁需要上线，候选须从**最新**运行镜像逐文件对齐并保留 0091、私有 S3 主写/本地缺失回退、续期协议、诊断接收端、worker/Compose 环境。用隔离 PostgreSQL 16 备份恢复跑相关 API 测试并证明无需迁移、合同不变；冻结候选 digest 与兼容回退镜像/配置。按 `docs/runbooks/app-release-deployment.md` 第 6 条单独申请本次服务候选发布授权；授权前仅保持候选，不部署。获授权后检查路由/鉴权/健康、封面 feed、S3 行为、其他容器未变及服务器超时边界。

- [ ] **Step 3: Android Debug 交付。** 与并行任务集成后冻结同一源码 SHA、版本/build；按 `docs/runbooks/android-apk-rebuild.md` 进行源码构建、常规 DEX/资源/Manifest 重建、zipalign 与既有固定测试签名，核对 ABI/包名/版本/证书与文件 SHA。检查模拟器 online 和原安装状态，用 `adb install -r` 保留数据覆盖，启动并核对已装 build、首次安装时间、零崩溃与媒体回归。用户当前只要求 Debug 模拟器测试，不自动发布正式 Android 更新或 iOS 包。

- [ ] **Step 4: 完成证据与结论。** `candidate-report.md` 必须分开写明代码级已证明故障、慢网 20 MiB PUT、封面首帧/失败重试、头像重签/换图、断网重进、闪照边界、服务运行镜像/源差异、测试命令/退出码/SHA、Debug 包 SHA/签名/模拟器安装、真机尚未复验项目。任何单一实际视频失败的原因仍须依其脱敏阶段码或设备时间线判断，不把本计划的多条候选路径说成该用户当次已确定根因。

## 自检映射

| 规格要求 | 计划任务 |
| --- | --- |
| 后台发送、媒体 PUT 30–360 秒、重试/幂等 | 1–3 |
| 0ms 首帧、≤480px/512 KiB、封面必需、旧动态回退 | 3 |
| 固定阶段/原因、隐私、旧接收端兼容 | 4 |
| 头像对象版本、重签命中、换图/删除、账号隔离 | 5–6 |
| 可见窗口预热、加密磁盘/有界内存、闪照隔离、断网证据 | 7 |
| 0091/S3 源差异、单独服务授权、Debug 模拟器 | 5、8 |
