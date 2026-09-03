# 邀请码统一 + 0.3.27 发布实施计划

**状态：** 已批准
**日期：** 2026-09-03
**依据：** 用户指令（2026-09-03）：① 向现有 App 用户推送新版本更新弹窗；② 统一"邀请码/好友邀请码"为单一注册邀请码体系。

## 任务 A：发布 0.3.27（更新弹窗推送）

更新弹窗链路已存在且经 0.3.26 验证：客户端启动比对 `GET /api/v1/app-updates/latest` 的 `latest_build`（归一化 `build % 1000`）→ 弹「发现新版本」→ apk_url 下载安装。本次为常规发布：

1. `pubspec.yaml` 与 `app_config.dart` 契约常量 → 0.3.27+30（`tests/mobile/test_app_build_contract.py` 校验同步）。
2. 构建 `flutter build apk --release --flavor standard --split-per-abi`（versionCode 2030/1030/4030；AppConfig 默认即生产地址）。
3. 发布（SSH `root@207.56.8.8:23421`）：上传 3 APK 至 `/opt/starchat/frontend/downloads/`、SHA256 比对、`latest-*.apk` 别名刷新、容器内发布脚本（幂等键 `app-update-publish-0.3.27-20260903`，`latest_build=2030`）、端到端验证。
4. 回滚：`PUT /api/v1/admin/app-update-settings` 写回 0.3.26/2029。

## 任务 B：邀请码统一

**现状**：注册页「邀请码」（管理员 Invitation，必填）+「好友邀请码」（30 分钟轮换 referral 码，选填）两字段；「我」页展示轮换 referral 码。

**方案**（复用 Invitation 全链路，无新表无迁移）：

1. 服务端 `GET /api/v1/invitations/mine`（鉴权）：`HMAC(referral_secret, "personal-invite:{user_id}")` 派生**固定** 8 位码（32 字母表），upsert `invitations`（`created_by=user`；`max_uses` 默认 20 / 有效期滚动 365 天，env 可配）；返回 code/max_uses/use_count/share_url。经现有 validate/consume 链路生效（哈希兼容：`sha256(upper(code))` 两处一致）。
2. 注册：`consume_in_session` 后若 Invitation.created_by 为 ACTIVE 用户且非本人 → 写 `referral_bindings`（邀请关系由"注册消耗了谁的邀请码"推导）；旧客户端 `referral_code` 参数继续兼容。
3. 轮换 referral 端点保留（旧版兼容），新客户端不再调用。
4. 客户端：注册页删除好友邀请码字段；「我」→ 邀请码页改固定码展示（去倒计时轮换）+ 剩余次数 + 分享。
5. 规格 §6.2 同步：邀请码 = 管理员签发 + 每用户固定个人注册邀请码；取消独立好友邀请码双轨。
6. 测试：mine 端点（鉴权/幂等/哈希兼容/防自邀）、注册绑定推导、旧参数兼容、注册页单字段、邀请码页静态控制器；OpenAPI 重生成。

## 顺序

任务 B 代码+测试 → 全量门禁 → 0.3.27 构建 → 服务器发布（APK + business-api 容器，无迁移）→ Mi 6 验证。
