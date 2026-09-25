# 登录与注册交互修复：2178 验证记录

## 范围与源码身份

用户提出六项修复：登录限流倒计时、点击空白收起键盘、手机号错误位置、取码按钮轮廓和按压反馈、深色认证背景、非法手机号也能点击取码并立即校验。用户此前已要求完成后将 Debug 保留数据安装到 MI 6；本次不发布正式包、iOS 或生产服务。

隔离分支 `codex/auth-login-2178` 从 MI 6 已装的 2177 源码后续提交 `c000ebc1` 建立，合入主线账单与钱包的四笔提交，再合入六项认证修复 `03c851a5`。2177 的验证码已通过后补填邀请码 ticket、一次性验证码不得重放、Matrix 设备会话处理与性能诊断保留。版本递增至 `0.4.13+2178`。主工作区的未提交并行改动没有被复制进此候选。

## 根因与改动

| 问题 | 根因 | 修复 |
| --- | --- | --- |
| “登录频繁”秒数不动 | 429 的 `retryAfterSeconds` 丢失在控制器转文案过程中；页面未按截止时间刷新 | 保留 typed 秒数；页面用截止时间、逐秒 timer 和前台恢复重算，过期不自动登录 |
| 点击空白键盘不收 | 认证脚手架无空白点击失焦 | 共用脚手架点击背景时 `unfocus`，输入框正常响应 |
| 手机格式错误在主按钮附近 | 手机验证复用了整页错误 | 字段下单独显示错误与格式正确反馈，编辑后同步更新 |
| 取码按钮缺少触感 | 原按钮无明确轮廓与按压处理 | 共用描边按钮、按压缩放、44px 触摸目标；减少动态效果时不缩放 |
| 深色背景仍亮 | 固定浅色 landing 图像无暗色处理 | 登录、注册、验证码的共用背景加暗色遮罩，表单卡片保持可读 |
| 非法手机号无法点取码 | 有效号码被写入按钮可用性条件 | 非忙碌且非冷却时允许点击；先本地格式校验，不发短信 |

合并复核额外修正：手机号注册建立会话后，号码只读但重发按钮仍可在冷却结束后点击；登录 429 元数据不会被 OTP 冷却 ticker 覆盖。HTML 演示的 OTP 冷却也改用绝对截止时间，后台标签恢复后重算。

## UI 演示与契约

视觉审查入口：`frontend/index.html?screen=phone-login-phone-default-dark`、`?screen=phone-registration-phone-default-dark`、`?screen=auth-registration-default-dark`、`?screen=auth-verification-code-dark`。在本地浏览器查看了深色手机号登录及验证码页，手机号为空点击取码后错误显示在手机号字段正下方，按钮描边可见。Figma 同步已由项目 UI 流程退役。

`packages/ui-contracts/changliao-component-registry.json` 复用现有颜色、间距和动效 token，登记新的认证按钮及只读手机号目的地状态；总数 32 组件、433 页面。没有新增独立视觉 token。

## 已完成门禁

| 命令/场景 | 结果 | 退出码 |
| --- | --- | ---: |
| 注册会话冷却后重发专项，修复前 | 只读/可点或实际重发断言失败；[红测日志](artifacts/2026-09-25/auth-2178/phone-resend-red.log) | 1 |
| 同一专项，修复后 | 点击按钮后 `requestRegistrationOtp` 第二次执行；[绿测日志](artifacts/2026-09-25/auth-2178/phone-resend-green.log) | 0 |
| Flutter 认证聚焦四文件 | 62 通过；[日志](artifacts/2026-09-25/auth-2178/flutter-focused-rerun.log) | 0 |
| `flutter analyze --no-pub lib test`，重发修复后 | No issues found；[日志](artifacts/2026-09-25/auth-2178/flutter-analyze-final.log) | 0 |
| `flutter test --no-pub`，重发修复后 | 4316 通过、9 跳过；[日志](artifacts/2026-09-25/auth-2178/flutter-full-final.log) | 0 |
| `flutter test --no-pub test/features/matrix` | 2108 通过、9 跳过；[日志](artifacts/2026-09-25/auth-2178/flutter-matrix.log) | 0 |
| `npm test`，最终 HTML | 311 通过；[日志](artifacts/2026-09-25/auth-2178/frontend-final.log) | 0 |
| `py -3.12 -m pytest tests/mobile -q` | 108 通过、1 跳过 | 0 |
| `py -3.12 scripts/verify_ui_contract.py` | 32 组件、433 页面 | 0 |
| `pwsh -NoProfile -File scripts/verify.ps1` | Infra 147、Getui 28、Matrix Bot 9、Business API/Worker 2905 通过/75 跳过、移动边界 108 通过/1 跳过，UI 契约、数据库迁移、OpenAPI、Compose 均通过；[完整日志](artifacts/2026-09-25/auth-2178/verify.log) | 0 |
| 2178 固定签名 Debug 构建与 18 项验包 | 源码构建、Apktool 2.12.1 重建、对齐、原测试身份签名、独立解包及语义核验均通过；[步骤日志](artifacts/2026-09-25/auth-2178/android-build/run-20260925-223434/steps.tsv) | 0 |
| MI 6 保留数据覆盖安装与启动 | 旧 2177 SHA、2178 设备读回 SHA、首次安装时间、Debug 标记、进程及零崩溃均核对；[设备证据](artifacts/2026-09-25/auth-2178/android-build/device-verification-2178-20260925T1440367450276Z.json) | 0 |

