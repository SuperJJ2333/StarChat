# ChatFlow Android 媒体选择 BUG 修复报告

**日期**：2026-09-02
**审计对象**：用户提供的 0.3.25 APK（`com.liuhetong.mobile`, targetSdk 36，清单缺 `READ_MEDIA_VIDEO`，AOT 含 `pickMultiImage`）与当前仓库工作树（0.3.26+，已发布）
**结论先行**：0.3.25 的根因是 **①清单缺 `READ_MEDIA_VIDEO`、②聊天"图片"入口走 `pickMultiImage`（仅图片 API）**。两者在当前仓库均已修复并随 **0.3.26** 发布；本次审计进一步清除了全部残留的"仅图片"选择路径。

---

## 1. 全局查找：picker API 使用点（修复后状态）

| API | 位置 | 用途 | 状态 |
| --- | --- | --- | --- |
| `pickMultiImage` | ~~`moment_composer_page.dart`~~ | 朋友圈选图 | **已删除** → 重构为 `pickMultipleMedia()`（需求 9） |
| `pickImage(camera)` | `media_message_service.captureToFile` | 「拍摄」短按拍照 | 保留（相机拍照，无相册权限语义） |
| `pickVideo(camera)` | `media_message_service.captureVideoToFile` | 「拍摄」长按录像 | 保留 |
| `pickImage(gallery)` | ~~`media_message_service.sendImage`~~、`avatar_source`（头像）、`moments_page`（封面） | 死代码 `sendImage` **已删除**；头像/封面单选图片属正当仅图片场景 | 头像/封面保留 |
| `pickMedia` / `pickMultipleMedia` | `moment_composer_page.dart`（新增） | 朋友圈多选（13+ 系统 Photo Picker） | 新增 |

聊天主选择器**不使用** image_picker（见 §2/§3）。

## 2. 全局查找：photo_manager RequestType

`lib/features/matrix/device_gallery_source.dart`：

| 用法 | 位置 | 说明 |
| --- | --- | --- |
| `RequestType.common` | 最近图片相册 + 默认分页器 | **照片+视频混排**（时间倒序） |
| `RequestType.video` | 顶部"本地视频"子相册 | 仅视频 |

**无 `RequestType.image` 用法**——不存在"仅图片"的相册查询路径。

## 3. 聊天"图片"入口最终调用链

```
聊天页「+」面板 → 图片（ChatMoreAction.image）
  → room_page._pickAndSendImages()
  → ImagePickerPage（微信式九宫格）
  → DeviceGallerySource.loadAlbums / DeviceGalleryPager.loadNextPage
  → photo_manager getAssetPathList/getAssetListRange（RequestType.common，照片+视频混排）
  → 勾选发送：图片走压缩图/原图；视频走 480p 压缩（预览与发送复用同一份）
```

满足需求 4：**相册同时显示照片和视频**（视频条目带"分:秒"角标与播放图标）。
0.3.25 的旧行为（`pickMultiImage` 仅返回图片）正是用户"看不到视频"的直接原因之一。

## 4. Android 13+ 权限：READ_MEDIA_VIDEO（需求 5）

- 0.3.25：缺 `READ_MEDIA_VIDEO` → 系统只授予图片读取，photo_manager 无论 `RequestType.common` 与否都看不到视频。
- **0.3.26 起已补齐**（`android/app/src/main/AndroidManifest.xml`）：

```xml
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>
<uses-permission android:name="android.permission.READ_MEDIA_VISUAL_USER_SELECTED"/>
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
```

`aapt dump permissions`（0.3.26 arm64 实测）确认四项全部存在于合并清单。

## 5. 运行时权限处理（需求 6/7）

`DeviceGallerySource._ensurePermission` 统一走：

```dart
PhotoManager.requestPermissionExtend(
  requestOption: PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,   // ← 同时请求 IMAGES + VIDEO
      mediaLocation: false),
    iosAccessLevel: IosAccessLevel.readWrite));
```

- **Android 12-**：请求 `READ_EXTERNAL_STORAGE`（≤32 清单项对应）。
- **Android 13+**：`RequestType.common` 使 photo_manager 同时请求 `READ_MEDIA_IMAGES` 与 `READ_MEDIA_VIDEO`（清单已声明两者，系统权限弹窗含视频项）。
- **Android 14+ 部分授权**：用户点"选择部分照片"时系统授予 `READ_MEDIA_VISUAL_USER_SELECTED` 语义（清单已声明）；`permission.hasAccess == true`，相册仅显示用户勾选的条目——选择器 UI 此前已支持该模式（权限说明文案"允许畅聊访问全部照片（或选择部分照片）"）。
- 拒绝时：选择器展示"未获得相册权限 → 前往设置"页，从系统设置返回自动重查（`didChangeAppLifecycleState`）。

## 6. System Photo Picker 评估（需求 8）

