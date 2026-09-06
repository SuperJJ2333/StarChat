# MI 6 来电名称、通知与视频体验交付

## 范围与授权

按用户要求完成源码修改、debug 构建、MI 6 覆盖安装；沿用本会话“先功能修复和验证，暂不更新 Figma”的明确授权。没有修改 Figma/导出状态，没有伪造设计节点验证。统计助手 HTML 是其他任务改动，本任务未编辑。没有部署服务端。

## 规格审查

- 来电：AppHome 原先可能先创建 CallUiManager，再创建共享显示名解析器，导致管理器长期持有 null。改为提前可用的 late final 同一解析器，备注/昵称优先；缺资料仅显示用户名，不显示完整 Matrix 地址。来电页可等待联系人预热后更新显示名。
- 通知：保留既有 `chatflow_messages_v2`、`calls_ring`、`chatflow_silent`，名称为消息通知、通话提醒、后台服务。聊天、提及、关注和系统消息合并；通话中和同步/静默共用后台服务；删除明确迁移的旧渠道，不修改保留渠道的用户声音选择。首次登录沿用系统权限申请，新增登录主界面可操作提示，系统设置返回复查总通知、消息/来电铃声与 Android 14+ 全屏来电权限。
- 视频：文件入口现在与相册、拍摄共用压缩策略；首轮 480p/24fps，超过 2MB 且减量不足 50% 时降档重试，仍取较小者。压缩取消等待完成后再进行下一轮。不能保证每种编码都达到固定压缩率；文件过大且压缩失败会拒绝发送。默认首帧封面（0ms）；首帧读取失败才回退后续采样。旧消息不会自动补封面或时长。
- 播放：增加可拖动进度条、0.5/1/1.5/2 倍速、与图片共用圆形下载/转发按钮。下载写入系统相册；转发进入共享“选择聊天”页面，图片旧的目标列表弹窗也已替换。RoomPage 复用现有加密消息转发服务。

## 质量/安全审查

附件与缩略图仍由 Matrix 加密上传，未发送到业务 API；没有修改 E2EE、认证或金融模块。转发仍要求加密会话；没有代用户发送消息或发起来电。没有通过 adb 授权权限或清空应用数据。通话布局和控制器既有源码边界检查问题单独记录，不以断言删除掩盖。

## 验证证据

证据目录：`artifacts/2026-09-05/mi6-upgrade/`。

- `red.log`：冷缓存完整 Matrix ID、渠道分散、中等视频不降档三项红灯。
- `tests-final.log`：9 个相关测试文件 38 项通过；随后增加压缩文件内容测试，`compression-final.log` 4 项通过（包含该新增项）。
- `player-final.log`：播放器 seek/倍速实际调用、权限提示往返、视频统一转发共 3 项通过。
- `channel-final.log`：最终三渠道初始化及名称/压缩策略共 8 项通过。
- `analyze.log`：Flutter analyze 无问题。
- `ui-contract.log`：UI contract drift PASS，17 components、330 screens；此检查不代表完成 Figma 更新。
- `verify.log`：业务 API/Worker 311 passed、19 skipped；移动边界 47 passed、4 failed。四项均为上个任务已在未修改基线复现的通话源码字符串检查，详见 `2026-09-05-group-qr-video-fixes.md`。总验证退出 1，不能宣称全绿；插件 KGP 迁移和 Python 弃用警告仍存在。
- `git diff --check` 通过。

## 构建与安装

使用源码标准版 flavor（`--debug --flavor standard --split-per-abi --target-platform android-arm64`），版本名 0.3.36、构建号 39；Gradle ABI 编码后的 versionCode 为 2039。API/Matrix/Getui origin 为 `https://liuhetong888.com`。未加壳、未启用额外混淆或保护。debug 构建不等于 release 性能，最终传输与解码速度由用户在真机测试。

首次误取无 flavor 的历史默认输出，被手机以 VERSION_DOWNGRADE 拒绝，未安装。修正为显式 standard flavor 并通过 aapt 校验版本、debug 标记和仅 arm64 ABI，再覆盖安装成功。最终以 `build-standard.log`、`install-final.log` 为准。

最终 APK：`artifacts/2026-09-05/mi6-upgrade/ChatFlow-0.3.36-arm64-debug.apk`。

SHA256：`10CC8EBBC67B1E9AEBC5795FD9EE885641552DAE46D040E2D62D6D14C6718726`。

签名证书 SHA256：`34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`。

MI 6（cbd0156b，Android API 28）执行 `adb install -r -t` 成功并启动。`device-verification.json` 证实已安装 versionName 0.3.36、versionCode 2039、进程运行，以及三个有效渠道：消息通知、通话提醒、后台服务。未卸载、未清数据。实际双方来电、真实视频压缩比和播放/保存由用户继续验收，未伪称完成两机端到端测试。
