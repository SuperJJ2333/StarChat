# R8 活动媒体字节准入候选

## 恢复入口

- 用户已授权执行可靠性计划 R8；root 委派本有界任务。批准计划位于集成树 `docs/superpowers/plans/2026-10-11-im-reliability-remediation.md`，关联原 client-plan-notes A7/B1/B2 和 ADR-0060。禁止部署、修改加密协议、读取生产凭据或宣称真机 RSS 达标。
- 工作树：`C:/Users/Administrator/.codex/worktrees/im-media-budget/StarChat`；分支 `codex/im-media-budget-current`；最终基线 `1284772e1743b584533333de5d2493477289c754`。最初从 3e0ce735 加 R7b 两提交创建，之后无冲突切到 root 已集成 R6/R7a/R7b/R8a 的 1284772e，保留本任务差异。
- 所有权：新增 media_transfer_budget.dart / 三个专项测试；MMS、content_addressed_media、media_cache、verified_media_content、room_image_preview_cache、prepared_chat_video、native_media_download。root 随后授予 matrix_e2ee_client 的 `_sendMedia` / emoji upload / emoji download 三处接线，未改 mention 扫描。RoomPage/UI 与持久原件/manifest 由 review_r1_r2 独占，本提交不修改。
- 状态：源码候选与本地门禁通过，等待独立 SPEC/domain → QUALITY、RoomPage 专用错误联测及持久任务整合。冻结源码提交由交接消息绑定，输入 SHA256 见 input-hashes.json。没有发布/APK/IPA/真机结论。
- 下一步：root 独立双审；向 review_r1_r2 释放 matrix 所有权，接入专用容量错误展示与持久文件流程。R8 整体仍未完成。

## 契约与可见变化

1. 全局 `sharedMediaTransferBudget` 默认 **201326592 字节（192 MiB）**，构造器注入仅用于明确的设备配置/测试；没有远端放大入口。按完整操作峰值原子准入，FIFO 等待最多 64 个元数据项。
2. 普通 Uint8List 发送按 **4N** 记逻辑工作量：调用者源、verified worker 快照、AES worker 输入、密文输出。普通 List<int> 适配另有 Uint8List 拷贝，按 **5N**。图片/视频另预留 64 MiB 解码工作及至少 512 KiB 缩略图；小 PNG 转成较大 JPEG 时，最终原图编码也至少预留 512 KiB。
3. 默认普通文件/语音可处理上限为 **50331648 字节（48 MiB）**；图片/视频预算上限 **33030144 字节（31.5 MiB）**，同时仍取现有图片 20 MiB、服务器/代理、视频限制的更小值。50/100 MiB 整数组发送现在会明确拒绝，不能为了夹具而增大默认预算。`MediaTransferLimitException.maximumPayloadBytes` 提供精确值；安全文案包含“内存预算/缩小或压缩后重试”。RoomPage 和 outbox 的专用映射由文件 owner 接入联测，未完成前不宣称用户体验闭环。
4. MMS 非视频选择前预检，视频按转码后文件判断。最多 12 字节的 MIME 估算前缀也先获得小预算，防扩展名隐藏图片解码成本。完整读取使用限长 openRead，并在增长越界时拒绝，保持服务器上限预检和固定 txid。
5. 缓存 cold flight 从下载到 worker 验证、落盘和内存交接使用同一 reservation；local outgoing cache 不再等网络 scheduler 槽，以免持有字节等待被下载占住的槽。scheduler source 显式绑定其原 Zone，不能继承另一任务的 scope/reservation。已知缓存文件按实际长度估算，未知下载默认有限 48 MiB；`loadMediaWithCache(maximumBytes:)` 可声明更小且真正执行的实际字节上限。
6. 普通/forward/emoji HTTP 使用流读取，检查 status、Content-Length（有则提前拒绝）和每一分块累计实长；无 Content-Length 仍有硬上限。原生 ciphertext 文件在读取前 stat、准入并限长读取。SDK 的密文 SHA/解密和受信明文 SHA、账号 generation/revoke 检查保持；ADR-0060 HKDF/AES-CTR 字节算法未改。
7. queued scope 取消立即移除；运行中的 HTTP/compute/SDK future 不支持 abort 时，真实 settle 前不返还额度。内部 reservation 引用覆盖 scheduler 提前完成取消的情况。嵌套阶段复用整条峰值，超额或并行子阶段明确失败而不等待自身额度；已完成 owner 的旧 Zone 不能重新借用。缓存清理/账号 generation 变化不会释放尚未 settle 的源。

## 明确边界与待办