| 方案 | 优点 | 缺点 | 决策 |
| --- | --- | --- | --- |
| **保持 photo_manager 自绘九宫格**（现聊天入口） | 微信式相册 UI、视频角标/时长、照片+视频混排、分页懒加载、压缩预览与发送复用 | 需要媒体运行时权限（清单与运行时均已正确处理） | **聊天入口保留** |
| **Android System Photo Picker**（image_picker 的 `pickMedia/pickMultipleMedia`，13+ 自动走系统组件） | **零媒体权限**；系统级视频/图片混合选择 | 无法定制相册 UI/角标/相册切换，返回临时文件句柄 | 用于**非自绘 UI 场景**：朋友圈发布器已迁移（见 §7）；聊天主入口因交互形态保留自绘 |

## 7. pickMultiImage → pickMultipleMedia 重构（需求 9）

`moment_composer_page.dart._pickImages()`：

```dart
selected = await ImagePicker().pickMultipleMedia();   // 13+ 系统 Photo Picker，12- 自动回退
final imageOnly = selected.where(isSupportedMomentImage).toList();  // 朋友圈仅图片
```

- `isSupportedMomentImage`（顶层纯函数）：按 MIME（`image/*`）过滤，MIME 缺失按扩展名（jpg/jpeg/png/webp/gif）兜底；**mp4/mov/hevc 被过滤并提示"已跳过 N 个视频/文件"**。
- 原 `pickMultiImage(imageQuality: 100)` 的质量参数等价于原图（100），`pickMultipleMedia` 返回原图，无行为退化。
- 顺带清理：删除无引用的死代码 `MediaComposer` 与 `MediaMessageService.sendImage`（单选 `pickImage(gallery)` 的仅图片旧路径，即 AOT 残留来源之一）。

## 8. 按类型分流（需求 10/11）

聊天发送分流按 **photo_manager 的 `AssetType`**（比 MIME 更可靠）：

| AssetType | 处理 |
| --- | --- |
| image | 压缩图（1280px）或原图 → `buildChatImageThumbnail`（≤800px/≤100KB）→ 加密上传 → **图片消息**（附带缩略图） |
| video | 480p 压缩（预览/发送复用）→ 时长（`info.duration`）→ 封面帧（photo_manager 480px 海报）→ 加密上传 → **视频消息**（附带封面） |
| gif | 原样发送（保留逐帧动画，不重编码） |

**flutter_image_compress 隔离（需求 11）**：`buildChatImageThumbnail` 仅在 image 分支与相机拍照路径被调用；视频分支的封面帧来自 photo_manager 的 `thumbnailDataWithSize`（系统解码器），**视频字节永远不会进入 flutter_image_compress**。朋友圈路径同理：视频在候选过滤阶段即被排除。

## 9. 测试矩阵（需求 12）

**自动化（本仓库已覆盖）**：
- `flutter analyze` 0 告警；`flutter test` 全量 **519 passed**。
- 新增 `moment_image_filter_test.dart`：jpg/jpeg/png/webp/gif 接受；mp4/mov/hevc 拒绝；无 MIME 扩展名兜底；无扩展名拒绝。
- 相册既有回归：分页 20/页、照片+视频混排、视频时长角标、GIF 原样发送、20MB 原图拦截、压缩回退提示。

**真机回归清单（需逐机执行，本环境无真机）**：

| Android 版本 | 验证点 |
| --- | --- |
| 12 (API 31/32) | READ_EXTERNAL_STORAGE 授权；相册照片+视频混排；聊天与朋友圈选择 |
| 13 (API 33) | IMAGES+VIDEO 双权限弹窗；仅授图片时视频不可见（预期行为）+ 提示；朋友圈走系统 Photo Picker |
| 14 (API 34) | "选择部分照片"（READ_MEDIA_VISUAL_USER_SELECTED）→ 相册仅显示所选；再次进入可改选 |
| 15 (API 35) | 同 14 + edge-to-edge 下选择器/预览布局 |
| 16 (API 36) | 同 15（targetSdk 36 最新兼容） |

**格式矩阵**（聊天发送 + 朋友圈过滤两项）：

| 格式 | 聊天相册可见 | 聊天发送 | 朋友圈 |
| --- | --- | --- | --- |
| jpg/jpeg/png/webp | ✓ | ✓（压缩/原图 + 缩略图） | ✓ |
| gif | ✓ | ✓ 原样（保动画） | ✓ 静态首帧（发布器按图片处理） |
| mp4 | ✓ 角标时长 | ✓ 480p 压缩+封面 | ✗ 过滤并提示 |
| mov | ✓（依赖系统解码） | ✓ 同 mp4 | ✗ 过滤 |
| hevc (H.265 mp4/HEIF) | ✓（系统解码支持时） | ✓；压缩回退原图路径已验证 | ✗ 过滤（HEIF 图片按 image/heic 属图片类） |

## 10. 修复清单一览

1. `moment_composer_page.dart`：`pickMultiImage` → `pickMultipleMedia` + 图片过滤 + 跳过提示。
2. 删除死代码：`media_composer.dart`（整文件）、`MediaMessageService.sendImage`。
3. 清单 `READ_MEDIA_VIDEO`：0.3.26 已含（本次复核）。
4. 文档：本报告；`docs/runbooks/mobile-release.md`（构建命令已随 flavor 更新）。
