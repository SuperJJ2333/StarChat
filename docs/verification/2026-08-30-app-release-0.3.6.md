# App 发布 0.3.6+9 — 验证证据（2026-08-30）

发布内容：Emoji 显示与体验优化（超级表情 256px animated WebP + 消息展示发送者头像/昵称备注；225 枚 fluentui-emoji 矢量普通emoji + EmojiText 内联矢量渲染 + 表情面板 emoji 页签）。技术验证见 `docs/verification/2026-08-30-emoji-rendering-quality.md`（407 测试全过、analyze 无问题、verify.ps1 exit 0）。

## 版本与产物

| 项 | 值 |
| --- | --- |
| 版本 | 0.3.6+9（`apps/mobile_flutter/pubspec.yaml`） |
| 构建 | `pwsh scripts/build_mobile_public_domain.ps1`（Release、`--split-per-abi`、dart-define 指向 https://liuhetong888.com，签名配置 `android/key.properties` 校验通过） |
| arm64 | `ChatFlow-0.3.6-arm64.apk` 67,319,157 B，SHA256 `FF10AD0F2994174519284D87B85698378CA60580DC554161BBF074F0502BF350`（公开默认下载项） |
| arm32 | `ChatFlow-0.3.6-arm32.apk` 58,299,873 B，SHA256 `B716D41AA3AB21E76674D555204870A5E798515BA3B7D78E4BFF12D428340B50` |
| x86_64 | `ChatFlow-0.3.6-x86_64.apk` 71,269,095 B，SHA256 `76A9B50E4F56DCE6BC68D26983B16976300BBC5F779102F6E3EF247E8C836D00` |

## 发布步骤与确认

1. APK 上传至 `207.56.8.8:/opt/starchat/frontend/downloads/`（nginx `starchat-gateway-1` 以 `/usr/share/nginx/html` 静态服务该目录，即 `https://www.liuhetong888.com/downloads/`）。服务器端 `sha256sum` 与本地构建逐一比对**完全一致**。
2. 落地页 `frontend/home.html` 下载链接由 `ChatFlow-0.3.5-arm64.apk` 更新为 `ChatFlow-0.3.6-arm64.apk`，本地与服务器副本同步。
3. 应用内更新设置发布（脚本 `docs/verification/artifacts/2026-08-30/publish_app_update_0.3.6.py`，经管理端 RBAC 接口，幂等键 `app-update-publish-0.3.6-20260830`）：
   - `PUT /api/v1/admin/app-update-settings` → 200，`latest_version=0.3.6`、`latest_build=9`、`min_supported_build=3`、`apk_url=https://www.liuhetong888.com/downloads/ChatFlow-0.3.6-arm64.apk`；
   - 未认证客户端端点 `GET /api/v1/app-updates/latest` → `configured=true`，版本/构建/apk_url 与发布值一致，更新说明随接口下发。

## 外部验证（verify_public_domains.ps1）

`PASS` 全项：三域名 DNS、HTTP→HTTPS 308、www 落地页内容（含 0.3.6 下载链接）、**三个 APK 下载 URL 均 200**、Business API live/ready、`/_matrix/client/versions`、well-known、admin 域健康与页面。

真实内容抽测：`curl -r 0-3 https://www.liuhetong888.com/downloads/ChatFlow-0.3.6-arm64.apk` → HTTP 206，首 4 字节 `50 4B 03 04`（ZIP/APK 魔数），确认静态服务返回真实安装包字节。

## 回滚方式

- 更新提示回滚：以新的幂等键调用 `PUT /api/v1/admin/app-update-settings` 将 `latest_version/latest_build/apk_url` 写回 `0.3.5/8/.../ChatFlow-0.3.5-arm64.apk`（服务器仍保留 0.3.5 三个 APK）。
- 下载回滚：落地页链接与 downloads 目录内旧版本文件均在，可直接指回。
