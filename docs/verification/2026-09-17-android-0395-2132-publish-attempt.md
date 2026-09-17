# 0.3.95 / 2132 更新弹窗发布记录（**已上线**；含先前的 SSH 阻断与恢复后一键续做）

- 日期：2026-09-17（Asia/Hong_Kong）
- 用户指令：「请你推送 Android 版的更新弹窗」。
- **最终结果：已发布完成**——APK 不可变文件已安装、`latest-arm64.apk` 已原子切换、更新弹窗已发布（5 条审计）、
  服务器与工作站双侧公网验证通过。详见第 11 节。过程中先经历了一段**生产 SSH 全面不可达**的阻断（第 2、10 节），
  恢复后用第 9 节的一键脚本完成发布。
- 前置事实：另一条工作流已完成 **本地构建 + 全部门禁 + GitHub 推送**，并已写好三个发布脚本；
  其记录见 [0.3.95/2132 发布记录](2026-09-17-android-0395-2132-release.md)。

## 1. 独立复核（本次实测）

| 项 | 实测值 |
| --- | --- |
| 线上发布状态 | **仍是 0.3.94 / 2129**（弹窗未更新）。依据：本会话早前对 `0.3.95` 之前那次发布做过**已验证的投影读回**（`0.3.94/2129`），
  且此后**本任务与并发工作流均未执行任何服务端写入**。注意：无 SSH 时无法直接读回设置本体（读回需服务端铸 token；
  公开端点未授权只返回 401），故此处为「上次已验证值 + 期间零写入」的推断，非本次直接实测 |
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

## 6. 阻断期间完成的离线预检（不依赖 SSH，已实测）

为让 SSH 恢复后一次成功，本次在等待期间把「待发布的产物」与「待执行的脚本」都独立验了一遍。

### 6.1 交付包的发布就绪性（本机独立复算，非引用他人结论）

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 内容哈希 | `Get-FileHash -Algorithm SHA256` | `35CA0962E9DDB3655474B2BCC5182DFCEB52D57549020C8680FC2E4BE3374633`（79,801,374 字节）——与发布记录一致 |
| 清单身份 | `aapt dump badging` | `com.liuhetong.mobile` versionCode **2132** / versionName **0.3.95** / minSdk 24 / targetSdk 36 / native-code **arm64-v8a**（非 debuggable） |
| 对齐 | `zipalign -c -P 16 4` | **exit 0** |
| 签名 | `apksigner verify --verbose --print-certs` | v2 ✓ v3 ✓，`Signer #1 certificate SHA-256: 75b31c66…ba61fff`（固定身份） |
| 上传脚本输入 | `release-2132/android/final.apk` | **存在**，SHA/大小与基线一致（脚本内置 `localHash -ne $baseline` 守卫） |

### 6.2 三个发布脚本的预检（逐项核对，未运行）

| 脚本 | 关键值 | 判定 |
| --- | --- | --- |
| `upload-apk.ps1` | `baseline=35CA0962…`、`remoteDir=/opt/starchat/releases/android-0395-2132-20260917/apk-chunks`、16MiB 分块 + 逐块远端大小核对 | 与已验产物一致，可用 |
| `publish-apk.sh` | `BASELINE=35CA0962…`、`NAME=ChatFlow-0.3.95-build2132-arm64.apk`、`PREV=ChatFlow-0.3.94-build2129-arm64.apk`、合并后 SHA 门 → `install -m 0644` → `ln -sfn`+`mv -T` 原子切换、并打印切换前 `latest-arm64.apk` 指向 | 与 2129 那次已验证的发布形态同构，可用 |
| `publish_settings_2132.py` | `TARGET_BUILD=2132`、`TARGET_VERSION=0.3.95`、`APK_URL=…/ChatFlow-0.3.95-build2132-arm64.apk`、`min_supported_build` 取线上现值（不提高）、断言 `app_ios_*` 零改动 + 该 trace 恰好 5 条审计 + `platform=android` 投影回显、`len(NOTES)<=255` | 满足「不强制更新、iOS 行不动、5 条审计」要求，可用 |

### 6.3 本轮 SSH 复探（全部失败，症状不变）

| 时间窗 | 尝试 | 结果 |
| --- | --- | --- |
| 本轮开始 | `ssh jumper` ×1 | `Connection closed by 8.163.93.151 port 22` |
| 冷却后 | `ssh jumper` ×4（间隔 45s） | 1×`banner exchange` 超时 + 3×`Connection closed` |
| 再冷却后 | `ssh jumper` ×5（间隔 60s） | 2×`banner exchange` 超时 + 3×`Connection closed` |

同窗口公网 HTTPS 仍正常：`health/live` 200、2129 包与 `latest-arm64.apk` 均 206。
即**持续为服务器侧 SSH 无应答**，与本机网络、代理、产物均无关。

## 7. 结论（本轮）

