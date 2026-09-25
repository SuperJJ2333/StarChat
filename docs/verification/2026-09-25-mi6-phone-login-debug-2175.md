# MI 6 手机登录防重提与 Debug2175 验证

## 结论

生产手机号认证和阿里云短信配置已按[恢复报告](2026-09-25-mi6-production-restore.md)恢复。用户在旧 Debug2174 看到“聊天设备会话确认未完成”后点击“重试”，客户端重新提交了一次性验证码，随后服务端按设计拒绝旧码。Debug2175 改为在任何有效手机号验证码提交前锁定本页旧码，所有失败和结果未知分支均清空输入，只允许用户主动请求新码；保留现有 60 秒冷却，不自动发短信或重提。Debug 增加 Matrix 本地凭据读取与 Business 会话确认请求两个封闭失败边界；不改变 E2EE、broker、服务端一次性消费或原有补偿逻辑。

用户在 2175 上报告未收到新短信。03:05:15 UTC 的服务端只读聚合存在一次发码 202 及新建、可用、未消费的登录挑战，供应商发送 API 即时返回 OK；应用匿名快照也有一次 auth POST 202/3392 ms。**202 和供应商即时成功均不证明短信已到手机。** 当前系统没有投递回执；本次未代用户请求第二条短信。03:05:27 UTC 的登录 422 只有状态码，日志无安全的固定错误码字段，不能判断是请求校验还是条款要求，也不能按聚合断言它属于同一用户。首次 Matrix 会话确认失败尚未在新版由真实新码复现，根因仍未知。

## 源码与交付身份

| 项目 | 证据 |
| --- | --- |
| 源码 | `codex/performance-debug-mi6`，提交 `dc0b0132f7a4733a134a52439eacd13dac3d9a62` |
| 最终包 | standard ARM64 Debug `0.4.12+2175`，145,625,387 字节，SHA256 `a0e0a8ffdb46f18f2a003834ff28f95c388f8e3cd0c9d35d33ff7b8c25123b61`；[构建元数据](artifacts/2026-09-25/phone-login-debug-mi6/run-20260925-105702/artifact.json) |
| 固定证书 | SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，与设备旧 2174 包一致 |
| 构建 | Flutter 源码构建 → Apktool 2.12.1 DEX/资源/Manifest 重建 → build-tools 36.0.0 zipalign → 固定证书签名 → apksigner、对齐、载荷、独立重解包和语义比对；构建脚本退出码 0，[比对报告](artifacts/2026-09-25/phone-login-debug-mi6/run-20260925-105702/verification.json) |
| MI 6 | `cbd0156b`、`sagit`；安装前设备 2174 APK SHA 与本地已验包一致，`adb install -r` 成功；安装后设备 APK SHA 与上文 2175 完全一致，首次安装时间仍为 `2026-09-20 09:35:24`，启动成功，本应用安装后 crash buffer 0 条；[设备验证](artifacts/2026-09-25/phone-login-debug-mi6/device-verification-2175-20260925T0300445669921Z.json) |

没有公开发布 APK、修改更新弹窗、清除应用数据、执行新的生产发布或发送验证码。

## 测试与审查

| 命令或门禁 | 真实结果 | 退出码 |
| --- | --- | ---: |
| 新增 OTP 防重提用例（先红后绿） | `PHONE_PROVISIONING_PENDING`、Matrix grant/本地账号、超时、未知错误、账号切换取消、启动回调、手机号在发码期间改变等 14 个 widget 测试通过 | 0 |
| `flutter analyze lib test --no-pub` | `No issues found`；2175 版本常量修正后再次通过 | 0 |
| `flutter test test/features/matrix --no-pub --reporter expanded` | 2108 通过、9 条条件跳过；Matrix 输入在后续版本号修改中未变化 | 0 |
| `flutter test --no-pub --reporter expanded` | 4289 通过、9 条条件跳过；后续仅修改 app version 常量与 pubspec，并单独复测版本/登录专项 | 0 |
| 2175 版本后的 Flutter app config、登录 UI 与诊断专项 | 18 通过 | 0 |
| `py -3.12 -m pytest tests/mobile -q` | 首轮发现 pubspec 与 `AppConfig` 不匹配，退出 1；修正后 108 通过、1 跳过 | 0（最终） |
| `py -3.12 scripts/verify_ui_contract.py` | 32 组件、429 屏漂移检查通过 | 0 |
| `pwsh -NoProfile -File scripts/verify.ps1` | 仓库/部署政策及模板测试通过；在配置渲染时因隔离工作树缺 `.env` 退出。使用示例值临时创建 `.env` 的命令被自动审批策略拒绝，未绕过。后端/Compose 等后续完整门禁未执行 | 1 |

