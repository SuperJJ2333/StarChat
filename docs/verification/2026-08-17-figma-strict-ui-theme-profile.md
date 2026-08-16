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

## Red / Green

- Red：`theme_controller_test.dart` 首次运行因 `theme_controller.dart` 不存在而失败。
- Green：ThemeController 4 项测试通过，覆盖缺失/损坏值、三态解析与持久化、保存回滚、外观面板选择。
- Profile Widget 测试覆盖身份卡、五个固定入口、朋友圈跳转和首页不再显示内联编辑/退出按钮。

## 自动化验证

- `flutter analyze`：PASS，0 issue。
- `flutter test`：PASS，102 tests。
- `python -m pytest tests/mobile/test_figma_ui_contract.py -q`：PASS，10 tests。
- `git diff --check`：PASS。

## Android 构建记录

- 首次 x86_64 debug APK 构建在解析 `shared_preferences_android` 的 AndroidX DataStore 1.1.7 时，访问 `dl.google.com:443` 超时。
- 已加入同坐标 Google Maven 镜像，DataStore 1.1.7 后续已进入 Gradle 本地缓存。
- 工作树全新 Android 产物的冷启动构建多次超过 10 分钟 CLI 时限；待合并至主工作区后使用已有 Android 增量构建目录重试并补充 APK/ADB 证据。

## 边界复核

- 主题值仅保存非敏感的 `system/light/dark`，不读写 Token、Matrix 密钥或恢复密钥。
- Profile 仍通过 `ProfileGateway` 访问业务 API；没有跨模块数据库写入。
- 未修改 Matrix E2EE、账本、资产精度、红包或钱包状态机。
