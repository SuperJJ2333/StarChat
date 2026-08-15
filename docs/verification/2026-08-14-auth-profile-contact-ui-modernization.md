# 认证、资料与通讯录现代化验收记录

- 日期：2026-08-15（Asia/Hong_Kong）
- 分支：`feature/auth-profile-contact-ui-modernization`
- 计划：`docs/superpowers/plans/2026-08-14-auth-profile-contact-ui-modernization.md`
- 规格：`docs/superpowers/specs/2026-08-14-auth-profile-contact-ui-modernization-design.md`
- ADR：`docs/adr/0004-business-auth-matrix-login-token.md`

## 1. 基础设施

执行：

```text
docker compose build business-api business-worker exit 0
docker compose up -d                         exit 0
docker ps -a                                 exit 0
docker compose ps                            exit 0
GET http://127.0.0.1:8082/api/v1/health/live  200
GET http://127.0.0.1:8082/api/v1/health/ready 200
GET http://127.0.0.1:8008/_matrix/client/versions 200
GET http://127.0.0.1:8025/api/v1/info          200
GET http://127.0.0.1:8081/health               200, matrix_ready=true
```

健康服务：Business PostgreSQL、Redis、Business API、Worker、Synapse PostgreSQL、Synapse、Matrix Bot、Mailpit、Coturn 与 Element Web 均为 `Up`；声明 healthcheck 的服务均为 `healthy`。本机已有进程占用 8080，因此仅在未跟踪的 `.env` 中将 Element 验收端口改为 8083。

宿主机入口：

| 服务 | 地址 |
| --- | --- |
| Business API | `http://127.0.0.1:8082` |
| Synapse Client API | `http://127.0.0.1:8008` |
| Matrix Bot health | `http://127.0.0.1:8081/health` |
| Mailpit Web/API | `http://127.0.0.1:8025` |
| Mailpit SMTP | `127.0.0.1:1025` |
| Coturn | 宿主机 LAN IP 的 `3478/tcp+udp`、`49160-49200/udp` |

Synapse PostgreSQL 使用 `C` locale 和 UTF-8 重新初始化。原非兼容 locale 数据目录未删除，隔离为忽略目录 `data/postgres-bad-locale-20260815111246`，可用于恢复审计。

## 2. 自动验证与构建

| 命令 | 结果 |
| --- | --- |
| `py -3.12 -m pytest tests/business_api tests/business_worker -q`（同时设置 API/Worker `PYTHONPATH`） | `161 passed, 1 skipped`，exit 0 |
| `py -3.12 -m pytest tests/matrix_bot -q` | `9 passed`，exit 0 |
| `pwsh -NoProfile -File scripts/verify.ps1` | Repository/Deployment policy、模板、配置渲染、Matrix Bot、Business API/Worker、Flutter boundary、导入、AST、迁移、OpenAPI drift、Compose render 全部 PASS；exit 0 |
| `flutter analyze` | `No issues found`，exit 0 |
| `flutter test` | `80 passed`，exit 0 |
| `flutter build apk --release` | 成功，116.8 MB，exit 0 |
| `tests/mobile/test_ios_simulator_ci.py`（包含于 verify） | PR `macos-14` simulator job、analyze/test、`flutter build ios --simulator --no-codesign` 静态边界通过 |

Android release：

```text
apps/mobile_flutter/build/app/outputs/flutter-apk/app-release.apk
SHA-256 59EB86FECB2FD715A8EF8327DBCA33D55741781099F59F04C8A472894D0ABED8
```

OpenAPI 已重新导出至 `packages/api-contracts/openapi/liuhetong-v1.yaml`，包含浏览器验证页和 link POST 端点；漂移检查通过。

## 3. TDD 与真实回归中发现的缺陷

以下缺陷均先以失败测试或真实复现确认，再进行最小修复并回归：

