# 2026-09-19 分支合并盘点 + Android 0.3.99/2139 发布 + iOS 2139 待签交付

## 分支合并盘点

main（`cd18e8b1`）已包含全部近期工作，三个 20260919 分支均为 main 祖先
（`git rev-list main..branch` 均为 0，无需再合并）：
- `codex/direct-conversation-auto-recovery-20260919`（=main 同点）
- `codex/retired-direct-room-repair-20260919`（behind 3，已被 main 收编）
- `codex/conversation-reliability-20260919`（behind 7，已被 main 收编）

用户点名的关键修复确认在 main：
- **红包金额上限**：BUG-41 单个红包上限 200.00 点钻（前后端统一），
  commit `340b6175`（缺陷批次 A-C），另有 `457896c4`/`7afbc985` 红包 UX 修复；
- **会话类修复**：弱网发送恢复、拉黑双投影+忽略列表同步、失败消息按原位恢复、
  通话气泡回拨（`340b6175`）、私聊目的地预解析（`6aca8636`）、退役私聊修复与
  fenced generation（`742bf4eb`/`c7534a33`）、会话统一入口与身份回归
  （`8051edb5`/`e5a85093`）、L07/L04（`suspend` 必达关闭 + device 轮换采纳）。

## Android 0.3.99/2139 发布

- 版本 0.3.99+2139（`4da52382`，成对 bump 脚本，契约门禁 PASS）。
- 固定流程构建：ARM64 正式 + 三项 HTTPS dart-define + Apktool 2.12.1 +
  zipalign 36.0.0 + 固定证书 `75b31c66…`；aapt 验证
  `com.liuhetong.mobile` 2139 / 0.3.99 / arm64；语义验证通过。
- SHA256：`8C41244DDC292754F88D86E56C9CA0B8D2D0548C14405A77A2FA6FEDBEBF1614`。
- 分块上传 + 服务端合并 SHA 门一致 → 安装为
  `/opt/starchat/frontend/downloads/ChatFlow-0.3.99-build2139-arm64.apk`；
  `latest-arm64.apk` 切换；2137 及更早保留。
- 更新弹窗（trace `0.3.99-2139-20260919`，5 条审计）：0.3.99/2139，
  notes 指向弱网发送/拉黑/通话回拨修复与红包 200 点钻上限；iOS 行（0.3.96/2134）
  核对未改动。
- 公网验证：2139 与 latest 均 206 + 正确 MIME；2137 保留 200；未授权 401 存活。

## iOS 2139 待签交付

- GitHub Actions run `35451243196`（commit `4da52382`，0.3.99+2139）success；
  `ChatFlow-iOS-signed` 解包后 IPA 60,542,741 字节。
- 交付文件：`docs/verification/artifacts/2026-09-19/release-2139/ios/ChatFlow-0.3.99-build2139-for-enterprise-resign.ipa`
- SHA256：`0F564E8C76E761BB74EA7452AD48EC8C14FB1F2C044B2FABDCC3F2F75EB57F88`
- 包内核验：bundle id `com.liuhetong.liuhetongMobile`、0.3.99/2139、
  SQLCipher 在位、统计 HTML SHA 与 Android 包一致。
- 签名沿用同一企业描述文件（与 2085/2117/2120 相同，覆盖安装兼容）。
  签名回传核验后另行发布 manifest 与 iOS 设置（独立事务）。