APK 源码提交 `f3b2d28e79cbcd53ae357bd5bc94d6cfadce0a17`；[构建元数据](artifacts/2026-09-25/auth-2178/android-build/run-20260925-223434/artifact.json)记录最终 SHA256 `1a03074f0c1a1f559355abdf4aac147411005ac942897d9ded79241d23ba9f7b`、大小 145658155 字节、签名证书 SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。MI 6 `cbd0156b` 的首次安装时间 `2026-09-20 09:35:24` 保持，设备读回 SHA 一致，安装后进程运行且零崩溃。

验证环境为 Windows NT 10.0.19045、PowerShell 7.6.5、Flutter 3.44.9 / Dart 3.12.2、Node 22.22.2、Python 3.12.10；`pubspec.lock` SHA256 `a2af1ef677f2bee3af4d012d15eb5dc2492d220bf66eabb27ccf62c17fd733fc`。`flutter --version` 输出版本时曾提示其自动 Git tag fetch 的 TLS 失败，Flutter 分析、测试与 APK 构建使用本机已安装 SDK 均成功。

## MI 6 匿名性能与网络

安装前 2177 同口径基线：公开 Business ready 3/3 返回 200，耗时 134.8、1153.3、7315.4 ms；公开 Matrix versions 0/3，均在约 10 秒连接超时。最慢 Business 样本的 DNS 1520.7 ms、TCP 完成累计 4928.6 ms、TLS 完成累计 7283.6 ms，而 TLS 完成后到首字节仅约 31.6 ms，说明该样本的长尾主要在设备到公网的解析/建连/握手。[2177 脱敏探测](artifacts/2026-09-25/auth-2178/mi6-probe/baseline-2177/network-public-2177-20260925T1438574910254Z.json)。

安装后 2178 连续两轮公开 Business ready 和 Matrix versions 合计 12/12 返回 200，总耗时 139.2–172.4 ms；两轮[首次探测](artifacts/2026-09-25/auth-2178/mi6-probe/candidate-2178/network-public-2178-20260925T1442141935111Z.json)、[复测](artifacts/2026-09-25/auth-2178/mi6-probe/candidate-2178/network-public-2178-20260925T1443136415041Z.json)。Android 默认 Wi-Fi 在采样时为 connected 且 validated。前后相隔数分钟，不能从这组数据断言 2178 修复了网络；现象符合短时间窗的公网链路波动。

2178 Debug 三次[脱敏冷启动记录](artifacts/2026-09-25/auth-2178/mi6-probe/candidate-2178/cold-start-observations-2178.json)：`appStartup` 分别 1357.688、1338.005、1339.945 ms；首帧标记 1335.449–1355.025 ms。每次新进程聚合慢帧 4 帧，build 最大 716.986–745.168 ms，但三个 trace 均 `frame_attribution_complete=false`，不能把聚合慢帧归因到启动。Android 两次 `am start -W TotalTime` 为 5113、5001 ms，与 Dart trace 起点不同，不能相减为具体瓶颈。仅三个 Debug 样本，不代表 Release 或登录后性能。一次[VM 快照示例](artifacts/2026-09-25/auth-2178/mi6-probe/candidate-2178/vm-summary-20260925T144201429596Z.json)。

广州试点域名在同一手机上的公开 Business ready 和 Matrix versions 各 3 次均于 TLS 握手阶段失败（curl 35，无 HTTP 状态），[脱敏记录](artifacts/2026-09-25/auth-2178/mi6-probe/candidate-2178/network-edge-2178-20260925T1446588491643Z.json)。MI 6 已完成 TCP 与 ClientHello，却未收到 ServerHello/服务器证书；[设备 TLS 证据](artifacts/2026-09-25/auth-2178/mi6-probe/candidate-2178/tls-device-filtered-2178.json)。Windows 直连及 OpenSSL SNI/主机名严格验证也未获证书；强制 TLS 1.2 与更换 SNI 仍失败。阿里云主机上的 Caddy 配置和 443 监听仍在，本机针对该域名严格 TLS 验证成功，HTTP 返回 Caddy 308；从公网 HTTP 请求同一试点健康路径却返回 `403`、`Server: Beaver`，页面标题为 `Non-compliance ICP Filing`。[只读双侧证据](artifacts/2026-09-25/auth-2178/edge-audit/edge-tls-readonly-evidence.json)。这强烈指向阿里云公网入站的备案过滤；具体过滤设备未独立验证，域名与云账号责任人需核对备案及接入备案状态。此域名目前不能作为客户端轮询节点，不能通过关闭 TLS 或更换 SNI 绕过，且本次未更改客户端或生产 DNS。

## 有证据的优化空间

1. **国内入口先恢复可用性。** 试点公网已被备案页拦截；由域名/云账号责任人核对 ICP 与接入备案，完成后重做严格 TLS、公网健康路径和真机对照，再评估客户端路由。当前不能把该试点加入轮询。
2. **源站链路需持续观测。** 安装前同一手机的 DNS、TCP、TLS 出现秒级长尾，Matrix 连接三次超时；数分钟后的两轮探测又全部成功。应基于现有统一诊断区分手机传输、服务可达与 Matrix 连接，累计足够样本后再判断是否需要合规的国内接入节点。
3. **首屏与帧归因需要 profile 证据。** Debug 三次 Dart 启动约 1.34–1.36 秒，聚合慢帧明显，但 `frame_attribution_complete=false`。在真实 profile 构建和页面交互场景中采集可归因帧时序，再决定是否优化 Flutter build/raster；当前不能据此指定某个 widget。

## 安全与限制

本次不改服务端鉴权、短信供应商、限频阈值或 Matrix 协议。非法号码、未同意协议和重发冷却不会触发短信请求。2177 的邀请码续行仅在服务端签发 ticket 后生效；倒计时到期不能重放已消耗验证码。测试使用模拟手机号和模拟 API；未申请真实短信、未输入账号凭据。Debug 性能数据只能代表测试机，不能推断 Release 的性能分位数。
