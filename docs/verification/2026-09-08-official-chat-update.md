# 0.3.52 / build 54 正式客户端发布

## 范围与来源

用户授权发布正式 APK 和应用更新弹窗，要求保留正式签名。本次不部署后端、迁移或开发中的钱包功能。

隔离分支 `codex/official-chat-update`，打包源码提交 `86fa1aa`。从 `4afbc6c` 恢复 0.3.51 的已发布移动端基线，再合入 `48915cb`、`8c22c23`、`1895a34`、`e454bf5` 对应聊天修复。已发布钱包的两个源码文件逐字节匹配 0.3.51 来源清单；恢复基线的 270 个文件中，267 个内容匹配（允许 LF/CRLF），三个聊天集成文件有差异并在本版合入新修复，不宣称整个历史快照完全一致。

包含发送消息排序、深色模式、Android 单任务入口、按账号/房间隔离的文字草稿，以及未解密会话摘要留空。保留相册、好友和既有钱包功能。构建后再次检查 494 个来源文件哈希未变。

## 本地校验

- 隔离源码 Flutter 全量 1299/1299，通过；analyze 零问题。
- 首轮缓存测试 2 项因 Windows 嵌套长路径失败。将同一工作树映射至 R: 后，未修改源码，全量通过。R: 指向本报告同名 artifacts 目录下的 source。
- 仓库全流程首次因隔离环境缺 .env 中断；使用 .env.example 仅在隔离目录渲染后继续。后端 349 通过 / 19 跳过；移动端边界发现 AppConfig 旧版本回退常量，修为 0.3.52/54 后 66/66 通过，19 项版本/更新 Flutter 回归通过。其后 UI 契约、API import、AST、迁移离线、OpenAPI、Compose 检查逐项通过。原脚本没有整条重跑，已通过且未改动的后端测试未重复。第三方弃用提示保留在日志，不属于本版变更。
- standard / release / android-arm64，版本 0.3.52+54。三个 API/homeserver/getui define 均为 https://liuhetong888.com。
- Apktool 2.12.1 完整解码和重建，Android build-tools 36.0.0 对齐及签名。
- 24573 个 smali 类、331 个原生库/资产项和 Manifest 语义前后一致。DEX、resources.arsc 已实际重建。新版本 Dart AOT 哈希与旧版本不同。
- 正式证书 SHA256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，与已发布 0.3.51 APK 相同。无 debuggable，仅 arm64-v8a，versionCode=54 > 53。
- 最终 APK：75,994,052 字节；SHA256 `b133068bc842648d21883335c1537933923a3d597b063dbc0eaa83dfcbd7597d`。

Mi 6 当前 debug 安装使用另一证书及 build 2054。本次不卸载、不覆盖该安装，不声称已完成此次正式包的真机覆盖安装测试。

## 发布记录

已于 2026-09-08 01:31:12（UTC+8）发布，状态 PUBLISH_PASS。五项设置独立回读一致：0.3.52 / 54 / min 3 / 新版文案 / 新版 URL；产生 5 条 settings.update 审计。服务器 APK、服务器经公网完整下载、本机经公网分段完整回下载及 latest 下载哈希均一致。未发布的初始候选包已移出公共下载目录并保存在发布归档。不可变下载名 `ChatFlow-0.3.52-build54-arm64.apk`；原版 APK 和五项设置备份保留。五项设置通过现有 SettingService 事务写入并审计，latest 链接原子切换；链接校验失败时回退设置与链接。

原始证据保存在 `docs/verification/artifacts/2026-09-08/official-chat-update/`（主工作区）：来源清单、测试日志、重建记录、证书、包校验、上传和发布记录。该目录不提交 APK、密钥或运行环境文件。
