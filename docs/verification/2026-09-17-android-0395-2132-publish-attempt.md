# 0.3.95 / 2132 更新弹窗发布：本次尝试与阻断证据（**未执行任何生产写入**）

- 日期：2026-09-17（Asia/Hong_Kong）
- 用户指令：「请你推送 Android 版的更新弹窗」。
- 结论：**无法执行**。生产 SSH（跳板机与目标机两条路径）均无 banner 应答，
  而本发布必须先经 SSH 上传不可变 APK，才允许发布弹窗设置。
- 前置事实：另一条工作流已完成 **本地构建 + 全部门禁 + GitHub 推送**，并已写好三个发布脚本；
  其记录见 [0.3.95/2132 发布记录](2026-09-17-android-0395-2132-release.md)。本次只做**独立复核与探测**，未做写入。

## 1. 独立复核（本次实测）

| 项 | 实测值 |
| --- | --- |
| 线上发布状态 | **仍是 0.3.94 / 2129**（弹窗未更新） |
| 交付候选文件 | `artifacts/2026-09-17/release-2132/delivery-ChatFlow-0.3.95-build2132-arm64.apk` |
| 候选 SHA256（本次独立计算） | `35CA0962E9DDB3655474B2BCC5182DFCEB52D57549020C8680FC2E4BE3374633`，79,801,374 字节 |
| 与记录是否一致 | **一致**（发布记录第 2 节所载最终交付 SHA 相同） |
| 版本占用核对 | `pubspec.yaml` 与 `lib/core/app_config.dart` 均为 `0.3.95+2132`（commit `9fa2c963`），
  高于线上 2129 与已装 Mi 6 的 debug 2131；**该版本号已被本任务占用，无需重新 bump** |
| 候选 commit | `9fa2c963`（父 `82b24ba7`）；该工作流记录构建前后 `git status --short` 均为 0 项 |
| GitHub | `origin/main == main == 5e39bf3a`，`origin/main...main` = `0 0` |

## 2. 阻断证据（本次实测，与既有记录一致）

| 探测 | 命令 | 结果 |
| --- | --- | --- |
| 跳板机 SSH（默认路径） | `scripts/starchat-server.ps1 -Action Probe` | exit 255，`Connection closed by UNKNOWN port 65535` |
| 跳板机 SSH 重试 ×3（间隔 10s） | `ssh -o ConnectTimeout=15 jumper true` | ①`Connection timed out during banner exchange` ②同① ③`Connection closed by 8.163.93.151 port 22` |
| 跳板机原始 banner | `TcpClient` 连 8.163.93.151:22 后读 128B | **`jumper_banner_bytes=0`**（TCP 可连，服务端零字节应答） |
| 备用路径 A：经本地代理直连生产 | `ssh 207.56.8.8`（`ProxyCommand connect -H localhost:7897`） | `/bin/sh: exec: connect: not found` → **本机无 `connect` 助手**，该路径不可用 |
| 备用路径 B：直连生产 | `ssh liuhetong-prod`（207.56.8.8:23421） | `Connection timed out during banner exchange` |
| 生产 Web 是否存活 | `https://liuhetong888.com/api/v1/health/live` | **200**（服务本身健在，仅 SSH 侧不应答） |
| 公网下载是否正常 | 2129 包 Range、`latest-arm64.apk` | **206 / 206** |

结论：端口可连、sshd 不回 banner，跳板机与目标机**同一症状**；生产 HTTPS 正常。
属服务器侧 sshd 挂起或上游中间设备拦截，不是本机网络/代理或产物问题。
另有干扰因素：本机 `http.proxy=127.0.0.1:7897` 与 git 的 schannel 组合此前已出现 TLS 抖动（见
[第二轮验证记录](2026-09-17-ui-round2-five-fixes.md) 第 6 节），与本次 SSH 阻断相互独立。

## 3. 为什么不能在「没有 SSH」时先发布弹窗

弹窗的 `app_apk_url` 指向尚未上传的
`https://www.liuhetong888.com/downloads/ChatFlow-0.3.95-build2132-arm64.apk`。
APK 上传与 `install -m 0644`、`latest-arm64.apk` 原子切换**都必须经 SSH**，没有 HTTP 上传通道。
若先把弹窗指向该 URL，用户点「立即更新」会拿到 **404**——即产生一个**坏掉的更新弹窗**，
比不发布更糟。因此本次**拒绝**在 APK 就位前发布设置（含通过内网 admin API 抢跑的做法）。

## 4. SSH 恢复后的一键续做（脚本与基线已就绪，均**未运行**）

```powershell
# 1) 16MiB 分块上传（逐块远端大小核对）
pwsh -NoProfile -File docs/verification/artifacts/2026-09-17/release-2132/upload-apk.ps1
# 2) 服务端合并 + SHA 门(35CA0962…) + install -m 0644 + latest-arm64.apk 原子切换
pwsh -NoProfile -File scripts/starchat-server.ps1 -Action Upload -LocalPath `
  docs/verification/artifacts/2026-09-17/release-2132/publish-apk.sh `
  -RemotePath /opt/starchat/releases/android-0395-2132-20260917/publish-apk.sh
pwsh -NoProfile -File scripts/starchat-server.ps1 -Action Command `
  -RemoteCommand 'bash /opt/starchat/releases/android-0395-2132-20260917/publish-apk.sh'
# 3) 更新弹窗：inspect → apply（trace android-release-0.3.95-2132-20260917，
#    min_supported_build 沿用线上现值、iOS 行不动、断言 5 条审计）
#    脚本：release-2132/publish_settings_2132.py（容器内执行）
# 4) 发布后验证：带 token 投影读回 0.3.95/2132；未授权 401；公网整包 SHA == 35CA0962…；双侧 200/206 + MIME
```

需要在服务器/跳板侧恢复 SSH（重启 sshd、检查跳板机负载与上游防火墙/中间设备）后即可续做；
本工作流在恢复前**不执行任何服务端写入**，以免留下半完成态。

## 5. 本次未执行项（如实列出）

- 未上传任何分块、未安装不可变文件、未切换 `latest-arm64.apk`、未写入任何设置/审计。
- 未发布更新弹窗；线上仍是 0.3.94 / 2129。
- 未安装 2132 正式包到任何设备（真机验收按约定由用户执行）。