1. Synapse PostgreSQL 非 `C` locale 无法启动：增加 Compose 初始化参数和静态测试。
2. Synapse 注册脚本 CRLF、Bot 被误注册为管理员：强制 shell LF，Bot 使用 `--no-admin`。
3. Matrix Bot homeserver 尾斜线产生 `//_matrix/...` 404：设置入口规范化 URL。
4. PostgreSQL 注册时 User 未 flush 导致邮箱 challenge FK 失败：在创建 challenge 前 `session.flush()`。
5. Pydantic 2.13 将 Matrix Token TTL 环境变量字符串交给 `Literal` 前未转换：增加 before validator。
6. 邮件链接原 query 形式会进入访问日志且无法完成验证：改为 `#token=...`，浏览器以 JSON body POST；补齐单次消费路径。
7. Android WebRTC 缺少 `ACCESS_NETWORK_STATE`：补 manifest 和静态测试。
8. Android 头像裁剪缺少 `UCropActivity`/主题：补 manifest、values 与 API 35 资源。
9. Matrix 被叫端没有本地 `m.direct` account data 时错误拒绝安全双人房：改为验证加密、已加入且参与者集合严格等于本机与对端 MXID；补安全边界测试。
10. 现代“我”页一度使彩币、红包和钱包失去入口：恢复白底图文入口并补 widget 导航测试。
11. 双域显式登录可能复用上一账号的 Matrix 会话：登录前清理 Matrix，任何失败同时清理两域，并以 Business 权威 MXID 校验绑定。
12. Production 缺少 Matrix provision secret 时会回退开发值：API 与 Worker 均改为 fail closed，并拒绝公开开发 secret。
13. 不同联系人共享 Direct Chat in-flight future：改为按 MXID 隔离并再次校验目标参与者集合。
14. 邮件重发后旧 link、客户端网络丢响应幂等、Outbox worker 崩溃租约、好友申请 payload 重放分别补失败测试并修复。
15. Logout/device revoke 后已签发 access token 仍可使用：access token 每次校验权威用户、设备与 refresh family 状态。
16. 头像内容响应补 `no-store`、`nosniff`、referrer policy；公开认证限流键改为 IP 与 subject 的哈希组合；OpenAPI 补 bearer security 与头像 binary body。
17. 双 AVD 无法直连且仓库缺 TURN：加入固定版本 Coturn、Synapse 临时凭证配置及显式外部中继地址。`10.0.2.2` 不产生可用 ICE relay 后，以宿主机 LAN IP 复现并确认语音、视频均达到 `CallState.kConnected`。
18. 视频通话在紧凑屏幕溢出：先增加 compact-device 边界测试，再将 RTC surface 改为受限弹性布局；真实双端复测无 overflow。

## 4. 双模拟器真实验收

设备：

- `emulator-5554`：`ASUS_AI2501_A`，Android 9 / API 28。
- `emulator-5556`：`2509FPN0BC`，Android 9 / API 28。

运行时凭证仅存于本机临时 JSON，验收后已删除；`.env`、数据库、媒体目录和构建目录均未纳入 Git。

### 注册、验证与双域会话

- 使用两个不同的新邀请码分别注册 `liuhetong_test01`、`liuhetong_test02`。
- 用户 01 从 Mailpit 邮件使用六位 code；用户 02 从 Mailpit 邮件使用 fragment link，并由浏览器页面 POST 完成验证。
- 两个 Business 用户最终均为 `ACTIVE` 且持久化稳定 `matrix_user_id`；Matrix 自动开户和一次性登录 Token 登录成功。
- 两端强制停止并重新启动 APP 后均恢复 Business + Matrix 会话，无需重新登录。
- 验收收尾撤销两个测试用户全部 refresh family 并强制停止 APP；不保留活动 Business 会话。

### 通讯录、资料与 E2EE

- 用户 01 发起好友申请、用户 02 接受；数据库存在唯一 friendship。
- 用户 01 将备注设为 `friend-two`，朋友圈权限设为 `HIDE_THEIRS`；通讯录和好友主页不显示 Business UUID。
- 创建并复用唯一双人加密 Direct Room；两端发送和解密消息。Synapse 证据为 `m.room.encryption=1`、`m.room.encrypted=20`、目标加密房间 `m.room.message=0`。
- 头像经过系统相册、UCrop 正方形裁剪、预览和确认上传；用户 01 的私有 `avatar_object_key` 已写入，客户端仅收到签名读取 URL。
- “我”页资料、默认头像、彩币、红包、钱包、设置与退出入口均可达。

### 语音与视频

- 语音：用户 01 从加密双人房发起，用户 02 真实呼入并接听；两端依次进入 `kConnecting` 和 `kConnected`，Coturn 记录双方临时用户名的 `ALLOCATE`、`CREATE_PERMISSION` 与 `CHANNEL_BIND` 成功。
- 视频：用户 01 发起、用户 02 接听；两端 WebRTC 均达到 `CONNECTED`/`CallState.kConnected`，本地/远端 `RTCVideoView` 同屏显示，紧凑屏幕无 overflow。
- Matrix call invite/candidate/hangup 信令均以 `m.room.encrypted` 事件发送；Business API、日志和数据库不接触媒体、SDP 或房间密钥。
- 两个 Android AVD 位于隔离且地址重叠的虚拟 NAT，使用 Coturn 中继穿透；Synapse 动态签发 1 小时凭证，媒体仍由 WebRTC 端到端加密，TURN 只转发密文包。

