# 邀请码（referral）API 与安全性说明

**日期**：2026-09-02　**关联计划**：`docs/superpowers/plans/2026-09-02-media-video-invite-image-optimization.md`
**契约**：`packages/api-contracts/openapi/liuhetong-v1.yaml`（`/invitations/referral*`）

## 端点

| 方法/路径 | 鉴权 | 限流 | 说明 |
| --- | --- | --- | --- |
| `GET /api/v1/invitations/referral` | Bearer | 200 次/30 分钟/用户 | 返回当前窗口码 `{code, rotates_at, rotates_in_seconds, share_url, reward_enabled}`；调用即发布/滚动更新当前窗口码 |
| `POST /api/v1/invitations/referral/validate` | 公开 | IP+码 10/60s；IP 30/3600s | `{referral_code}` → `{valid}`；不回显邀请人（防枚举） |
| `POST /api/v1/auth/register` | 公开（既有） | 既有 3/3600s | 新增选填 `referral_code`；有效则同事务写入 `referral_bindings`，无效**不阻断注册**（管理员邀请码仍是硬门槛） |

## 轮换与安全设计

- 码 = `HMAC-SHA256(BUSINESS_REFERRAL_CODE_SECRET, "{user_id}:{window_index}")` 截断 8 位，
  32 字符无易混字表（无 0/O/1/I/L），`window_index = epoch // 1800`。
- **旧码立即失效**：校验按服务端当前时间窗口比对 `referral_invites.window_index`，跨窗即拒。
- **防伪造/防枚举**：码空间 ≈2^40 + 双层限流；明文码不落库不落日志（仅 sha256）。
- **防重放/防重复绑定**：`referral_bindings.invited_user_id` UNIQUE + 注册幂等键（幂等 payload 已含
  `referral_code`）。
- **规模（≥10000 人）**：校验路径 = 1 次 Redis 限流 + 1 次 `code_hash` 唯一索引命中，无全表扫描；
  1000 次校验实测 <1s（单次 « 200ms），见 `tests/business_api/identity/test_referral_api.py`。
- **奖励**：`BUSINESS_REFERRAL_REWARD_ENABLED=false`，绑定记录 `reward_state=NOT_CONFIGURED`。
  涉及账本的资金奖励属受保护变更，须先过 ADR + 双评审（AGENTS.md），当前实现不发资金。

## 配置（.env）

```
BUSINESS_REFERRAL_CODE_SECRET=<强随机，生产必填>
BUSINESS_REFERRAL_ROTATION_SECONDS=1800
BUSINESS_REFERRAL_SHARE_BASE_URL=https://example.com/register
BUSINESS_REFERRAL_REWARD_ENABLED=false
```

## 数据库（迁移 0034，expand-only，幂等）

- `referral_invites`：user_id PK、`code_hash` UNIQUE（反查邀请人）、window_index、updated_at。
- `referral_bindings`：id PK、inviter_user_id（索引）、invited_user_id UNIQUE、code_hash、
  code_window_index、status、reward_state、bound_at、created_at。

## 客户端（Flutter）

- 入口：「我」→「邀请码」（`profile-invite-entry`），打开即取码，页面显示 **mm:ss 后自动更新** 倒计时，
  到点自动重新拉取（服务端旧码失效时客户端同步获得新码）；导航栏另有手动刷新。
- 分享：复制邀请码 / 复制邀请链接 / 保存分享图片（卡片渲染 PNG 存相册）/ 跳转微信（`weixin://`）/
  跳转 QQ（`mqq://`）；未安装对应应用时回退为「邀请码已复制，可直接粘贴发送」。
- 注册页新增选填「好友邀请码（选填）」：填写时先公开校验，无效给字段级提示且不提交；留空跳过。
