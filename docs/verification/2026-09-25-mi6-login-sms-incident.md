# MI 6 Debug2174 登录与短信故障：只读调查

> 后续进展：2026-09-25 09:45 HKT 已按[生产恢复报告](2026-09-25-mi6-production-restore.md)恢复服务器既有配置。本报告描述**恢复前**的只读现场；其中“未修改生产”仅指调查阶段。后续审查还发现两个已有钱包转换开关漂移，均已按已核准值恢复。真实短信送达及 MI 6 登录仍待实测。

## 结论

1. **验证码暂不可用已定位为生产配置回退。** 2026-09-24 19:29 HKT 的 `wallet-360` API Compose 替换遗漏了 16 项已核准环境配置；worker 的层叠配置也遗漏同 16 项。当前容器实际 `phone_auth_enabled=false`、`sms_provider=disabled`，OTP 申请在 `PhoneAuthService.request_login_otp` 的第一项开关检查就返回 `PHONE_AUTH_DISABLED`/HTTP 503，未请求阿里云。2026-09-23 的[已上线记录](2026-09-23-phone-wallet-live-restore.md)证明此前手机号认证与短信供应商已启用并验证。旧版 Debug2171 与新版2174指向同一生产域名，降级客户端不会恢复短信。
2. **登录长时间转圈是独立链路问题，具体阻塞阶段尚未确定。** 用户确认密码和手机号模式都转圈超过两分钟，之后出现“网络连接中断”。`LoginPage._submit` 设置 `_loading=true`，等待 Business 登录、Matrix 登录/会话、同步及 `session.bootstrap()` 完成后才在 `finally` 结束加载。整条链路没有总时间预算；Business 密码 POST 没有本地 deadline，Matrix SDK 虽给单次 HTTP 请求 35 秒预算，但顺序执行的完整登录/本地启动仍无统一上限。设备匿名 trace 有一次认证类 POST 31,146 ms 后 `socket_failure`，logcat 同时段出现 `Connection timed out`。相同时间窗，服务器密码登录 3×200、Matrix grant 3×200、Matrix token login 2×200、Matrix session complete 1×200、Matrix `/sync` 41×200，说明部分步骤成功，但无法将各条聚合日志与同一次 MI 6 操作逐条关联。用户看到的文案来自 `LoginStageException` 的 network 分类；不能据此把最终失败武断归为手机断网或 Matrix 服务器错误。
3. **配置漂移有额外受保护影响。** 遗漏项包括 FX 依赖凭据，以及原先明确为 `false` 的红包群主抽成开关；后者按当前代码默认值变成 `true`。只读账本聚合显示，自该配置切换至 2026-09-25 08:40 HKT 没有新红包或抽成账本交易。生产 DB 处于 `0088_profile_grapheme_limits`，当前 API 镜像却不含该迁移修订，因此不能整份回退旧镜像/Compose，也不能未经兼容门禁重启替换。

## 证据与边界

| 来源 | 可确认事实 | 不能推断 |
| --- | --- | --- |
| [设备 VM 匿名快照](artifacts/2026-09-25/performance-debug-mi6/vm-summary-20260925T001742728566Z.json) | auth POST 一次 31.146 s socket failure；两次 HTTP 200（4.064 s、0.738 s） | trace 不含具体子路由，不能指认是哪一次验证码、密码或 Matrix grant。|
| MI 6 本应用 logcat（仅现场分类，不保存原文） | 08:13:49、08:14:20 HKT 有 `SocketException`/`Connection timed out` | 不可据此认定所有请求超时或系统 Wi‑Fi 离线。|
| [生产脱敏聚合](artifacts/2026-09-25/performance-debug-mi6-login/server-sms-incident.json) | OTP 1×503；密码 3×200；Matrix grant 3×200、session complete 1×200、Matrix login 2×200、sync 41×200；refresh 3×200/10×401 | 窗口覆盖其他客户端；refresh 401 不能全部归给 MI 6。网关未记录跨层 ID 或请求耗时。|
| 同机无凭据公网探测 | Business ready 3×200（139–280 ms），Matrix versions 3×200（148–165 ms） | 只证明探测时服务可达，不证明 08:13–08:14 每条认证请求成功。|
| 客户端源码 | `LoginPage` 的 `finally` 只在整条 Future 结束时运行；直接 `SocketException` 在控制器中显示“网络连接不稳定”，后续阶段统一映射“网络连接中断” | 不能在没有分阶段 trace 时确定最后卡在 Matrix sync、会话确认或本地 bootstrap。|

## 修复边界与建议顺序

1. 从**当前** wallet-360 API/worker 镜像及运行 Compose 派生候选，只把 09-23 已核准但 09-24 丢失的 16 项配置按逐项审查合入；凭据仍留服务器 0700/0600 私有目录，不写入仓库/日志。先确认 `0088` 迁移兼容、续期协议、短信装配与金融默认值，再做隔离数据库及 API/worker 门禁。ADR-0075 认证与 ADR-0078 红包的领域、质量/安全审查不可跳过。
2. 用户操作修复需要在 Debug 客户端增加**封闭枚举的登录阶段耗时**或等效安全证据，复现“超过两分钟后网络连接中断”时明确最后阶段；为认证 HTTP/Matrix/会话启动定义预算与取消语义，写失败测试后实施。不能通过隐藏转圈、吞错误、跳过 Matrix/E2EE 或清除本地数据制造成功。
3. 重新装包必须按 Android 重建与固定签名流程，版本高于 2174，并保持 MI 6 数据。当前 ADB 已变为 offline，设备端复测须等连接恢复。没有从本调查执行真实短信、生产写入、镜像切换、数据库修改或设备重装。

## 安全

报告与 JSON 只有路由模板、状态计数、配置**变量名**、布尔状态、版本及聚合数量。没有手机号、用户名、Token、短信凭据、IP、消息、Matrix ID、真实请求体或完整日志。