产物已就绪且经独立验证，脚本已就绪且经预检；**唯一缺口是生产 SSH**。
在服务器/跳板侧恢复 SSH 之前，本目标无法推进到 ③④⑤，且**不会**以任何形式的抢跑写入生产
（包括先发弹窗指向未上传的 APK）。恢复后按第 4 节三步执行即可完成。

## 8. 候选内容核对：这次要发布的包确实包含用户要求的改动

用 git 祖先关系与候选源码直接核对（不依赖 SSH）：

| 要求 | commit | 是否在候选 `9fa2c963` 中 |
| --- | --- | --- |
| 红包弹窗恢复居中磨砂样式 + 领取后响音效直接进领取详情 | `ad12f92c` | **是**（`merge-base --is-ancestor` = True） |
| 五项 UI 改动（邀请码/钱包复制位置/充值页/提现按钮/红包入口） | `8c97fbf2` | **是** |
| 清空聊天记录后会话位置不变 | `175b3e6e` | **是** |

候选源码实查：`red_packet_claim_dialog.dart` 中同时存在
`NotificationFeedback.shared.play(SoundType.redpacketOpen);` 与 `_openClaimRecords();`
（即「响音效 → 关闭弹窗 → 进领取详情」），且候选树中**不存在** `red_packet_claim_page.dart`
（已回退的全屏页）。因此 2132 一旦发布，线上即为用户要求的红包行为。

### 构建复用说明（按交付工作流的「不重复等价门禁」）

①②（冻结候选 + 构建与门禁）由并发工作流在**同一 commit、工作树干净时**完成，其记录见
[0.3.95/2132 发布记录](2026-09-17-android-0395-2132-release.md)；本任务**未重复构建**，而是
对产物做了独立复核（第 6.1 节：哈希/清单身份/对齐/签名全部本机复算一致）。
重复构建同一 commit 会产出不同 SHA 的等价包，反而使已记录的发布基线失效，故按工作流复用该产物。

## 9. 一键续做脚本（本轮新增，已自测其「零写入」安全属性）

为把恢复 SSH 后的执行压缩成单条命令，新增
`artifacts/2026-09-17/release-2132/publish-all-2132.ps1`，顺序为：
本地产物 SHA 门 → **SSH 可达性门禁（不可达即中止，绝不做任何写入）** → 分块上传 →
上传并执行 `publish-apk.sh`（合并 SHA 门 + `install -m 0644` + `latest-arm64.apk` 原子切换）→
设置备份（容器 `/tmp` → 宿主机 `0600`）→ `inspect` → `apply`（断言 `PUBLISH_PASS` 与 `audit_count: 5`）→
带真实 token 的 HTTP 投影（断言 `0.3.95/2132`）→ 服务器侧公网检查（新包 200/206 + MIME、`latest` 指向新包、
旧包 2129 仍 200、未授权 401、健康 200、公网整包 SHA）→ 工作站侧经跳板 SOCKS 隧道做 Range 与**整包 SHA** 比对
→ 输出 `PUBLISH_ALL_RESULT=PASS`。

自测（本轮实测）：

| 检查 | 结果 |
| --- | --- |
| 语法解析 | `Parser::ParseFile` → **parse_errors=0** |
| 自测运行 | 退出码 **1**；输出 `artifact_sha256=35CA0962…` → `==> production SSH reachability gate` → `production SSH unreachable: aborting before any server write (no chunks uploaded, no settings written)` |
| 安全性结论 | **门禁在写入之前生效**：自测期间未上传分块、未安装文件、未切换链接、未写设置/审计（脚本在 SSH 门禁处 `throw`，后续步骤未执行） |

## 10. 第二轮复探（仍不可达）

| 路由 | 结果 |
| --- | --- |
| `ssh jumper`（8.163.93.151:22）× 4（间隔 30s） | 1×`Connection closed` + 2×`banner exchange` 超时 + 1×`Connection closed` |
| `ssh target-B`（8.163.93.151:60022，本轮首次尝试的备用路由） | `Connection closed by 8.163.93.151 port 60022` |
| 公网 HTTPS 对照 | `health/live` **200**（服务健在） |

即跳板机**两个端口**的 SSH 均不可用，且症状为「TCP 可连、无 banner」；非本机问题。

## 11. 发布执行（SSH 恢复后，2026-09-17）

第 3 轮探测时跳板机恢复（`ssh jumper` → `exit=0`）。按流程**先重读生产基线**再写入：
`latest-arm64.apk -> ChatFlow-0.3.94-build2129-arm64.apk`（阻断期间无人发布）、业务容器 healthy（up 7h、未重启）。

### 11.1 执行方式与两次修复

用第 9 节的一键脚本执行，过程中修掉脚本自身的两个缺陷（均为**我的脚本**问题，非产物/服务端问题）：

