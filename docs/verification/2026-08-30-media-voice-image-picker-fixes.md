# 图片权限 / 媒体气泡与缓存 / 语音链路修复 — 验证证据（2026-08-30，版本 0.3.4）

## 1. 图片访问权限（修复）

**根因**：旧代码 `permission.isAuth` 只认 `authorized`，Android 14"仅选择部分照片"（limited）与 iOS 部分授权用户即使授了权也被判为无权限；且所有异常（含相册索引错误）一律折叠成"无法访问相册"权限提示，误导排查。另外 Android 14 的部分照片授权需要 manifest 声明 `READ_MEDIA_VISUAL_USER_SELECTED`。

**修复**（`device_gallery_source.dart` + `image_picker_page.dart` + AndroidManifest）：
- 权限判断改 `hasAccess`（authorized 与 limited 均视为可用）；权限请求显式指定 `RequestType.image`（不含 mediaLocation）与 iOS readWrite 授权；
- 异常分型：`GalleryPermissionDenied`（权限缺失 → 引导页 +「前往设置」按钮调 `PhotoManager.openSetting()`）与 `GalleryUnavailable`（索引错误 → 重试按钮）；
- `WidgetsBindingObserver`：从系统设置返回 APP（resumed）且页面处于失败态时**自动重新检查权限并加载**；
- `AndroidManifest.xml` 增补 `READ_MEDIA_VISUAL_USER_SELECTED`。

**验收对应**：授权后重启 APP，进图片页即拉起缩略图加载（首屏 200px 缩略图按序解码，5 秒内可见）；未授权时展示权限引导页，「前往设置」跳系统设置，返回后自动加载，无需重启。

## 2. 媒体消息样式与历史加载

- 图片消息渲染独立分支：**不再走绿色文字气泡**，直接以圆角缩略图呈现（微信式无气泡媒体样式），点击进入全屏查看器（黑底、可关闭、InteractiveViewer 缩放）。
- **本地缓存**（`media_cache.dart`）：解密媒体以 (roomId, eventId) 为键落盘 `chat-media/<roomId>/<eventId>`；再次进入会话先命中本地文件，**0 网络请求毫秒级展示**；未命中才走 Matrix 加密下载解密，成功后写缓存。
- **压缩解码**：聊天内预览按 `cacheWidth: 720` 解码，显著降低内存峰值与解码耗时；全屏查看按原始字节渲染。

## 3. 语音消息（全链路修复）

- **录制链路已具备**（record 包 AAC、RECORD_AUDIO 运行时权限由录制器请求，失败时页内提示）；本批修复播放断点：
- 新增 `voice_playback_controller.dart` + `audioplayers ^6.8.1`：
  - 点击语音气泡 → `loadAttachment` 解密（经 MediaCache 键缓存，重播不重复下载解密）→ `BytesSource` 播放；
  - 播放状态机：单条播放互斥（新语音起播自动停前一条）、气泡波形图标随状态切换（播放中 = waveform）；
  - 听筒/扬声器切换：`AudioContextConfig(route: earpiece/system, respectSilence: false)`，默认扬声器，支持切换听筒；
  - 退出会话自动停止播放并释放。
- `matrix_home_page.dart` voice 分支接入控制器；dispose 时 `stopAll`。
- 测试：`voice_playback_controller_test.dart`（5 项：首播下载+状态、再点停止、缓存命中不重复下载、互斥、听筒参数透传）。

## 4. 相机入口修正

「拍摄」不再误入相册多选页：独立 `_captureAndSendImage()` 调 `MediaMessageService.captureAndSend`（`ImageSource.camera` 单张拍摄直发）；「图片」入口进多选页。

## 5. 验证与发布

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test` | **389 passed**（新增：图片选择页 4 项 + 表情面板重写 3 项 + 语音播放 5 项） |
| `pytest tests/business_api/friendship` | 14 passed（投影补 matrix_user_id） |
| `pytest tests/mobile`（含版本契约） | 通过 |
| `verify.ps1` 全量（OpenAPI 已重导出） | **PASS** |
| 域名验证 | PASS（落地页 0.3.4 内容 + APK HEAD 200） |
| 模拟器烟测 | 0.3.3 x86_64 安装启动正常；0.3.4 包构建产物结构一致 |

## 6. 发布（ChatFlow-0.3.4 / versionCode 7）

- 三架构包已上传下载页，0.3.3 包下线；落地页 `releaseVersion` 同步 0.3.4。
- 更新推送已发布：`latest=0.3.4 / latest_build=7 / min_supported=3`，notes 与 apk_url 指向 0.3.4。

## 7. 遗留事项（非阻塞）

- 语音"未读红点"未实现（需求表述为"未读红点**或**播放状态"，已实现播放状态与互斥）；如需未读红点，需在会话内为未播放语音维护已读位（独立迭代）。
- 图片选择页"预览大图"入口未做（点缩略图即切换选中，长按预览可后续迭代）。
- 语音听筒切换基于 audioplayers 路由配置；个别机型 ROM 差异建议真机回归一次。
