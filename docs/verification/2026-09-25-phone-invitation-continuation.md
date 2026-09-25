# 手机号验证码已验证后补填邀请码：候选验证

## 故障与授权

用户在 MI 6 的 Debug2175 指出：新手机号尚未注册，首次提交未填写邀请码；随后补填时旧验证码已被供应商消费，出现“无效或已过期”。用户明确要求允许此时输入邀请码，保留已经通过的验证码状态，不再获取短信。阿里云校验 PASS 与本地事务不能共同回滚，所以必须由服务端签发可验证的短期续行证明，客户端不能自行保留六位码并声称已验证。原先“短信服务暂不可用”的生产配置遗漏已在 09:45 HKT 单独恢复；供应商发码接口即时 OK 不等于终端收到短信。

## 代码与安全边界

- 新客户端在 `/auth/phone/login` 显式请求邀请码续行；旧客户端默认行为保持。未知新手机号经真实 OTP PASS 后，本地在同一事务消费 OTP 并建立五分钟 `login_invitation`。响应 `INVITATION_VERIFIED` 携带 256 位随机票据，`Cache-Control: no-store`；此时无账号、邀请码占用或 Matrix Outbox。
- 服务端数据库只存票据、手机号和设备键的 HMAC 摘要。续行端点检查票据、手机号、设备、有效期及纠错次数；邀请码及条款可补填。有效邀请码成功时，在单事务中建立账号、占用邀请码、产生 Matrix provisioning Outbox，并把原证明改为已有 `login_resume`。丢失邀请码提交响应可用同一票据安全继续；重复续行不重复开户。
- 客户端只在收到服务器明确证明后显示“验证码已通过”，在本页内存持有票据；更换手机号、切换登录方式或重新发码会清除。错码、网络结果未知、旧客户端 422 均不产生已验证状态。短信、邀请码、ticket、设备密钥、手机号、消息、Matrix/E2EE 内容均未加入诊断日志。
- 证明过期在取得数据库锁后、PostgreSQL 手机号并发 advisory lock 后和提交前重新读取时钟。SQLite 续行显式开始外层写事务，使延迟过期时的 SAVEPOINT 回滚也撤销用户和 Outbox。

## 本地证据

| 门禁 | 结果 | 退出码 |
| --- | --- | ---: |
| 票据、邀请码纠错、设备绑定、旧客户端兼容等后端专项 | 96 通过、1 条 PostgreSQL 条件跳过；两项过期测试先红后绿 | 0 |
| 隔离 PostgreSQL 18 的 8 路同票据并发测试 | 1 通过；唯一账号、邀请码使用和 Outbox | 0 |
| `flutter analyze lib test` | No issues found | 0 |
| `flutter test --no-pub test/features/matrix` | 2108 通过、9 跳过 | 0 |
| `flutter test --no-pub` | 4295 通过、9 跳过 | 0 |
| `py -3.12 -m pytest tests/business_api tests/business_worker -q` | 2893 通过、77 跳过、1 个 Starlette 测试依赖弃用警告，27 分 11 秒 | 0 |
| `py -3.12 scripts/export_openapi.py --check` | OpenAPI 无漂移 | 0 |
| `py -3.12 -m pytest tests/mobile -q` | 108 通过、1 跳过 | 0 |
| `py -3.12 scripts/verify_ui_contract.py` | 32 组件、429 屏一致 | 0 |

独立领域与质量/安全增量复核均已通过，安全复核独立运行 18 条定向测试退出码 0。此前后端全量运行因发现需修复的过期竞态而主动中断，不计为通过；修复后重新完整运行结果如上。`verify.ps1` 在隔离工作树缺 `.env` 时于配置渲染前停下；自动审批拒绝创建临时 `.env`，未绕过。独立门禁还包括仓库政策、部署政策、PowerShell 模板、Python 导入/260 文件 AST、Alembic 单一 0088 head 与离线 SQL、Docker Compose 渲染，均退出码 0。测试运行须把当前工作树的 `services/business-api` 显式置于 `PYTHONPATH`，否则本机 editable install 会导入另一份源码。

