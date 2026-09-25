# MI 6 Debug2174 登录与短信故障调查

## 恢复入口

- 用户反馈（2026-09-25）：Debug2174 无法正常发送验证短信；短信服务提示暂不可用；登录按钮长期显示加载图标。不可要求用户提供手机号、密码或验证码。
- 设备：MI 6 `cbd0156b`；已安装 `com.liuhetong.mobile` 0.4.11+2174 Debug，调查初始在线且应用运行，之后 ADB 断开。APK 身份与前次[装机报告](../../verification/2026-09-25-performance-debug-mi6.md)相同。
- 工作树：`C:/Users/Administrator/.codex/worktrees/performance-debug-mi6/StarChat`，分支 `codex/performance-debug-mi6`，调查起始 HEAD `899adfdf5c7cda753aba0fc85d780c29a29e1a5f`，无未提交改动。root 拥有设备/文档与可能的最终修复；客户端差异和生产短信/API 由独立只读代理调查，互不编辑文件。
- 范围：先定位真实故障链路，再写失败测试并做最小修复。生产检查只读；不触发真实短信、不代填凭据、不清除应用数据、不降级。
- 当前状态：短信根因已确认是 09-24 API/worker Compose 遗漏 16 项已核准配置，`PHONE_AUTH_DISABLED`/503；密码登录转圈与其独立，最后具体阶段未确认。用户补充转圈超过两分钟后出现“网络连接中断”。只读[事故报告](../../verification/2026-09-25-mi6-login-sms-incident.md)记录服务器、设备和代码证据。MI 6 ADB 当前 offline，已请求用户恢复连接。

## 验收台账

| ID | 预期 | 当前证据 | 状态 |
| --- | --- | --- | --- |
| LOGIN-01 | 登录按钮在成功、业务拒绝、网络失败均结束加载状态，错误可理解 | >2 分钟后“网络连接中断”；整条 DualDomain + bootstrap 无总预算；设备 auth POST 有 31 s socket timeout，生产密码与 Matrix 部分请求均 200，末端阶段未定位 | 待分阶段实测与修复 |
| SMS-01 | 已配置的短信服务能够正常受理验证码请求；不可用时给出具体、准确原因 | 09-24 Compose 丢失既有认证/短信配置，实际 `phone_auth_enabled=false`、`sms_provider=disabled`；OTP POST 503 `PHONE_AUTH_DISABLED`，未到阿里云 | 根因已确认，待受控恢复 |
| NET-01 | 区分设备传输、认证 API、短信提供商和 Matrix 登录阶段 | VM trace：一次 auth POST 31,146 ms 后 `socket_failure`；另两次 200。生产密码 3×200、Matrix grant 3×200、Matrix login 2×200、sync 41×200；聚合无法逐请求关联 | 部分定位 |
| DELIVERY-01 | 如须改客户端，保留数据重建并将高版本固定签名 Debug 装回 MI 6 | 当前仍为 2174；尚无修复包 | 待根因 |

## 已取得的安全证据

- 设备 VM 扩展的匿名[诊断快照](../../verification/artifacts/2026-09-25/performance-debug-mi6/vm-summary-20260925T001742728566Z.json)：auth POST 一次 31,146 ms 失败、`network_error=socket_failure`；另两次 HTTP 200，分别 4064 与 738 ms。trace 仅有 `auth` 类别，没有 endpoint path/body 或用户身份，故不能仅凭它判断哪次是短信、哪次是登录。
- 本应用进程的 logcat 在 08:13:49 与 08:14:20 HKT 出现 `SocketException`/`Connection timed out`。仅提取类型与时间，未保存完整日志、主机/IP、号码或凭据。
- 同机当前无凭据 GET：Business `/api/v1/health/ready` 三次 200、139–280 ms；Matrix `/versions` 三次 200、148–165 ms。这证明检查时公网服务可达，不能证明 08:13–08:14 的认证请求已到达 API，也不能证明短信提供商可用。
- 调查未修改生产或设备状态；客户端代码比对与生产日志/配置核对均已完成。
- 当前 API/worker 相比 09-23 已核准 Compose 同缺 16 项环境配置；旧私有配置仍存。红包抽成开关由原 `false` 落到默认 `true`，但切换后至 08:40 HKT 新红包及抽成账本均 0。生产 DB 为 0088，当前 API 镜像缺此迁移修订；不允许整体旧镜像/Compose 回退。

## 阶段计时与下一步

| 阶段 | 时间 HKT | 结果 | 下一步 |
| --- | --- | --- | --- |
| 用户反馈与设备基线 | 2026-09-25 08:17–08:18 | Debug2174 在线，应用运行；VM trace 采集成功 | 客户端/服务端边界核对 |
| 公共路径与 logcat 分类 | 08:18–08:20 | 当前公共 HTTPS 200；之前认证链路有 31 秒 socket timeout | 区分瞬时传输与 API/短信业务故障 |
| 生产只读配置/日志/账本核对 | 08:19–08:40 | 短信服务关闭及 Compose 漏项证实；登录后续阶段未定位；未写生产 | 安全恢复候选与客户端分阶段证据 |

故障修复需先有可复现失败测试，再实施并按移动交付工作流验证；没有真实测试账号时由用户自行输入，不索取凭据。