- 这是**活动执行中的逻辑数组/受控解码工作量准入**，不是进程 RSS 上限。Dart GC、加密库内部临时分配、HTTP 已交付的当前分块、平台返回缩略图之前的原生解码、GPU/视频解码和系统开销仍需设备实测。
- 既有 encoded LRU 32 MiB 和 Flutter decoded ImageCache 64 MiB 是独立驻留预算，不伪称包含在 192 MiB 中。已有本地大 seed 的临时副本继续由 encoded LRU 计数。
- `_DeferredOutgoing*` 准备完成后的排队/重试原件驻留，及 `gallery_media_payload.originalBytes()` 的原生相册入口尚需受控文件接口。此提交只覆盖这些数据进入实际 SDK 发送后的活动阶段；prepared_chat_video 覆盖转码后读文件/封面阶段，返回后的排队驻留仍待 durable owner 闭合。
- 没有做 B1 的 100 MiB 文件流式加密/上传、无全量数组或 50 次真机生命周期验证。100 MiB 的旧 R7b worker 验证通过显式 **400 MiB 测试预算**继续验证算法/执行上下文；64 MiB encrypted preview 磁盘配额测试显式使用 256 MiB 测试预算。这不改变生产默认值。
- 目录治理下一步：media_cache 增量对象字节/访问索引与后台校准，替代写入后的目录全扫描；native 固定 chat-media 目录的 backup exclusion 设置及读回由 root 负责。可再生缓存和唯一待发原件分域，不能让 GC 删除待发源。

## RED → GREEN 与门禁

| 门禁 | 命令 / 证据 | 结果 |
| --- | --- | --- |
| 发送 RED | Flutter media_transfer_admission_test.dart；admission-red.log | exit 1；100 MiB 被发送，五个独立 10 MiB MMS 同时读取/发送（期待四个） |
| 下载 RED | Flutter media_download_budget_test.dart；download-red.log | exit 1；真实 SDK 无长度响应在 3 字节限额下返回全部 6 字节 |
| 全部相关 Flutter | `flutter test --no-pub` 下列 12 个文件；focused-green.log | **127 PASS，exit 0** |
| 分析 | `flutter analyze --no-pub`；analyze.log | 0 issues，exit 0 |
| Repository / Deployment / Template | 独立执行 verify.ps1 的前三门禁；对应 policy 日志 | 全部 PASS，exit 0 |
| 移动安全/依赖边界 | `.venv/Scripts/python.exe -m pytest tests/mobile/test_flutter_boundaries.py tests/mobile/test_vendored_matrix_dependency.py -q` | **8 PASS，exit 0** |
| 完整 verify.ps1 预检 | 工作树 `.env=false` / `.venv=false`；scripts/verify.ps1 在 render-only 段需要配置，并含本变更无关服务/数据库门禁 | 未运行整套；未导入生产秘密。Python边界使用主树既有venv，仅读取工具 |
| 差异/依赖 | git diff --check；pub get --offline --enforce-lockfile with PUB_HOSTED_URL=https://pub.dev | PASS；锁文件无变化 |

Flutter 12 文件：media_transfer_budget_test、media_transfer_admission_test、media_download_budget_test、media_upload_preflight_test、content_addressed_media_test、verified_media_content_test、unified_emoji_media_test、native_media_download_test、room_image_preview_cache_test、media_cache_clear_test、system_camera_capture_test、video_transcode_performance_trace_test。

关键断言：10/50/100 MiB 构造工作量原子准入、默认过大永不排队/读取、跨 MMS 共享、源增长、排队取消、HTTP 不可中止保留额度、清理/取消不回流、真实 SDK direct/lease 上传期间额度保持、真实 SDK 错误密文拒绝、R7b 一次 worker digest、图片元数据及 ADR 字节兼容。Native bridge fixture 是 Flutter 模拟平台渠道，不等于 Android/iOS 原生设备验收；media index fixture 的 UnimplementedError 是既有模拟降级，未证明原生索引运行。

工具：Windows / PowerShell 7 UTF8NoBOM；Flutter 3.44.9 / Dart 3.12.2；Python UTF8。没有联网真实 Matrix/APNs、部署、生产密钥、签名包或用户媒体测试。

## 阶段计时

| 阶段 | 开始（UTC+08） | 结束 | 结果与来源 |
| --- | --- | --- | --- |
| 设计/源码调查、工作树 | 在首次 RED 前完成，精确起点未留存 | 12:08:53 前 | 不补造精确耗时 |
| 发送 RED | 2026-10-11 12:08:53 | 12:09:15 | 日志创建/写入时间；真实 2 fail |
| 下载 RED | 12:13:43 | 12:13:48 | 日志创建/写入时间；真实 overflow fail |
| 实现/回归迭代 | 12:09:15 | 12:32:51 | 阶段重叠，含缓存 scheduler Zone 归属、resize 编码扩张及旧64/100MiB测试显式预算修正；不累加为总墙钟 |
| 最终相关测试/分析 | 12:32 左右 | 12:33 左右 | 以 focused-green.log/analyze.log 实际时间及 input-hashes 为准；本地无 CI id |

回退：整体撤回本源码候选；没有数据库、磁盘格式或 wire 协议迁移。部署及最终包发布均由 root 统一执行，当前仅候选。
