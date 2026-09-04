# TURN 服务与通话网络兜底

关联：`docs/verification/2026-09-04-release-0.3.33.md`（部署记录）、
`docs/NOTIFICATION_SYSTEM.md`（通话质量日志 `chatflow/callquality`）。

## 1. 生产现状（2026-09-04 部署/修复）

| 项 | 状态 |
| --- | --- |
| coturn 容器 | `starchat-coturn-1`（coturn/coturn:4.6.3-r3），3478 udp/tcp + 49160-49200/udp 对公网开放 |
| **turn_uris 修复** | 修复前 homeserver.yaml 仍是过期的 `turn:192.168.1.116:3478`（手机不可达的内网地址）——**生产 TURN 从未可用**；现已改为 `turn:liuhetong888.com:3478?transport=udp/tcp` + `turns:liuhetong888.com:5349?transport=tcp` |
| **turn_shared_secret 修复** | homeserver 内残留 dev 密钥（36 位）与 coturn 实际使用的 .env 密钥（64 位）不一致——TURN 认证必然失败；已同步（备份 `homeserver.yaml.bak-secret-fix`） |
| TLS 5349 | coturn 已挂载 nginx 证书启用（SAN 含 liuhetong888.com，与 URI 主机名匹配）；主机 ufw 已放行 5349/tcp+udp；**托管商安全组尚未放行**（服务器自连公网 IP 5349 被拒，过滤在上游） |
| 防火墙（ufw） | 已放行 5349/tcp+udp（注释 coturn TLS）；既有 3478/49160-49200 不变 |

## 2. 待人工完成项（不得标完成）

1. **托管商安全组放行 5349/tcp + 5349/udp**（我无控制台权限；放行后
   turns URI 立即生效，无需再改服务端）。验证：
   `openssl s_client -connect liuhetong888.com:5349` 出现证书即通。
2. **TCP-443 TURN（可选进阶）**：宿主 443/tcp 已被 nginx 网关占用、
   443/udp 被 QUIC 服务占用。若确需 443 兜底：需新增 `turn.<域名>` DNS
   记录 + 该主机名证书 + nginx stream 模块按 SNI 分流（443 归 stream，
   web 转内部端口）。涉及生产网关重构与 DNS/证书签发，独立评审后实施。

## 3. 客户端行为

- 无客户端改动：Matrix SDK 从 `/voip/turnServer` 拉取 homeserver 下发的
  URIs 并透传给 libwebrtc（`turns:` 原生支持）。
- 通话质量日志（0.3.33 起）：`chatflow/callquality` 汇总含
  `turn=used/not-used`（getStats 候选类型判定 relay）——真机验证 TURN
  是否实际启用看这一行。

## 4. 双机真机测试矩阵（人工执行，覆盖 Wi-Fi/4G/5G/跨运营商）

每格记录：通话是否接通 / `chatflow/calldiag` sent→ice 耗时 /
`chatflow/callquality` 的 turn= 与 rtt/jitter/丢包。

| 场景 | 机型 A（网络 1） | 机型 B（网络 2） | 预期 |
| --- | --- | --- | --- |
| 同 Wi-Fi | 任意 | 同一 Wi-Fi | host 直连，turn=not-used，RTT 低 |
| 跨 Wi-Fi（不同 NAT） | Wi-Fi A | Wi-Fi B | srflx 打洞或 turn=used |
| Wi-Fi ↔ 4G/5G | Wi-Fi | 蜂网 | 常见 turn=used |
| 跨运营商蜂窝 | 移动 5G | 电信/联通 4G/5G | 大概率 turn=used（CGNAT） |
| 企业网（仅 443 出站） | 任意 | 受限网络 | 3478 阻断 → turns:5349 兜底（需 §2.1 放行后验证） |
| 弱网 | 限速/丢包注入 | 正常 | 观察丢包率与 jitter 汇总 |

日志抓取：`adb logcat -s flutter | grep -aE "calldiag|callquality"`。