## 生产与设备状态

切换前旧 API 使用 StrictModel，会因新客户端的 opt-in 字段拒绝全部手机号登录。因此先发布并验证 API，再保留数据安装 0.4.13+2176；回退时先恢复旧客户端。生产 DB 0088 已备份到服务器 0700 目录，备份 SHA256 为 `0cd7fb84628eaa1f5d07ee22ebb52d6393d608d1f42abe5800fd9793c57e570f`；使用独立 PostgreSQL 16.9 容器恢复出 137 张 public 表及修订 0088，容器已停止。当前生产源码与工作树另有未发布差异，候选只将本次 API 差异应用到当前运行镜像源码。

切换前运行的 API 镜像为 `sha256:2e7ca2e5…`；生产 `identity.py` 与工作树有其它未发布差异。本次补丁以精确上下文应用到实际生产 `identity.py` 副本，候选 `identity.py` 相比生产只增加 33 行、修改 2 行；同时覆盖 `phone.py`，两个文件在应用目录及 site-packages 中哈希一致。仅变更这两个文件的候选镜像 `sha256:b20c1be0…` 已构建；禁网镜像协议 9 项检查、完整应用工厂与实际 `uvicorn` 启动和新旧路由 HTTP OpenAPI 检查均退出码 0。API-only Compose 候选与当前配置除镜像 ID 外完全一致；回退镜像的协议门禁也通过。生产只读发布前检确认当时 API healthy/零重启、schema 0088、备份哈希及 26 个其它运行容器，退出码 0。

候选继承现行 API 镜像缺少迁移 `0088_profile_grapheme_limits` 文件的既有缺口：对隔离恢复数据库手动运行 `alembic upgrade head` 退出非零，报缺修订。当前生产及本次候选 Compose 均显式用 `uvicorn` 启动、不会执行该镜像默认的迁移命令；本次没有迁移，隔离 `uvicorn` 启动与路由验收通过。该镜像迁移文件欠账需独立处理，不能把本次候选称为迁移自包含镜像。

Debug2176 已由提交 `81bb67c3135175aaa7d6d814622f93e0166f2b25` 构建，标准 ARM64 Debug `0.4.13+2176`。源码构建 → Apktool 2.12.1 DEX/资源/Manifest 重建 → build-tools 36.0.0 对齐 → 原固定证书签名 → 签后验包、独立重解包和语义比对，18/18 步退出码 0。最终 APK 145,641,771 字节，SHA256 `4ea9263927f005ffed8714e34b881f0f289ed34abbb6be339c65732977275c1b`；固定证书 SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。27,317 类、339 个原生库/资产项和清单语义与源码 APK 核对，重建 DEX/资源确已生成。[构建证据](artifacts/2026-09-25/phone-invitation-continuation/android-build/run-20260925-122928/artifact.json)及[验包报告](artifacts/2026-09-25/phone-invitation-continuation/android-build/run-20260925-122928/verification.json)。

## API-only 生产切换

2026-09-25 12:45:06–12:45:27 HKT 调用现有 `business_release_guard.py`，仅切换 `business-api` 到候选 `sha256:b20c1be074ad4113b31c54cbbcd07b71d17b52a3308633b5bc201d4e866070a9`，保留 worker 和所有其它 25 个容器、DB 0088、环境配置。guard 自身 9 项协议门禁通过，冻结的当前 Compose 位于服务器私有 `/opt/starchat/releases/guarded-kgvpz3p3/compose.json`；回退镜像 `sha256:2e7ca2e5…` 与配置已备份并通过同一协议门禁。发布脚本对健康、容器/环境漂移、HTTPS、API 路由、OpenAPI 兼容及错误日志执行自动验收，**退出码 0，passed=true**：API healthy/零重启、环境未变；Business ready 200、Matrix versions 200、未认证资料 401、新旧手机号路由空请求各 422、新路由可见、旧客户端 opt-in 默认 false、OpenAPI 312 路径、新 API 错误标记 0。无真实短信或账号操作。MI 6 安装在该服务端验收之后执行。

