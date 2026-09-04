# 推送通道配置手册（Matrix Pusher + Sygnal + FCM/APNs）

**状态（2026-09-04 更新）：** 客户端代码就绪；**Sygnal 网关已部署生产并
公网验证**（`https://liuhetong888.com/_matrix/push/v1/notify`，休眠态——
占位 pushkin 只记日志并拒绝投递）。**凭据仍未配置，推送投递未激活**：
在凭据配置并验证前，不得宣称"推送已接入"；**任何情况下不得把真实凭据
提交进仓库**。

- 实施计划：`docs/superpowers/plans/2026-09-04-background-notification-reliability.md`
- 客户端代码：`apps/mobile_flutter/lib/features/push/`
- 服务端模板：`infra/sygnal/sygnal.yaml.template`、`docker-compose*.yml`
- 背景与架构：`docs/NOTIFICATION_SYSTEM.md` §8/§9

---

## 1. 架构与 E2EE 边界

```text
Matrix 客户端 ──(pushers/set: kind=http, format=event_id_only)──▶ Synapse
Synapse ──(/_matrix/push/v1/notify)──▶ Sygnal 网关 ──▶ FCM（Android）/ APNs（iOS）
操作系统展示通用通知 ──点击──▶ 冷启动 App ── Matrix 同步 ── 本地解密 ── 进入会话
```

硬性边界（有自动化测试断言）：

- 客户端 pusher `data` 只含 `format=event_id_only` + 网关 URL；
- 客户端载荷解析白名单只有 `event_id/room_id/type/unread` 四个键，
  即使服务端误发正文/密钥字段也不读取（`push_tap_router_test.dart`）；
- homeserver 模板显式 `push.include_content: false`
  （`infra/synapse/homeserver.yaml.template`）；
- 后台兜底通知只显示通用文案（"你收到一条新消息"），不含正文。

## 2. 缺失凭据清单（人工获取）

| # | 凭据/资源 | 用途 | 存放位置（绝不入库） |
| --- | --- | --- | --- |
| 1 | Firebase 项目 + `google-services.json` | Android FCM 客户端初始化 | `apps/mobile_flutter/android/app/google-services.json`（.gitignore 已排除或需确认） |
| 2 | FCM v1 服务账号 JSON | Sygnal 向 FCM 发送 | 服务器 `data/sygnal/fcm-service-account.json` |
| 3 | Apple Developer 账号 + APNs Auth Key (.p8) + key_id + team_id | iOS 推送 | 服务器 `data/sygnal/apns/`；`.p8` 同时不入客户端仓库 |
| 4 | iOS 推送 entitlement 激活 | 客户端签名 | `apps/mobile_flutter/ios/Runner/Runner.entitlements`（由 `Runner.Push.entitlements.template` 复制；Xcode 勾选 Push Notifications capability） |
| 5 | ~~生产推送网关域名 + TLS~~ | **已解决**：复用主域名路径 `https://liuhetong888.com/_matrix/push/v1/notify`（nginx 更长前缀 location 覆盖 `/_matrix/`，2026-09-04 已部署生效） | — |
| 6 | ~~生产部署授权~~ | **已完成**（2026-09-04 用户授权；见 `docs/verification/2026-09-04-release-0.3.32.md`） | — |

## 3. Android（FCM）配置步骤

1. Firebase 控制台创建项目，包名 `com.liuhetong.mobile`。
2. 下载 `google-services.json` 放到 `apps/mobile_flutter/android/app/`。
   - 构建脚本已条件化：文件存在时才应用 `com.google.gms.google-services`
     插件（`android/app/build.gradle.kts`）；缺失时构建产物零变化。
   - 确认 `.gitignore` 排除该文件（含真实 API 元数据）。
3. 项目设置 → 服务账号 → 生成 JSON，保存为服务器上的
   `data/sygnal/fcm-service-account.json`。
4. 服务器 `data/sygnal/sygnal.yaml` 取消 `com.liuhetong.mobile.android`
   段注释并填 `fcm_service_account_file`。
5. 客户端构建注入网关地址（0.3.32 起发布构建已带）：
   `pwsh -File scripts/build_mobile_public_domain.ps1 -SygnalUrl https://liuhetong888.com`
   （编译进 `AppConfig.sygnalPushGatewayUrl`，运行时解析为
   `<url>/_matrix/push/v1/notify`；未注入的构建不注册 pusher）。
6. 验证：登录后 `adb logcat -s flutter | grep notif-diag` 应出现
   `pusher registered (format=event_id_only)`；杀进程后由另一账号发消息，
   系统通知应出现（通用文案），点击冷启动进入会话且不重复提醒。

## 4. iOS（APNs）配置步骤

1. Apple Developer → Identifiers → App ID 开启 Push Notifications。
2. 生成 APNs Auth Key（.p8），记录 key_id/team_id；`.p8` 只上服务器。
3. 客户端：
   - 复制 `ios/Runner.Push.entitlements.template` →
     `ios/Runner/Runner.entitlements`（开发构建 `aps-environment=development`，
     发布 `production`）；
   - Xcode：Runner target → Signing & Capabilities → 勾选
     Push Notifications（确认 Code Sign Entitlements 指向上述文件）；
   - `Info.plist` 已含 `UIBackgroundModes: remote-notification`（本仓库已做）。
4. 服务器 `sygnal.yaml` 取消 `com.liuhetong.mobile.ios` 段注释并填
   keyfile/key_id/team_id/platform。
