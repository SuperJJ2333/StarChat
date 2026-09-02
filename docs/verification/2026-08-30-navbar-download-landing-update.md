# 导航栏报错修复 / www 下载按钮与重设计 / 版本更新弹窗 — 验证证据（2026-08-30）

需求批次：4 项（导航栏 TextStyle 插值错误、产品首页下载按钮、www 前端重设计、版本更新弹窗）。

## 1. 任务 1：导航栏左右图标点击报错（已修复）

**现象**：点击顶部导航栏图标触发页面跳转时出现红底错误 "Failed to interpolate TextStyles with different inherit values."（Flutter `TextStyle.lerp` 断言，`painting/text_style.dart`）。

**根因**：`WeChatTheme.build`（`lib/ui/theme/wechat_theme.dart`）覆盖了 `navTitleTextStyle`（Dart 字面量 → `inherit: true`），但未覆盖 `navActionTextStyle`（框架默认 `_kDefaultActionTextStyle` → `inherit: false`）。Cupertino 导航栏 Hero 过渡执行「下页中间标题 → 上页返回标签」的 `TextStyleTween`（cupertino/nav_bar.dart:3018），两端 `inherit` 不一致且存在双未指定字段（如 letterSpacing）→ 每次推入/弹出页面必抛错。

**修复**：在 `CupertinoTextThemeData` 中补齐 `navActionTextStyle` 字面量（`inherit: true`，socialLink 色），两端一致后插值正常。

**测试**：`test/ui/nav_bar_hero_transition_test.dart`（push + pop 两条路径，先复现红再转绿）。

## 2. 任务 2：产品首页下载按钮（已上线）

- `frontend/src/admin-home.js` `homeView()` 新增下载区块：Android 按钮为 `<a href="/downloads/app-release.apk" download>` 可点击；iOS 按钮为 `disabled` + `aria-disabled="true"` + 灰色禁用样式（`.land-btn-disabled`）+「即将上线」角标，视觉与交互双重禁用。
- APK 分发链路：仓库构建 `app-release.apk`（v0.3.0+3，SHA256 `165DDC37767989476915EFA6279C66643635A9666A94AFBBFDD5A7B77CD45FA0`）→ 上传服务器 `/opt/starchat/frontend/downloads/`（gateway 既有 `./frontend` 挂载直接服务，零 nginx/compose 变更）；`frontend/downloads/` 已加入 `.gitignore`（不提交二进制产物）。
- `frontend/home.html` 增加静态引导内容（品牌 + 下载链接），无 JS/爬虫环境可见，JS 加载后被 `homeView()` 替换。
- `scripts/verify_public_domains.ps1` 同步新行为：www `/` 期望 200 并校验页面含「畅聊 ChatFlow」与下载路径；`HEAD /downloads/app-release.apk` 期望 200；admin `/` 期望 200。

## 3. 任务 3：www 前端重设计（简洁科技感）

- 新增 `frontend/src/styles/landing.css` + 重写 `homeView()`：粘性半透明导航、大留白 Hero（56px 标题、栅格双栏）、六张功能卡片、深色安全横幅、下载卡片、公告与极简页脚。
- 设计语言：全部使用 tokens（新增 `--land-shadow-card/lift`），系统无衬线字体栈（SF Pro/-apple-system/PingFang/Roboto 系），卡片圆角 18px、柔和分层阴影，hover 抬升与 80–220ms 克制过渡，`prefers-reduced-motion` 降级；1023/639px 两级响应式。
- 约束合规：`source-contract` 测试（无 `!important`/内联样式/外链/硬编码色）与 `brand-contract`（畅聊 ChatFlow 用语）全部通过，node --test 26/26。
- 线上视觉验收截图：`docs/verification/artifacts/2026-08-29/landing-hero.png`、`landing-download.png`。

## 4. 任务 4：版本更新弹窗（可忽略 / 强制）

**后端**（业务 API 为版本权威，不涉及 Matrix）：
- `app_settings` 表新增键：`app_latest_version / app_latest_build / app_min_supported_build / app_update_notes / app_apk_url`（`modules/settings/service.py`）。
- 新端点 `GET /api/v1/app-updates/latest`（登录用户，未配置返回 `configured:false`）；管理端点 `GET/PUT /api/v1/admin/app-update-settings`（SYSTEM_ADMIN + Idempotency-Key + 审计，最低支持版本不得高于最新版本）。
- 测试 `tests/business_api/test_app_update_settings.py` 5/5（401/未配置/403/发布与读取/422）。

**客户端**（`apps/mobile_flutter`）：
- 新依赖 `url_launcher: 6.3.1`（显式版本）。
- `lib/features/update/app_update.dart`：`AppUpdateInfo` 解析、`resolvePendingUpdate`（currentBuild < latestBuild 才提示）、`requiresForcedUpdate`（currentBuild < minSupportedBuild 为强制）。
- `lib/features/update/app_update_dialog.dart`：可忽略更新 =「更新」+「稍后再说」；强制更新 = 仅「立即更新」、`barrierDismissible:false`、`PopScope(canPop:false)` 拦截系统返回；AppHome 接线层对强制场景加"弹窗被关闭即重新弹出"循环，直到更新完成。
- 登录后静默检查（失败不打扰会话）；「稍后再说」会话内不再重复提示。
- 版本标识 `AppConfig.appVersionName/appBuildNumber` 与 `pubspec.yaml` 对齐，由新增契约测试 `tests/mobile/test_app_build_contract.py` 双向锁定（并断言双场景弹窗实现存在）。
- 测试：`test/features/update/app_update_test.dart` 5 项 + `app_update_dialog_test.dart` 3 项（强制弹窗经 `maybePop` 系统返回路径验证不可关闭）。