## MI 6 Debug2176 覆盖安装

API 验收后运行固定签名[2176 安装脚本](artifacts/2026-09-25/phone-invitation-continuation/android-build/install-mi6.ps1)，`adb install -r` 保留数据，退出码 0。安装前旧 2175 设备包 SHA 与已验包一致；安装后 `0.4.13+2176`、`DEBUGGABLE`，设备 `base.apk` SHA256 与上文 2176 最终包完全一致；首次安装时间仍为 `2026-09-20 09:35:24`，应用进程运行，安装后本应用 crash buffer 为 0 条。[设备证据](artifacts/2026-09-25/phone-invitation-continuation/android-build/device-verification-2176-20260925T0446493185967Z.json)。未代用户请求验证码、输入邀请码或账号；真实业务流程等待用户在手机上操作。

## MI 6 无账号性能与网络对照

2176 的[匿名 VM 快照](artifacts/2026-09-25/phone-invitation-continuation/device-diagnostics/vm-summary-20260925T045039704842Z.json)显示一次 Debug 冷启动 `app_startup` 为 1372.858 ms，6 帧中 4 帧超过当前预算，build 最大 762.830 ms、raster 最大 147.013 ms、总帧最大 805.379 ms。该样本只有一次冷启动，不能推断聊天页面或 Release 性能。`app_startup` trace 的 `slow_frame_count=0` 与聚合 4 并存；Flutter 的帧 timing 在 raster 后回调，当前 trace 在首帧 post-frame 立即结束，因此这个 0 不能证明启动没有慢帧，帧归因需要修正或标记未知。聚合窗口中的 4 帧也不能直接归入这一条 trace。

[第一轮 MI 6 公网探测](artifacts/2026-09-25/phone-invitation-continuation/device-diagnostics/network-public-2176-20260925T0451438090877Z.json)对 Business ready 和 Matrix versions 各 3 次：每个入口只有 1 次 200，另外 4 次在约 10 秒超时；成功请求分别用 3008.5 和 9172.6 ms，长耗时主要在建连/TLS 完成前。该探测由设备系统 curl 发起，测得的 DNS/TCP/TLS 相位不可填入 Flutter HTTP 的请求相位。

[第二轮 MI 6 公网探测](artifacts/2026-09-25/phone-invitation-continuation/device-diagnostics/network-public-2176-20260925T0454548719168Z.json)为 Business 2/3、Matrix 3/3 返回 200；Business 另 1 次约 10 秒超时，成功请求 177.1–7875.5 ms，Matrix 最慢一次到 TCP 完成为止已 7200.5 ms。两轮合计 **5/12 超时**，其余请求也有 7.88–9.17 秒长尾。同检查窗口从[生产服务器独立访问相同公网健康端点](artifacts/2026-09-25/phone-invitation-continuation/device-diagnostics/network-public-server-2176-20260925T0458085871568Z.json)为 6/6 返回 200，Business 43.4–247.5 ms、Matrix 209.4–221.7 ms。[MI 6 脱敏网络状态](artifacts/2026-09-25/phone-invitation-continuation/device-diagnostics/transport-state-2176-20260925T0500378658961Z.json)显示默认网络已连接且 Wi-Fi 系统验证联网，但这不保证每次请求顺利建连。证据将主要待查点收窄到 **手机到公网入口的传输/建连/TLS 长尾**；不能据此认定服务器或短信供应商导致这些超时，也不能从公开健康端点反推真实认证请求结果。

