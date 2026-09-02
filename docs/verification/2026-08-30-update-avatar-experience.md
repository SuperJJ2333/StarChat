# 更新推送 / 更新数据保留 / 头像缓存与展示体验 — 验证证据（2026-08-30）

需求批次：5 项（更新弹窗推送、更新数据完整保留、头像本地缓存、裁剪安全区、自定义头像全局优先无闪烁）。全部为客户端改动，后端无变更。

## 1. 更新弹窗推送（含选择记录）

上一批已交付弹窗本体（立即更新 → 外部浏览器打开下载页；稍后再说 → 关闭）。本批新增**选择记录**：
- `AppUpdateDeferStore`（SharedPreferences）：记录被推迟的版本号与时间（`update-deferred-build` / `update-deferred-at`）。
- 行为语义：同一启动会话内不再重复弹出（内存 + 持久化双记录）；**下次启动仍会再次提醒**（符合"下次启动再次提醒"），持久化记录用于审计与避免会话内频繁打扰。

## 2. 更新后数据完整保留

- **保留机制**：Android/iOS 应用升级由操作系统保留应用私有数据（SharedPreferences、flutter_secure_storage 会话令牌、SQLCipher 聊天库、头像磁盘缓存），前提是签名一致 —— 发布签名由 `key.properties` 保证并在构建脚本中强制校验。
- **新增 `UpdateDataIntegrity`**（`lib/features/update/update_integrity.dart`）：启动时对比 `last-run-build` 与当前构建号；版本变化即运行探针（偏好设置可读、安全会话存储可读）并写入新版本号；失败**只弹一次提醒、绝不清理或重置数据**；首次安装仅记录基线不弹窗。
- 测试 4 项：首装记录基线不出报告、同版本静默、版本变化逐项报告失败、推迟记录读写往返。

## 3. 头像本地缓存

- 磁盘缓存已由 `AvatarCache`（flutter_cache_manager，30 天 TTL、按 用户+版本+尺寸 键、上限 500）承担，头像URL经过脱敏（剥离签名查询参数后取哈希做版本键）。
- 本批补齐**变更闭环**：头像上传成功 → `AvatarCache.invalidateUser`（清磁盘键与 retained 记录）→ 新增 `ProfileController.onAvatarUpdated` 回调 → AppHome 触发 `ChatIdentityCache.refresh()` + 页面重建 → 各界面立即以新签名 URL 重新拉取并淡入展示。红包/转账卡片与领取弹窗的头像均取自同一条 `_avatar(message)` → `MatrixUserAvatar` → `UserAvatar` 管线，天然继承缓存与刷新。

## 4. 裁剪界面全面屏安全区

- 裁剪为原生 `image_cropper` 9.1.0（insets 由插件处理）。为浅色系统栏显式声明 `statusBarLight/navBarLight` + 工具栏主题色（`toolbarColor/toolbarWidgetColor`）与品牌色控制柄，保证"确认/退出"在刘海/灵动岛/手势条设备上可见可点；非全面屏设备布局不变。（9.x 已废弃 `statusBarColor/navigationBarColor`，按新 API 使用。）

## 5. 自定义头像全局优先 + 无闪烁

- `UserAvatar` 首绘行为重写：本地已有同用户头像（retained）→ 无感替换（原行为保留）；**首次加载改为透明占位 + 180ms easeOut 淡入**，只有加载失败才显示首字占位 —— 消除"默认头像闪现后跳变为真实头像"的现象。
- 旧测试"首帧前保持默认占位可见"按新规格反转为"首帧前透明、绝无默认闪现"；既有聊天/联系人/群接龙等全部头像调用点均复用该组件，红包/转账/领取弹窗同享。
- 缓存命中（`wasSynchronouslyLoaded`）时直接绘制、零淡入，重复展示不再有网络请求。

## 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test` | **365 passed**（新增：完整性 4 项 + 推迟记录 1 项；闪现测试按新契约反转） |
| 契约测试（wechat_components / messaging_surfaces） | 随全量通过 |

证据文件：本文件；实现：`app_update.dart`、`update_integrity.dart`、`app_home.dart`、`profile_controller.dart`、`avatar_source.dart`、`user_avatar.dart`。