5. 验证：TestFlight 或开发构建真机杀进程收推送（需 Mac 构建环境，
   Windows 开发机无法完成 iOS 签名验证——如实记录，不得标记完成）。

## 5. 服务端（Sygnal）部署步骤

> matrix-org/sygnal 已于 2025 年归档（最后版本 v0.15.1，本仓库固定该
> 版本镜像，禁用 latest）；它仍是 Matrix 参考推送网关。若未来更换实现，
> 必须保持 `/_matrix/push/v1/notify` 协议兼容并重做安全评审。

### 已完成（2026-09-04 生产部署记录）

- 镜像：`matrixdotorg/sygnal:v0.15.1`（Docker Hub；**ghcr.io 在生产服务器
  拉取被拒 "denied"**，故 .env.example 用 Docker Hub 源）。
- 容器：`starchat-sygnal-1`（compose 服务 `sygnal`，`restart: unless-stopped`）。
- nginx：`upstream sygnal_upstream`（`server sygnal:5000 resolve;`）+
  `location /_matrix/push/v1/notify`（更长前缀优先于 `/_matrix/`）。
  ⚠ 运维教训：**单文件 bind-mount 在 inode 替换（mv/sed -i）后仍指向旧
  内容**——改 nginx.conf 后必须 `docker restart starchat-gateway-1`
  （仅 `nginx -s reload` 不够）。
- 配置 schema：sygnal **v0.15.x** 为顶层 `log.setup`/`apps`/`http`（无
  数据库）；`http.bind_addresses` 必须显式 `["0.0.0.0"]`（默认只绑
  127.0.0.1，nginx 容器无法访问）；旧版 `sygnal: logging:` 嵌套写法会
  崩溃（"dictionary doesn't specify a version"）。
- 休眠态占位：v0.15.x 拒绝零 apps 启动，凭据到位前用
  `infra/sygnal/nooppushkin.py`（挂载进容器 sygnal 包路径）——收到 notify
  只记日志并拒绝 pushkey，不伪造投递。
- 公网验证：`POST https://liuhetong888.com/_matrix/push/v1/notify`（占位
  app_id）→ `200 {"rejected":["..."]}`；synapse/element/business-api/admin
  回归全部 200。

### 激活推送（凭据到位后）

1. 服务器编辑 `/opt/starchat/data/sygnal/sygnal.yaml`：删除
   `com.liuhetong.placeholder` 占位段，取消 `com.liuhetong.mobile.android`
   注释并填 `fcm_service_account_file: /data/fcm-service-account.json`
   （iOS 同理）。
2. `docker compose restart sygnal`（注意：若改动 compose 文件本身，
   用完整 `-f docker-compose.yml -f docker-compose.production.yml`）。
3. 验证：真实设备登录后 `adb logcat -s flutter | grep notif-diag` 出现
   `pusher registered (format=event_id_only)`；杀进程收消息出现系统通知。

### 开发环境

1. `pwsh -NoProfile -File scripts/init_matrix.ps1` 渲染
   `data/sygnal/sygnal.yaml` + `nooppushkin.py`（休眠态可启动）。
2. `docker compose up -d sygnal`。

## 6. 客户端行为摘要（已实现，无需凭据）

- 登录后 `_startPushIntegration`：解析 FCM → 注册 Matrix pusher
  （token 轮换自动重注册）→ 挂载点击路由。
- 登出/账号切换：`deletePusher` + 丢弃挂起点击路由（不跨账号串会话）。
- 冷启动：通知点击（FCM initial message 或本地通知 launch details）→
  eventId 先入持久去重 → 会话就绪（含等待首次同步带回房间）→ 进入会话。
- Android 后台/被杀：`onBackgroundPushMessage` 展示通用通知（消息）或
  heads-up 通知（来电信令兜底）；点击冷启动走上述路由。
- FCM 凭据缺失时：`FirebasePushTokenProvider.tryCreate` 返回 null →
  Noop 降级（不注册 pusher），诊断留痕；Matrix 同步通道照常。

## 7. 来电推送设计（独立后续工作，本期未实现）

- **Android**：来电信令（`m.call.*`）经 FCM **高优先级** data 消息唤醒
  （Sygnal 按 `prio: high` 透传）；进程存活时主 isolate 的 Matrix 同步
  触发既有全屏来电通知；进程被杀时后台 isolate 展示 heads-up 兜底通知。
  合规目标形态为 `Notification.CallStyle`（需在前台服务内构建 + 用户
  主动授权），属后续迭代。
- **iOS**：必须使用 **PushKit（VoIP push）+ CallKit**——Apple 要求收到
  VoIP 推送必须立即上报 CallKit，否则 APNs 证书会被吊销；**不得**用普通
  APNs 消息推送冒充 VoIP 推送。需要：独立 VoIP 证书、
  `UIBackgroundModes: voip`、PushKit registry、CallKit provider 配置、
  以及 Sygnal 侧 `apns-push-type: voip` 的 app 配置。全部依赖 Apple
  Developer 凭据与 Mac 构建环境，未具备前不实现、不宣称。

## 8. 回滚

- 客户端：不注入 `LIUHETONG_SYGNAL_URL` 构建（或移除
  `google-services.json`）→ pusher 不注册、FCM 不初始化，行为等同 0.3.30；
- 服务端：`docker compose stop sygnal` 并移除 nginx location；客户端
  pusher 已注册时会收到网关 5xx，Matrix 同步通道不受影响；重新配置后
  客户端下次登录自动重注册。
