# 推送通道配置手册（Matrix Pusher + Sygnal + FCM/APNs）

**状态：** 客户端与服务端**代码/模板已就绪，凭据未配置，通道未激活。**
本文档列出全部缺失凭据与人工配置步骤。在凭据配置并验证前，
不得宣称"推送已接入"；**任何情况下不得把真实凭据提交进仓库**。

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
| 5 | 生产推送网关域名（如 `push.<域名>`）+ TLS 证书 | 客户端可达 Sygnal | 服务器 nginx（`data/nginx/nginx.conf` 增加 location 反代） |
| 6 | 生产部署授权 | 上线 Sygnal | 人工审批（本仓库规则：未经授权不得部署生产） |

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
5. 客户端构建注入网关地址：
   `--dart-define=LIUHETONG_SYGNAL_URL=https://push.<域名>`
   （`AppConfig.sygnalPushGatewayUrl`；未注入时不注册 pusher）。
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

开发环境：

1. `pwsh -NoProfile -File scripts/init_matrix.ps1` 会渲染
   `data/sygnal/sygnal.yaml`（apps 为空，无凭据可启动；仅日志报
   "no app found"）。
2. `docker compose up -d sygnal`。

生产环境（需部署授权）：

1. 服务器上编辑 `data/sygnal/sygnal.yaml`：取消 apps 注释并填入真实凭据
   （文件已被 .gitignore 的 `data/` 规则排除）。
2. `data/nginx/nginx.conf` 增加反代（示例）：
   ```nginx
   location /_matrix/push/v1/notify {
       proxy_pass http://sygnal:5000;
       proxy_set_header Host $host;
   }
   ```
3. `docker compose -f docker-compose.yml -f docker-compose.production.yml up -d sygnal`
   并 reload nginx。
4. 验证：`curl https://push.<域名>/_matrix/push/v1/notify -d '{}'`
   返回 Sygnal 的 4xx JSON（证明网关可达），而非 502。

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
