# MI 6 性能诊断 Debug2174 交付与实测

## 交付身份与边界

- 用户授权：2026-09-25 在 MI 6 保留数据安装 Debug，并检测性能与网络。没有公开 APK 分发、生产服务部署、代发消息、拨打电话或资金操作。
- 隔离源码：`codex/performance-debug-mi6` 的 `c06886679146b5c35876ac472661a2487877d981`，从 Android 已发布源 `e7ba46a4` 整合诊断 `8d044655`；`pubspec.lock` SHA-256 `a2af1ef677f2bee3af4d012d15eb5dc2492d220bf66eabb27ccf62c17fd733fc`。
- 最终包：`standard` ARM64 Debug 0.4.11+2174，SHA-256 `3317ba916a39c88fb341509af91d55d21e819ba96951e11105cf2a400685e06c`，固定测试证书 SHA-256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。
- source Flutter APK 只是中间产物。Apktool 2.12.1 重建 DEX、resources.arsc、Manifest 后经 zipalign、固定身份签名；独立比较确认 27,317 个 class 的 smali 语义一致、全部 DEX 二进制变化、资源重建、Manifest 语义一致、Flutter/native assets 不变，`apksigner` 和载荷检查通过。构建脚本退出 0；[构建元数据](artifacts/2026-09-25/performance-debug-mi6/run-20260925-045044/artifact.json)与[重建验证](artifacts/2026-09-25/performance-debug-mi6/run-20260925-045044/verification.json)。
- MI 6 `cbd0156b` 从 0.4.10+2171 Debug 用 `adb install -r` 覆盖；装前旧包 SHA、装后新包 SHA 均从设备 `base.apk` 读回一致，首次安装时间仍为 2026-09-20 09:35:24。启动成功，安装后 crash buffer 中本应用记录数 0；[设备验证](artifacts/2026-09-25/performance-debug-mi6/device-verification-2174-20260924T2100023626163Z.json)。安装脚本首次因 ADB shell 日期格式参数被拆分，在执行 install 前退出；修正后重试一次成功，旧版在失败后仍完整保留。

## 源码门禁

| 门禁 | 结果 | 退出码 |
| --- | --- | ---: |
| `flutter analyze lib test --no-pub` | No issues found | 0 |
| Flutter 聚焦 6 文件 | 66 通过 | 0 |
| `flutter test --no-pub --reporter expanded` | 4277 通过、9 跳过 | 0 |
| `flutter test test/features/matrix --no-pub --reporter expanded` | 2108 通过、9 跳过 | 0 |
| `py -3.12 -m pytest tests/mobile -q` | 108 通过、1 跳过 | 0 |
| 后端诊断聚焦 4 文件 | 166 通过、1 跳过 | 0 |
| OpenAPI `--check`、仓库策略 | 通过 | 0 |

日志位于 `docs/verification/artifacts/2026-09-25/performance-debug-mi6/`。本整合分支没有重跑全量后端测试；原诊断分支曾有 2861 通过、74 跳过，但输入不同，不能作为本分支全量门禁。本工作树无 `.env`，没有重跑 `scripts/verify.ps1`。

## 设备端诊断结果

`CHATFLOW_PERFORMANCE_METRICS=true` 已生效。通过仅限 ADB loopback 的 Dart VM `ext.chatflow.performance` 读取有界快照，过滤后只保存封闭枚举与数字；不保存 VM URI、operation ID、用户身份或日志原文。[首次启动快照](artifacts/2026-09-25/performance-debug-mi6/vm-summary-20260924T210119598039Z.json)及[前台返回快照](artifacts/2026-09-25/performance-debug-mi6/vm-summary-20260924T210626722786Z.json)。

| 场景 | 实测 | 限制 |
| --- | --- | --- |
| 安装后首次冷启动 | `app_startup` 1367 ms；首帧阶段 1365 ms；21 帧观测中 11 慢帧（首次 6 帧中 4 慢帧） | 只有一次 Debug 冷启动；诊断与 JIT、首次安装成本混合，不能推断 Release P95。|
| 登录页 HOME→返回前台 | 5 帧，1 慢帧；build 最大 2.0 ms，raster 最大 17.5 ms | 登录前没有 `app_resume` 业务 trace，不能推断 Matrix 恢复耗时。|
| trace 帧关联 | `app_startup` trace 的慢帧字段为 0，但全局帧计数已有慢帧 | FrameTiming 回调可能晚于首帧 trace 完结；启动操作的慢帧归属当前存在漏计风险，应在后续优化诊断相关性。|