### 离线与视觉

- 移除 Business API 的 `adb reverse` 后重启，页面主体和 Tab 位置不变，顶部出现“网络不可用，点击重试”胶囊。
- 恢复 reverse 并点击重试后胶囊消失，会话与页面保留。
- 明暗模式截图覆盖登录、注册、好友/通讯录、“我”、朋友圈、彩币、红包、钱包、头像、E2EE、语音/视频和离线恢复。

截图索引：`docs/verification/screenshots/2026-08-14-auth-profile-contact-ui-modernization/`。

## 5. Domain Review

| 检查项 | 结论与证据 |
| --- | --- |
| Business/Matrix 身份绑定 | PASS。Matrix Token 目标只来自 access token `sub` 对应的权威用户记录；显式登录不复用旧 Matrix 身份，显式鉴权失败清理两域、网络失败保留 Business 会话，绑定必须匹配稳定 MXID，迁移态缺失 MXID 时 fail closed。 |
| Token 单次/过期 | PASS。真实 Synapse 登录 Token 验收结果为首次 `200`、重放 `403`、过期 `403`；验证码/link、refresh rotation 另有单次/过期测试。 |
| Outbox 幂等 | PASS。邮件、Matrix provision、Matrix profile sync 只发布内部 ID/稳定键；注册重放不重复消耗邀请码或开户；超过 5 分钟的 `PROCESSING` 租约可重领。 |
| 头像访问控制 | PASS。私有对象键不出 API，读取 URL 5 分钟签名，过期/篡改/删除拒绝；裁剪上传真实通过。 |
| Direct Chat E2EE | PASS。只允许已加入、已加密、严格两成员房间；无明文消息事件；Business 域不接触正文/密钥。 |
| WebRTC 媒体边界 | PASS。通话只从验证后的加密双人房发起；双 AVD 语音/视频均经 Coturn 达到 connected；Business API、审计与日志不接触媒体或密钥。 |
| 回滚/恢复 | PASS。Business PostgreSQL `pg_dump`/`pg_restore` 后 2 个用户一致；私有媒体复制恢复后 1 个对象哈希一致；迁移为扩展式，主动退出即时撤销 access/refresh family。 |

Domain Review：无 Critical/Important 未解决项。

## 6. Quality / Security Review

| 检查项 | 结论与证据 |
| --- | --- |
| 日志脱敏 | PASS。邮件 Token 使用 fragment，SMTP/Matrix 错误稳定脱敏；Outbox 无 code/token/password；未把测试凭证写入证据或 Git。 |
| 权限拒绝 | PASS。相机/麦克风拒绝在发信令前终止；被叫拒权时拒接；Android/iOS usage declarations 和 Android network permission 均有静态测试。 |
| 最小权限 | PASS。Matrix Bot 使用普通账户；Business API 管理 Token 只用于开户/一次性 Token，不返回或记录。 |
| 配置与供应链 | PASS。Compose 生产镜像有显式版本/摘要；Production 强制 HTTPS、TLS SMTP、所有权威签名/管理 secret 与 TURN secret 均拒绝公开占位值；Coturn 外部地址必填；OpenAPI、runbook 与 CI 同步。 |
| UI/可访问性边界 | PASS。现代白底图文按钮、危险操作样式、沉浸认证、稳定语义标签、离线 Overlay 均有 widget/static tests 和明暗截图。 |
| 代码质量 | PASS。Python AST、迁移、OpenAPI、Flutter analyze、完整测试与 Android release 全部 exit 0；`git diff --check` 无 whitespace error。 |

Quality/Security Review：无 Critical/Important 未解决项。

## 7. 非阻塞环境限制

1. 当前主机为 Windows，未安装 Xcode，且仓库没有 Git remote/`gh`，因此无法在本机会话实际启动 macOS GitHub Actions。PR 触发的 `macos-14` unsigned simulator job 已实现并由静态测试锁定；首次推送 PR 时必须以该 job 的绿色结果作为合并门禁。
2. Flutter 3.44.9 对 `flutter_olm`、`flutter_openssl_crypto`、`flutter_webrtc` 输出未来 Built-in Kotlin 迁移提示；当前 release 构建成功，不是失败或被忽略的 warning，后续依赖升级时处理。