[地址族对照](artifacts/2026-09-25/phone-invitation-continuation/device-diagnostics/network-family-2176-20260925T0502571970483Z.json)中，强制 IPv4 的 4 次请求只有 2 次返回 200（147.5、3164.8 ms），另 2 次在 8 秒上限内超时；强制 IPv6 的 4 次均为 DNS 解析失败，因此没有有效 IPv6 时延对照，不能把 IPv4 的长尾解释成 IPv6 回退。客户端只读核对显示手机号 OTP/提交/邀请继续各有单请求 8 秒上限、无自动重试；密码登录 Business API 没有显式总超时，控制器对指定传输异常最多尝试 3 次，间隔 250/500 ms。普通授权请求每次 8 秒，刷新与重放总预算 20 秒。下一步可在不改变一次性验证码语义的前提下，为密码登录定义明确的整链路等待上限，并分别诊断调用方超时与底层 HTTP 最终结果；网络侧优先追踪手机 Wi-Fi/路由到公网 IPv4 的建连与 TLS 长尾。上述建议仍需复测，不能凭健康端点探测证明登录业务已修复。

[短信链路只读复核](artifacts/2026-09-25/phone-invitation-continuation/sms-readonly-summary.json)：生产 API/worker 健康且零重启，手机号认证与阿里云短信配置已启用。过去 24 小时匿名聚合有 8 次登录验证码签发、供应商接口即时接受 8 次；最新签发为 03:05:14 UTC，早于新版 API 发布和 2176 装机；此前两小时没有新的签发记录。当前实现对速率限制和部分不适用目标也可能返回 accepted，且供应商接口即时 OK 不包含运营商/终端送达回执。故历史“短信服务暂不可用”的配置原因已排除，但用户最近未收到新短信的原因仍无法锁定；需要用户自行在 2176 发起一次后，用匿名时间窗对齐客户端请求、服务端 challenge/供应商结果与送达状态。不得仅凭界面倒计时声称短信已送达。

## 帧归因与接收协议修正候选

2176 样本暴露了首帧 post-frame 结束 trace 早于 Flutter raster timing 回调的问题。修正后的客户端候选使用真实 VM timeline 时间戳按操作窗口增量归因，`finish()` 的业务耗时仍同步冻结；最长等待 1200 ms 回调，未覆盖或时钟不一致时报告 `frame_attribution_complete=false`、省略 `slow_*`，不再伪报 0。普通 Release 未启用本地帧指标时同样保持 unknown；账号代次切换丢弃待归因记录。45 秒/2691 帧且本地样本容量为 3 的测试确认长操作不会因环形样本淘汰而丢失帧计数。帧专项 7/7、`flutter test --no-pub test/performance` 94/94、`dart analyze lib/core test/performance` 无问题，均退出码 0；startup 接线先红后绿，3/3 通过。**这项修正尚未装入 MI 6 的 2176，不应把该设备现有 trace 的慢帧 0 当成实测 0。**

服务端现行严格诊断接收 schema 不认识 `frame_attribution_complete`，必须先发布兼容接收端，否则新版客户端上传 422 后会停止该会话的操作上传。候选接收端兼容 legacy 三计数、complete=true 三计数和 complete=false 无计数，拒绝矛盾形态；OpenAPI 的条件 oneOf 与运行时校验一致。后端测试先红后绿，`test_client_diagnostics.py` 156/156、OpenAPI export/check 均退出码 0。当前生产仍运行旧接收端，客户端修正版尚未安装；生产发布与真机复测须按服务端先行顺序完成。

## 已知限制

首次携带 ticket 的响应若在 OTP PASS 后丢失，客户端没有票据；供应商状态与本地数据库不能原子提交，必须再取新码。最终 `/login/complete` 已消费票据但会话响应丢失时，现有一次性完成流程也不能恢复；本轮没有扩大其认证语义。服务端没有短信终端投递回执，真实到达和首次 Matrix 会话确认仍需用户自行操作验证，不能从发送 API 的 202 推断成功。