设备当前显示登录页，未取得会话打开、消息发送、媒体、钱包、Matrix `/sync` 和 WebRTC 实际操作样本。不能依据空样本声称这些场景已通过或优化完成。

## 网络实测

Android 9 系统默认传输为 `VALIDATED` Wi‑Fi。独立在 MI 6 上用 Android curl 7.58 发起无凭据 HTTPS 请求，抓取真实 DNS、TCP、TLS、首字节与总耗时；这不是 Flutter `http` 或 Matrix SDK 的内部分段。所有数值为毫秒，TCP/TLS/TTFB 为相邻累计时间相减；[公开入口 5 次](artifacts/2026-09-25/performance-debug-mi6/network-head-mi6.json)、[Business/Matrix 各 5 次](artifacts/2026-09-25/performance-debug-mi6/network-services-mi6.json)。

| 端点类别 | HTTP | 5 次总耗时 | 有代表性的长尾 |
| --- | --- | --- | --- |
| 公开入口 HEAD | 均 302 | 302、313、317、1527、3615 | 3615 ms 样本中 TCP 1172 ms、TLS 2287 ms。|
| Business `/health/ready` GET | 均 200 | 167、520、556、597、4791 | 4791 ms 样本中 TLS 1190 ms、TLS 后到首字节 3428 ms。|
| Matrix `/versions` GET | 均 200 | 188、189、908、944、1592 | 1592 ms 样本中 TCP 1140 ms。|

**当前判断：** transport 有效，Business 和 Matrix 服务均可达；短样本暴露出建立连接、TLS 与一次 Business 首字节等待的长尾。服务端处理与网络读等待在 curl 的 TTFB 中混合，不能单凭 3428 ms 判定数据库慢。Matrix versions 可达也不代表用户的 Matrix session 已连接。五次样本不足以给出稳定 P95/P99。

同一时间窗的只读生产日志聚合：网关记录 Business ready 与 Matrix versions 各 5 条、均 200；Synapse 自身 5 条 versions 的 `Processed request` 在日志精度下 P50/P95/MAX 都约 1 ms。因此 Matrix 公共请求的 0.19–1.59 秒主要不在 Synapse 应用处理，但仍无法在网关、TLS 和公网链路之间细分。现行 Nginx access log 没有 `request_time`/`upstream_response_time`，Business API Uvicorn access log 没有耗时，也没有与设备探测关联的请求 ID；4.791 秒 Business 长尾仍不能可信归因。[匿名聚合证据](artifacts/2026-09-25/performance-debug-mi6/production-window-aggregate.json)。本次未改动、重启或部署生产服务。

## 可优化空间与下一步

1. 优先在登录后采集 `conversation_open` 分阶段、`matrix_sync` response wait/processing、Business API 请求 trace，再确认用户体感卡顿由哪一层主导。当前证据不足以改业务逻辑。
2. 对 HTTPS 长尾，先在后续受控变更中为网关 route template 增加 request/upstream timing 并打通短期 correlation ID，结合已有 Business API 诊断确认服务端占比；同时重复设备 TCP/TLS 探测并检查连接复用。当前 Synapse versions 处理约 1 ms，但公网到设备的 Matrix 总耗时有 0.19–1.59 秒波动。不要把 Matrix 断线直接归因手机断网。
3. 调整首帧 trace 与异步 FrameTiming 的归属时机，避免全局慢帧已记录但 `app_startup` 显示 0 的诊断误导。需先写可复现测试，再重新构建真机包。
4. 用户自行登录后继续测聊天打开、联系人、朋友圈、钱包、媒体；消息/通话仅在用户提供明确测试对象和场景时采集。HTTP 栈中真实 DNS/TCP/TLS 分段仍为 `unsupported`，独立 curl 的数值不能回填为应用请求指标。

## 隐私

快照筛选后无用户名、roomId、eventId、消息、token、媒体 URI、IP、SDP、ICE、E2EE 数据。网络证据只保存端点类别、状态和时长；没有 URL query 或响应正文。调试截图只用于确认当前为登录页，未纳入报告；本地临时截图的删除命令受到自动审批策略阻止，位置为 `docs/verification/artifacts/2026-09-25/performance-debug-mi6/mi6-screen-temporary.png`（忽略目录、未跟踪）。不再采集截图。