| # | 现象 | 根因 | 处理 |
| --- | --- | --- | --- |
| 1 | 第 4 步「设置备份」`docker cp` 报 `Could not find the file /tmp/android-release-2132-before.json` | 脚本把备份排在 `inspect` **之前**，而该文件由 `inspect` 在容器内生成 | 调整顺序为 `inspect` → 备份出容器 → `apply` |
| 2 | 服务器侧公网校验首条 curl 报 `URL rejected: No host part in the URL` | 远端脚本用了 `\$B`：PowerShell 中反斜杠**不能**转义 `$`，变量被本机插值成空 | 远端脚本改为**单引号 here-string**（不做本机插值），并在远端声明 `NAME/PREV` |

第 1 次失败发生在**设置写入之前**，故当时状态为「APK 已上线、弹窗未发」的安全半完成态；
修正后重跑，脚本对已安装的同名不可变文件与已指向的符号链接具备幂等性。

### 11.2 执行结果（逐步 PASS）

| 步骤 | 结果 |
| --- | --- |
| 本地产物 SHA 门 | `artifact_sha256=35CA0962…374633` |
| SSH 可达性门禁 | `ssh_gate=PASS` |
| 16MiB 分块上传（逐块大小核对） | `upload=PASS` |
| 服务端合并 + SHA 门 + `install -m 0644` + 符号链接原子切换 | `install=PASS`；`merged_sha=35CA0962…`、`SHA gate passed`；文件 `ChatFlow-0.3.95-build2132-arm64.apk`（79,801,374）；`latest-arm64.apk -> ChatFlow-0.3.95-build2132-arm64.apk`；旧包 `ChatFlow-0.3.94-build2129-arm64.apk` **原位保留** |
| 设置 preflight + 备份 | `inspect` 报出 before `0.3.94/2129`；备份 `$rel/backup/settings-before-2132.json`（0600，sha256 `71fa1068…93ec28`） |
| 更新弹窗 apply | **`settings_publish=PASS`**；`"result": "PUBLISH_PASS"`、**`"audit_count": 5`**、`min_supported_build` 仍为 **3**（未强制更新）、`app_ios_*` 投影仍为 `0.3.92/2120`（未改动） |
| 真实 HTTP 投影（带会话 token） | **`live_projection=PASS`**；`platform=android`、`configured=true`、`latest_version=0.3.95`、`latest_build=2132`、`apk_url` 与发布值一致 |

### 11.3 双侧公网验证

服务器侧（`publish-all-public-server.log`）：

| 检查 | 结果 |
| --- | --- |
| 新包 `ChatFlow-0.3.95-build2132-arm64.apk` | 200 / `application/octet-stream` / 79,801,374；Range **206** / 1024 |
| `latest-arm64.apk` | 200（同字节数）+ 206 |
| 旧包 2129（回退路径） | 200 / 79,408,158 |
| 未授权 `app-updates/latest?platform=android` | **401** |
| `health/live` | 200 |
| **公网整包 SHA256（服务器）** | `35ca0962…374633`，与交付候选**一致** |

工作站侧（经跳板 SOCKS，TLS 校验保留，`publish-all-public-workstation.log`）：

| 检查 | 结果 |
| --- | --- |
| 新包 Range | 206 / `application/octet-stream` |
| `latest-arm64.apk` Range | 206 |
| 旧包 2129 | 200 / 79,408,158 |
| **公网整包 SHA256（工作站）** | `35CA0962E9DDB3655474B2BCC5182DFCEB52D57549020C8680FC2E4BE3374633`，与交付候选一致（79,801,374 字节） |

### 11.4 发布后线上状态

| 项 | 值 |
| --- | --- |
| Android 正式版 | **0.3.95 / 2132** |
| `latest-arm64.apk` | → `ChatFlow-0.3.95-build2132-arm64.apk` |
| Android 更新弹窗 | `0.3.95` / `2132`，`min_supported_build` **3**（可关闭，不强制） |
| iOS 更新行 | `0.3.92` / `2120`（未改动） |
| 回退包 | `ChatFlow-0.3.94-build2129-arm64.apk` 原位保留 |

### 11.5 回退

1. 弹窗：`publish_settings_2132.py rollback`（恢复 `0.3.94/2129`，写 `<trace>-rollback` 审计）。
2. APK 别名：`ln -sfn ChatFlow-0.3.94-build2129-arm64.apk latest-arm64.apk`。
3. 本次未改容器镜像、未迁移数据库，无镜像/迁移回退项。

### 11.6 需要用户留意的一点（更新文案覆盖范围）

弹窗文案（由并发工作流撰写、随 2132 候选一并冻结）描述的是**闪照安全 / 通话音频路由 / 搜索优化**三项；
本次构建同时**包含**红包弹窗行为修复（`ad12f92c`）与五项 UI 改动（`8c97fbf2`，第 8 节已证），
但**未在文案中逐条点名**。若希望用户看到红包/钱包相关说明，可用一条新的
`SettingService` 更新改写 `app_update_notes`（同一 trace 规则，写 5 条审计），需要时我可以补做。