ADR-0075 领域审查与质量/隐私复审均放行本次客户端防重提及 Debug 封闭分类。受保护的 session bootstrap 恢复边界是既有问题，本次未改变，不能宣称已修复。构建前工作树干净；`git diff --check` 与本次新增/修改的 11 个文档链接检查通过。旧 `current-state.md` 其他历史段有 16 个既存失效链接，不算本次新增。

## 真机性能与网络

`CHATFLOW_PERFORMANCE_METRICS=true` 已启用；仅经 ADB loopback 读取 Dart VM 的有界快照，落盘前只保留封闭枚举与数值，不保存原始 VM URI、operation ID、身份或正文。[03:02 快照](artifacts/2026-09-25/phone-login-debug-mi6/vm-summary-20260925T030225874502Z.json)、[03:06 快照](artifacts/2026-09-25/phone-login-debug-mi6/vm-summary-20260925T030656283939Z.json)。

| 指标 | 2175 实测 | 判断边界 |
| --- | --- | --- |
| `app_startup` | 1447 ms | 一次 Debug/JIT 冷启动，不代表 Release P95 |
| 认证 API | 一次 `socket_failure`/31,095 ms；一次 202/3392 ms；一次 422/194 ms | 同属 auth 类别，快照不保存具体子路径或账号；服务端 03:05 发码 202 与设备 202 时间接近，不能以此建立逐请求身份关联 |
| Flutter 帧 | 03:06 累积 17,237 帧中 238 慢帧；最近 1024 样本 `frameTotal` P95 17.573 ms、P99 19.793 ms | 跨整个运行期，不全归于登录；认证 31 秒失败 trace 关联 38 慢帧，主要耗时仍是请求等待 |
| Matrix 会话分类 | 尚无新版 `matrix_session` 边界事件 | 用户未收到新码，无法完成首次成功 OTP 后的同路径复现 |

另以 MI 6 系统 curl 对公开无凭据端点做 3+3 次 HTTPS 探测，保留证书校验；[数值证据](artifacts/2026-09-25/phone-login-debug-mi6/network-public-2175.json)。Business ready 全部 200，总耗时 161、437、5393 ms；5393 ms 样本 DNS 13 ms、TCP 完成累计 1358 ms、TLS 完成累计 5366 ms、TLS 后到首字节约 27 ms。Matrix versions 全部 200，总耗时 140–162 ms。此短窗显示 Business 公共路径长尾主要出现在建连/TLS，不能归咎业务数据库；curl 不等于 Flutter HTTP 内部分段，不能把这些数值回填到应用 `dns_ms/tcp_ms/tls_ms`。此前一次手机 curl 对 Business ready 超时，说明传输并非持续稳定；系统 Wi-Fi 可连接且有 VALIDATED 状态，也不能证明每条请求可达。

## 仍需处理

1. 用户收到实际新短信后自行完成**一次**登录，仅读取 `chatflow/matrix` 封闭 boundary/cause 和匿名操作快照，确定首次会话失败是本地凭据、传输、Business 拒绝还是服务端错误。不要重提已用旧码。
2. 短信未达须通过供应商/运营商投递侧证据继续查；现有 API 只有发送即时响应，没有投递回执或状态查询，不能猜测为网络、模板、拦截或号码问题。03:05 新 challenge 仍未消费，不应再无节制申请验证码。
3. 当前样本显示 31 秒认证连接失败和公网 TLS 建连长尾，优先在设备网络路径与网关增加短期、脱敏的请求耗时关联；需要多次独立复测再调整客户端连接策略。首帧 trace 与异步慢帧归属差异仍见[2174 基线报告](2026-09-25-performance-debug-mi6.md)。DNS/TCP/TLS **应用内分段仍为 unsupported**。

本报告没有消息、手机号、验证码、用户名、Token、roomId、媒体 URI、IP、SDP、ICE 或 E2EE 数据。
