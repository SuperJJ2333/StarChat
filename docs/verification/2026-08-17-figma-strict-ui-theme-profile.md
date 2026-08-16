# 2026-08-17 Figma 严格映射、主题与 Profile 验证证据

## 范围

- Figma 文件：`zpzwTbnj1hqx80tyRygX78`
- Flutter：消息“更多”、三态主题、Discovery 首页、Profile 首页/资料/设置、底部主导航
- 基准：iPhone 15，393×852，1 CSS px = 1 Figma px

## Figma 读取与写入证据

- 读取 `profile-home-default` `29:2169`、`profile-settings-default` `29:2357`、`discovery-home-default` `29:2726`。
- 发现 Figma 的 Discovery 内容容器高度固定为 114，导致主导航 `29:2765` 处于 `y=158`。
- 将 Discovery 内容容器改为占据剩余高度，写入后 `29:2765` 主导航为 `y=710` / `height=83`。
- Profile 浅色 `29:2169` 与深色 `29:2263` 的导航均复核为 `y=710` / `height=83`。
- Discovery/Profile 导航中的 `●` / `◇` 字符占位已删除，替换为消息气泡、通讯录、指南针和个人语义的 24×24 真实矢量图标；选中态 `#07C160`，未选中 `#888888`。
- `20 Messages & Chat` 新增三个独立 393×852 外观状态 Frame：`messages-theme-system-sheet` (`99:2`)、`messages-theme-light-sheet` (`99:30`)、`messages-theme-dark-sheet` (`99:58`)；每个 Frame 都展开当前选中标记、Modal scrim、安全区和真实矢量 checkmark。

## Red / Green

- Red：`theme_controller_test.dart` 首次运行因 `theme_controller.dart` 不存在而失败。
- Green：ThemeController 4 项测试通过，覆盖缺失/损坏值、三态解析与持久化、保存回滚、外观面板选择。
- Profile Widget 测试覆盖身份卡、五个固定入口、朋友圈跳转和首页不再显示内联编辑/退出按钮。

## 自动化验证

- `flutter analyze`：PASS，0 issue。
- `flutter test`：PASS，102 tests。
- `python -m pytest tests/mobile/test_figma_ui_contract.py -q`：PASS，10 tests。
- `git diff --check`：PASS。
- `pwsh -NoProfile -File scripts/verify.ps1`：PASS；repository/deployment policy、配置渲染、Matrix Bot 9、Business 161（1 skipped）、Flutter boundary 19、迁移、OpenAPI 和 Compose 全部通过。

## Android 构建记录

- 首次 x86_64 debug APK 构建在解析 `shared_preferences_android` 的 AndroidX DataStore 1.1.7 时，访问 `dl.google.com:443` 超时。
- 已加入同坐标 Google Maven 镜像，DataStore 1.1.7 后续已进入 Gradle 本地缓存。
- 根因定位：Gradle 线程堆栈阻塞在 `dl.google.com:443` 的 HTTP HEAD，本机连接长时间处于 `SynSent`；Gradle 缓存的 repository stickiness 仍会使已加入 mirror 的 fallback 配置回访 Google Maven。
- 修复：Android 依赖仓库以同坐标 Google Maven 镜像为权威源，不再回访不可达的源。
- `flutter build apk --debug --target-platform android-x64 --no-pub`：PASS，首次成功构建 106.5s，增量重建 12.2s，产物 `build/app/outputs/flutter-apk/app-debug.apk`。
- ADB：`emulator-5554 device`；`adb install -r -d -t .../app-debug.apk` 返回 `Success`；进程 PID 正常，无 `FATAL EXCEPTION`。
- 手工证据：更多/外观面板可触发；切到深色后 force-stop/relaunch 仍保持深色；Discovery/Profile 主导航在屏幕最底部且是真实图标。
- 截图：`docs/verification/screenshots/2026-08-17-messages-more-appearance.png`、`2026-08-17-theme-picker-system.png`、`2026-08-17-theme-dark-restart.png`、`2026-08-17-profile-dark-bottom-nav-final.png`。

## 边界复核

- 主题值仅保存非敏感的 `system/light/dark`，不读写 Token、Matrix 密钥或恢复密钥。
- Profile 仍通过 `ProfileGateway` 访问业务 API；没有跨模块数据库写入。
- 未修改 Matrix E2EE、账本、资产精度、红包或钱包状态机。
