# 畅聊聊天交互、表情仓库与好友页验证证据

**验证日期：** 2026-08-17

**分支：** `main`

**设计基准：** Figma gallery node `107:3`，对应 `20 Messages & Chat` 与 `40 Contacts & Friend`

## 交付范围

- 聊天输入栏严格使用“语音 → 输入框 → 表情 → 更多/发送”的顺序与真实图标。
- “更多”面板收纳图片、拍摄、语音通话、视频通话、红包和文件。
- Unicode 表情支持最近/全部；自定义图片与 GIF 通过 Matrix 私有 E2EE 仓库跨设备同步。
- 长按消息支持添加到表情（仅图片/GIF）、转发、本机删除、多选、引用、提醒和两分钟内撤回。
- 本机删除不发送 Matrix 删除事件；撤回使用 Matrix Redaction；红包与系统消息不能转发。
- 双击头像发送“拍一拍”，长按头像插入 Matrix mention；自定义拍一拍后缀通过加密配置房间同步。
- 提醒定义通过 Matrix E2EE 同步；应用级 coordinator 持续监听同步并在离线初始化失败后自动重试，各设备创建不含消息正文的本地通知。
- 私有表情及提醒控制房间不会出现在用户会话列表。
- 表情面板固定中文 locale，空态为“暂无最近使用”，并移除第三方默认蓝色操作栏。

## 自动验证

在 `apps/mobile_flutter` 执行：

| 命令 | 结果 |
| --- | --- |
| `dart format --output=none --set-exit-if-changed lib test` | PASS；131 个文件，0 个需修改 |
| `flutter analyze` | PASS；No issues found |
| `flutter test` | PASS；164 tests |
| `flutter build apk --debug` | PASS |

在仓库根目录执行 `pwsh -NoProfile -File scripts/verify.ps1`：PASS。其结果包含仓库策略、部署策略、模板测试、配置渲染、9 个 Matrix Bot 测试、161 个 Business API/Worker 测试（1 skipped）、19 个 Flutter 边界测试、导入冒烟、88 个 Python 文件 AST 解析、迁移、OpenAPI 漂移与 Docker Compose 渲染。

## APK 与模拟器

- APK：`apps/mobile_flutter/build/app/outputs/flutter-apk/app-debug.apk`
- 大小：241,900,279 bytes
- SHA-256：`6AEBBF184A507CB009A7BC51EFFEDF687A53783445D1BEF7D69D8F0F8502D9DC`
- 模拟器 serial：`emulator-5554`
- 模拟器型号：`ASUS_AI2501_A`
- 安装：`adb install --no-streaming -r` 返回 `Success`
- 启动：`com.liuhetong.mobile` 进程存在且 MainActivity 为 resumed activity

## 设备冒烟结果

- 底部导航“消息 / 通讯录 / 发现 / 我”可见；“我”页钱包和设置入口可见。
- 会话可进入，聊天输入栏语音、表情与更多控制可见。
- 表情面板“最近 / 全部 / 我的表情”均可见。
- 中文空态“暂无最近使用”可见；`No Recents` 与 `No MaterialLocalizations` 均未出现。
- 私有表情仓库与提醒控制房间未显示为普通会话。
- 长按文本消息菜单未显示“添加到表情”；其他规定操作可见。

## 已知构建提示

Flutter 构建成功，但当前固定版本的 `emoji_picker_flutter`、`flutter_olm`、`flutter_openssl_crypto` 与 `flutter_webrtc` 仍会输出未来 Built-in Kotlin 迁移提示；本次构建、安装和运行未受影响。