## 5. 测试与验证汇总

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test` | **357 passed**（含新增：导航栏 2 + 更新功能 8） |
| `node --test frontend/tests/*.mjs` | 26 passed / 0 failed |
| `pytest tests/business_api/test_app_update_settings.py` | 5 passed |
| `pytest tests/mobile`（含新构建契约） | 23 passed |
| `verify.ps1` 全量 | **PASS**（OpenAPI 已重导出，契约一致） |
| `verify_public_domains.ps1`（线上三域名） | **PASS**（落地页 200 + 内容、APK HEAD 200、admin 200） |
| Release APK 模拟器验证 | emulator-5554 安装成功（v0.3.0 build 3），启动正常无报错横幅（`emulator-5554-release-launch.png`） |

## 6. 部署记录（2026-08-29T17:29Z）

- 服务器备份：`/opt/starchat/backups/20260829T172959Z/`（admin.py、main.py、settings/service.py、admin-home.js、tokens.css）。
- 同步文件：后端 4 个（app_update.py 新增、admin.py、main.py、settings/service.py）+ 前端 5 个（home.html、admin-home.js、landing.css、tokens.css、downloads/app-release.apk）。
- business-api 镜像重建并重启；探针：`/health/live` ok、`/app-updates/latest` 未登录 401、www 落地页 200、APK 200。
- nginx 无需变更（www 落地页配置已于当日早些时候渲染上线）。

## 7. 追加修复：安装包体积与命名（2026-08-30）

**体积问题（132MB → 50.8MB，-62%）**：原发布包是三 ABI 合一的 fat APK（arm64 46MB + armeabi-v7a 37MB + x86_64 模拟器 50MB），每个架构各含一份 Dart AOT 业务代码（~14MB）、Flutter 引擎（~11MB）、WebRTC 原生库（~11MB，来自加密通话依赖 `flutter_webrtc: 0.12.11`）、SQLCipher（~5MB）与 OpenSSL（~2.5MB）。构建脚本改为 Release `--split-per-abi`，公开分发只发 arm64-v8a 单架构包；v7a/x86_64 拆分包保留在构建输出备用。

**命名问题（自动递增）**：`build_mobile_public_domain.ps1` 现在解析 `pubspec.yaml` 的 `version: X.Y.Z+build`，自动产出 `ChatFlow-<版本号>.apk`（当前 `ChatFlow-0.3.0.apk`，SHA256 `F2AD1883FF37E14C3AABEF1CC0F8DACAE70828BCA43C3507268871E623664131`，50,790,407 字节）。发布流程只需递增 pubspec 版本号，文件名与落地页版本注记随之滚动（落地页由 `releaseVersion` 常量驱动链接与文案）；`-Install` 模拟器验收按设备 ABI 自动选择对应拆分包。

**部署**：服务器已替换为 `ChatFlow-0.3.0.apk`（哈希一致）并下线旧 `app-release.apk`；`verify_public_domains.ps1` 从 pubspec 推导版本化 URL 校验（落地页内容 + HEAD 200 均 PASS）；线上落地页按钮已确认指向 `/downloads/ChatFlow-0.3.0.apk`。

## 8. 追加修复②：文件名带 ABI 后缀 + 架构选择键（2026-08-30）

- **保存名修复**：上一版落地页 `download` 属性仍写死 "app-release.apk"，浏览器保存时强制覆盖了服务端文件名 —— 已移除该写死值，`download` 属性置空（保存名取服务端文件名）。
- **命名规则**：发布产物改为 `ChatFlow-<版本号>-<ABI>.apk`：`ChatFlow-0.3.0-arm64.apk`（默认推荐，50,790,407 字节，SHA256 `F2AD1883…`）、`ChatFlow-0.3.0-arm32.apk`（42,049,651 字节，`D0E05BF0…`）、`ChatFlow-0.3.0-x86_64.apk`（54,740,345 字节，`9082A605…`）；构建脚本按此三件套发布。
- **架构选择键**：下载按钮右侧新增 `<select>`（arm64 推荐 / arm32 旧机型 / x86_64 模拟器），切换时同步更新按钮 `href` 与文件路径提示；移动端纵向堆叠。截图：`artifacts/2026-08-29/landing-abi-selector.png`。
- **服务器**：三个包均已上传（哈希与本地一致），旧 `ChatFlow-0.3.0.apk` 已改名下线；`verify_public_domains.ps1` 检查 arm64 主链接及 arm32/x86_64 变体 HEAD 200 —— 线上 PASS。
- 契约测试 26/26（箭头图标改 base64 内联以符合"禁外链"约束）。

## 9. 遗留事项（非阻塞）

- 版本发布流程：管理员经 `PUT /api/v1/admin/app-update-settings` 发布新版本后，旧客户端将在下次启动收到更新弹窗（当前线上未配置 → 客户端静默跳过，行为正确）。
- iOS 上架后：将下载区 iOS 按钮替换为 App Store 链接并解除禁用即可（前端单点修改）。
