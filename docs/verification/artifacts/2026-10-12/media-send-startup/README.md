# Android 2214 图片/视频发送：AppHome media binding 最小回归修复

## 恢复入口

- 用户报告：Android 0.4.45+2214 全机型房间图片/视频红叹号；这是用户观测，本子任务没有执行设备验收。
- 授权：用户已授权修复、debug 模拟器验证；root 将只读追踪任务扩展为独立工作树的 AppHome 初始化顺序修复及 composition 测试。
- 计划：现有 IM 可靠性 R8 媒体持久发送计划内的确定性回归；不增加功能，不改变 E2EE、账号、存储或转码策略。
- 工作树：`C:/Users/Administrator/.codex/worktrees/media-send-startup-2214/StarChat`；分支 `codex/media-send-startup-2214`；基线 `0ef24bd1`。
- 所有权：`apps/mobile_flutter/lib/app_home.dart`、`apps/mobile_flutter/test/app_home_media_outbox_startup_test.dart`、本证据目录；无 ADB/服务器/版本变更。
- 状态：代码候选与 focused 验证完成；待 root 独立规格/质量安全审查、最终候选全量门禁、debug 真正发送、保留数据安装。

## 根因与最小改动

AppHome 初始化先 `_bindConnectionStatus()`，继而同步 `_bindNetworkState()` → `_bindOutbox()` → 异步 `_bindMediaOutbox()`。后者在第一个 secure binding await 前捕获 startup generation 0；随后启动 callback 调用 `_startup.open()` 将 generation 加至 1。secure binding 返回后，严格的 current guard 拒绝旧 generation，sender 不会安装。照片公共 prepared-media 入口、视频公共 file 入口因此同样抛出 `MediaOutboxException(owner-unavailable)`，发生于网络上传之前。

仅将 `_startup.open()` 与 `_matrixReady = true` 移至 `_bindConnectionStatus()` 前，让异步绑定捕获已打开 generation。所有 generation、mounted/disposed、binding epoch、Matrix 实例、账号、sendPreparationIdentity 检查原样保留。没有跳过持久 intent、上传预算、加密或转码。

## 验收台账

| ID | 场景 | pinned 结果 | 限制/下一步 |
| --- | --- | --- | --- |
| M1 | 真实 AppHome + SecureSessionStore 安装生产 sender | baseline shared null RED；修复 active + owner GREEN | native/HTTP 为下面声明的 doubles |
| M2 | 图片公共 enqueuePreparedMedia → durable job → send | baseline owner-unavailable RED；修复 m.image GREEN | 不等同真实 server ACK |
| M3 | 相册视频公共 enqueueVideoFile → durable intent + prepare → send | baseline owner-unavailable RED；修复 m.video GREEN | 原生编码结果是 double |
| M4 | secure binding 异步迟到，但仍属当前 generation | baseline sender null RED；修复 active GREEN | 确定性 hold/release |
| M5 | 迟到 binding 在 dispose 后不得安装 | GREEN | stale guard 保留 |
| M6 | 迟到 binding 在账号变化后不得安装 | GREEN | account guard 保留 |
| M7 | 已安装 sender 在换账号后 inactive，public send 拒绝 | baseline sender null RED；修复 E2EE_LIFECYCLE_ACCESS_REVOKED GREEN | 没有发送事件 |
| M8 | 原 7 个 AppHome lifecycle 回归 | 7/7 GREEN | 未修改原测试 |
| M9 | 原 SDK/coordinator 邻接用例 | desktop bootstrap 7/7 GREEN | 真实 SDK 附件加密及 ACK-loss 同 txid 重试；native SQLCipher 尚待设备 gate |

## 最终输入与证据

最终 gate 使用原锁 `a43833c8e7c3d6faa93d21babdc61dfe4b3563c7ac00912006f26daa8e0ecc5d`；显式 `PUB_HOSTED_URL=https://pub.dev` 执行 `flutter pub get --offline --enforce-lockfile` exit 0。另比较 `.dart_tool/package_config.json` 的 216 个 hosted package 与 lock version，0 mismatch。源码、测试、邻接输入、工具/OS 版本和 package_config SHA 见 `pinned-input-identity.json`。

| 命令/证据 | 退出码/结论 |
| --- | --- |
| `pinned-composition-red.log` + receipt | exit 1：原 AppHome 源码 + 最终测试，2 pass / 5 intended fail（含公共图片/视频 owner-unavailable） |
| `pinned-composition-green.log` + receipt | exit 0：7 新 composition/boundary + 7 原 lifecycle = 14 pass |
| `pinned-desktop-neighbors-green.log` + receipt | exit 0：7 原 SDK/coordinator tests，验证 harness 先初始化 desktop SQLite worker |
| `pinned-analyze.log` + receipt | exit 0：AppHome 与新增测试 No issues found |
| `pub-get-pinned.log` + receipt | exit 0：锁强制固定；未提交 pubspec.lock 改动 |

桌面测试使用真实临时文件、真实 SQLite durable store、真实 secure binding 序列化；Matrix Room transport、私有目录 native metadata 和 video codec 为明确 doubles。Windows 没有 `libsqlcipher.dll`；未初始化 desktop worker 的 direct 邻接测试曾全部停在 Win32 126 环境错误。`desktop_media_neighbors_test.dart` 仅为验证 harness，import 未修改的原测试，不能当作原生 SQLCipher 测试。

fixture 的 synthetic business API 返回 404；未完整初始化的通知/通话组件产生 caught LateError、notification wake cancellation 和 home-resource-dispose diagnostics，日志原样保留。这些不是未处理测试失败，也不构成通知、通话或 native disposal 验收。测试不连接真实业务或 Matrix 服务，不含真实账号/令牌/媒体。

早期 `composition-*`/`focused-green*` 与初次 `pub-get.log` 为诊断尝试，不能复用为最终门禁：初次 mirror pub get 有补丁依赖漂移；最终已强制原 pub.dev lock 并重跑 RED/GREEN/邻接/analyze。早期未退出/fixture 挂起的尝试不算通过。只归档本表所列 pinned evidence；合成 fixture 数据库/媒体不纳入 Git。

## 阶段计时与交接

准确本地命令起止采用各 receipt 的 UTC 时间；诊断前段主动工时未知，不推算。最终 lock 固定从 2026-10-12T11:45:38Z 开始；RED/GREEN、邻接/analyze 结束及输入冻结时间见 receipts。并行 analyze 与邻接的墙钟不能相加。

本子任务没有运行全仓 `scripts/verify.ps1`：本地 `.env` 不存在，root 负责最终候选的全量门禁与复用检查，不导入生产配置。没有构建或发布 APK/IPA，不能称线上已修复。下一操作：root 审查并 cherry-pick 候选，固定同一 lock/source 构建 debug，模拟器保留数据覆盖安装，以真实已登录账号房间确认图片与视频 server ACK/重开房间可见，随后执行最终候选共享门禁及平台验证。

回退为撤销这一个初始化顺序 commit；不会变更数据库 schema、账号 binding 或媒体格式。本子任务没有运行中的命令/隧道。
