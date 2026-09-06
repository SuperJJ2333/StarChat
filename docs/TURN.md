# TURN 服务与通话网络兜底

## 2026-09-05 已验证修复（优先于下方历史记录）

实测 TLS 失败根因是 coturn 的 nobody:nogroup 用户无法读取 nginx 的 root:root 0600 私钥，TLS 监听未启动。此前根据宿主端口结果推断“托管商安全组阻断”并不准确。

生产已将 coturn 挂载切换到独立 `data/coturn/certs`，使用 root:65534 0750 目录、0640 私钥；nginx 原私钥仍为 0600。同步工具 `scripts/sync_turn_certificates.py` 校验配对后发布；Certbot 域名限定钩子 `scripts/renew_turn_certificates.sh` 安装为 `zz-starchat-turn.sh`，续期成功同步后只重启 coturn。

公网定向复测 UDP/TCP/TLS 全部认证、中继成功：分配约 158/162/360 ms，中继往返约 154 ms。九次强制 relay 的真实 WebRTC 数据通道测试全部通过，建立用时 770–1019 ms。该结果来自 Windows 测试路径，不能替代双真机/跨运营商音视频测试或饱和带宽测量。

客户端原 Matrix 0.34.0 SDK 不刷新 TURN 临时凭证（生产 TTL=3600 秒）。`RefreshingTurnVoIP` 仅覆盖公开 discovery 方法：账号内存缓存按 TTL 提前刷新、最多缓存五分钟、合并并发、预热及三秒超时；未修改 Matrix 信令或媒体加密路径。

当前无需继续“放行 5349”的旧待办：TLS 主机名/证书及外部认证测试均已通过。443 TURN 仍属于可选新节点/网关设计，未实施。

证据：`docs/verification/artifacts/2026-09-05/call-connection/`。

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
- **2026-09-04 诊断扩展**（远距离通话卡顿排查）：summary 追加
  - `codec=`：收流编解码器（如 `audio/opus`、`video/VP8`；VP8/H264
    互操作问题、音频 OPUS 降级可见）；
  - `availOut=<kbps>`：candidate-pair `availableOutgoingBitrate` 均值
    （可用出站带宽估算；中继带宽上限问题直接可见）；
  - `conceal=<n>`：音频隐藏事件峰值（`concealmentEvents`，丢包补偿
    触发次数——"听得见但断续/机器人声"的量化指标）；
  - ICE 状态进入抽样（`iceState`，pair `state`）。
  实现：`apps/mobile_flutter/lib/features/matrix/call_quality_monitor.dart`
  （解析为纯函数，测试 `test/features/matrix/call_quality_and_gate_test.dart`）。

### 3.1 服务器核验（2026-09-04，本次五联修）

- coturn 容器 `starchat-coturn-1` Up，主机 3478/5349 tcp+udp 均在监听；
- homeserver `turn_uris` 三条与 §1 一致（render_config `--check`：
  NO DRIFT）；
- **公网实测**：3478/tcp 可达 ✅；**5349/tcp 仍不可达** ❌——托管商
  安全组仍未放行（§2.1 待人工），公网 `turns:` 兜底当前不可用，
  3478/udp（非 TLS）中继可用。

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
