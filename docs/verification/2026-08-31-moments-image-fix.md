# 带图朋友圈无法显示 — 根因与修复证据（2026-08-31）

发布形式：**服务端热修复（无 APK 版本）**——修复部署即对所有客户端版本生效。

## 复现（生产端到端）

以超管会话对生产执行 上传媒体 → 发布带图动态 → 拉取 feed：
- 上传（begin/PUT/complete）201/204/200 ✓，发布 201 ✓
- **`FEED_HAS_ITEM False`** —— feed 中不存在刚发布的带图动态（问题实锤）

## 根因（两层叠加）

1. **审核队列无放行流程**：`moments/service.py` 发布时
   `status = "PENDING_REVIEW" if image_urls else "PUBLISHED"` —— 带图动态被置为
   待审核，而 feed/detail 只显示 `PUBLISHED`；系统不存在任何审核放行端点，
   带图动态等于永久不可见。
2. **媒体短签 URL 被持久化**：上传完成时签发的媒体 URL 仅 **300 秒有效**
   （`signed_read_url(..., 300)`）且原样入库；feed 原样返回 → 即使动态可见，
   图片也会在 5 分钟后全部失效。

## 修复（服务端，均已部署生产）

| 文件 | 改动 |
| --- | --- |
| `moments/service.py` | 带图与纯文字一致直接 `PUBLISHED`；feed DTO 输出 `image_urls` 时**动态重签为 7 天（604800s）**；朋友圈封面同步改长签 |
| `integrations/private_storage.py` | 新增 `resign_read_url(token, ttl)`：无时效解密既有令牌并按新 TTL 重签（**救活历史已过期的入库链接**）；`read_signed` 放行长 TTL（300 兼容保留） |

安全说明：签名密钥与令牌机制不变；resign 仅对自家令牌解密重签，解密失败原样返回；
内容安全依赖既有举报通道（`POST /moments/{id}/reports`）。

## 测试

- 反转旧契约测试为 `test_create_with_images_publishes_immediately_and_shows_in_feed`
  （带图直接 PUBLISHED + 出现在好友 feed + image_urls 正确）；
- 新增 `test_feed_resigns_moment_media_urls_to_long_ttl`（feed 必须以 7 天 TTL 重签、
  令牌透传）；`test_storage_resign_recovers_expired_tokens`（存储层无 TTL 解密救活过期令牌）；
- moments 套件 **12 passed**。

## 生产部署与验证

- `moments/service.py` + `integrations/private_storage.py` 双路径同步，
  `business-api` 镜像重建重启，`health/ready` OK。
- 部署后端到端复验：发布带图动态 → `FEED_HAS_ITEM True`、`STATUS PUBLISHED`、
  feed `image_urls` 为 `expires_in=604800` 的重签链接；**匿名 GET 该 URL 返回 200
  与真实 JPEG 字节**——图片可正常展示。
- 复现过程产生的 3 条测试动态已从生产清理（204）。

## 关于“更新推送”

本次为**纯服务端修复，已部署生效，无需发新 APK**：所有现有版本的客户端拉取
feed 时即可正常显示带图朋友圈（发布与展示链路的协议未变）。
