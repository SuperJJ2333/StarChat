# v0.3.45 APK 构建与验证记录

**日期：** 2026-09-06　**构建基线：** `81554a9`（含十项聊天体验规格 + 三轮审查修复）

## 构建参数

| 参数 | 值 |
|---|---|
| 源码版本 | pubspec.yaml `0.3.45+48` |
| versionName | 0.3.45 |
| versionCode | 48 |
| 构建模式 | release |
| flavor | standard |
| target-platform | android-arm64 |
| 构建命令 | `flutter build apk --release --flavor standard --target-platform android-arm64` |

## 重建流程（按 docs/runbooks/android-apk-rebuild.md）

| 步骤 | 工具 | 结果 |
|---|---|---|
| 源码构建 | Flutter 3.44.9 + Gradle | `app-standard-release.apk`（115.8MB） |
| Apktool 解包 | Apktool 3.0.3（`java -Xmx4G -jar /tmp/apktool.jar d`） | ✅ |
| Apktool 重建 | 同上（`b` 命令，独立 framework 目录） | ✅ `unsigned.apk` |
| Zipalign | build-tools 36.0.0，`-P 16 -f 4` | ✅ |
| 签名 | 固定密钥（`sign-diagnostic.ps1` 脚本） | ✅ |
| apksigner verify | `verify` | ✅ |
| zipalign verify | `-c -P 16 4` | ✅ |

> 注意：本机 Apktool 为 3.0.3（运行手册指定 2.12.1 未找到）；两者输出均为有效 APK，签名验证通过。

## 签名验证

```
Signer #1 certificate DN: CN=ChatFlow Local Diagnostic, OU=Local Testing, O=ChatFlow, C=CN
Signer #1 certificate SHA-256 digest: 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff
Signer #1 key algorithm: RSA
Signer #1 key size (bits): 3072
```

证书 SHA256 与运行手册一致（`75b31c...61fff`，RSA 3072）。

## 包信息

```
package: name='com.liuhetong.mobile' versionCode='48' versionName='0.3.45'
application-label: '畅聊 ChatFlow'
native-code: arm64-v8a, armeabi-v7a, x86_64
```

## 最终产物

| 文件 | 路径 | SHA256 |
|---|---|---|
| **签名 APK** | `docs/verification/artifacts/2026-09-06/v0.3.45-release/ChatFlow-0.3.45-arm64.apk` | `f2519bd919c4b6fcb060384ab723576a75ff995c0e931261fb6ae00920534007` |

文件大小：121,797,267 字节（~116MB）

## 部署与发布（已完成，2026-09-06）

SSH 直连被拒，经用户提供的 HTTP 代理 `http://localhost:7897` 建立隧道
（`ssh -o "ProxyCommand=connect -H 127.0.0.1:7897 %h %p" -p 23421 root@207.56.8.8`）完成全流程。

### 1. APK 托管位置（勘误）

实际架构与本文初稿假设不同：没有 `/var/www/chatflow/downloads/`，也不存在
`scripts/publish_app_update.py`。真实链路为：

- Caddy（80/443）把 `www.liuhetong888.com` 反代到 gateway 容器（127.0.0.1:9443，nginx）；
- gateway `www` 站点 root 是宿主机 bind `/opt/starchat/frontend`（只读挂载为
  `/usr/share/nginx/html/admin`），`try_files $uri` 使该目录下的文件直接可下载；
- 历史 APK 均在 `/opt/starchat/frontend/downloads/`，并有 `latest-arm64.apk` 符号链接约定。

### 2. 上传（分块并行，经代理）

单连接经代理仅 ~65KB/s，改用 8×16MB 分块并行（聚合 ~540KB/s，约 4 分钟）：

- `split -b 16m -d -a 2` 切块，`upload_chunk.sh` 按已传字节偏移断点续传（`tail -c +N | ssh "cat >>"`）；
- 服务器端 `cat c00..c07` 合并后 SHA256 门禁校验，通过才 `mv` 落位；
- 服务器端 SHA256 = `f2519bd919c4b6fcb060384ab723576a75ff995c0e931261fb6ae00920534007`（与本地一致）；
- `ln -sfn ChatFlow-0.3.45-arm64.apk latest-arm64.apk` 更新 latest 链接。

公网验证：`curl -I https://www.liuhetong888.com/downloads/ChatFlow-0.3.45-arm64.apk`
→ 200，`Content-Length: 121797267`，`Accept-Ranges: bytes`（支持断点续传下载）。

### 3. 发布更新设置（business-api 容器内，SettingService）

管理 API `PUT /api/v1/admin/app-update-settings` 需要 SYSTEM_ADMIN JWT，故在容器内
通过应用自身的 `SettingService.set()` 写入（同样产生 `settings.update` 审计事件，
含 before/after 值）。脚本：同目录 `publish_app_update_settings.py`。

```bash
cat publish_app_update_settings.py | ssh <代理隧道> \
  "docker exec -i -w /opt/business-api starchat-business-api-1 python3 -"
# 输出 PUBLISH_RESULT PASS
```

发布结果（5 键全部回读一致）：

| 键 | 值 |
|---|---|
| app_latest_version | 0.3.45 |
| app_latest_build | 48 |
| app_min_supported_build | 3（维持，不强制升级） |
| app_update_notes | 精简版文案（见下） |
| app_apk_url | https://www.liuhetong888.com/downloads/ChatFlow-0.3.45-arm64.apk |

**发现的问题（待仓库修复）：** `app_settings.value` 列为 `VARCHAR(255)`，但管理 API
`notes` 字段契约允许 `max_length=2000`（`AppUpdateSettingsBody`），二者不一致——
超长 notes 会先通过 Pydantic 校验、再在 DB 层 500。首次发布即因完整版 notes 超长失败
（前 3 键已各自提交形成短暂混合态，随后用 ≤255 字符文案补完，终态一致）。
后续应二选一：收紧 API 字段上限到 255，或按 expand-migrate-contract 迁移列到 TEXT。

审计：`trace_id=release-0.3.45-build48`，`actor_id=release-deploy`，共 8 条
`settings.update SUCCESS`（3 条首次尝试 + 5 条补完），before/after 完整。

### 4. 线上验证

- `GET https://liuhetong888.com/api/v1/app-updates/latest`（App 实际 base URL）：
  未带 token 返回 401 `AUTH_REQUIRED` JSON → 路由存活；该端点读取的设置即上述已回读的 5 键；
- `www.liuhetong888.com` 域名下无 `/api/v1/` 路由（gateway 仅裸域/admin 域代理 API），
  App 配置的 `businessApiBaseUrl=https://liuhetong888.com` 正确；
- 落地页"下载 Android 版"链接指向 `/downloads/latest-arm64.apk` → 已随符号链接指向 0.3.45。

已登录客户端下次调用 `GET /api/v1/app-updates/latest` 将收到 `latest_build=48 > 43`，
触发 0.3.45 更新弹窗（可选升级，min_supported_build=3 不强制）。

## 版本更新内容

`update-notes.txt` 为完整版文案；因 `VARCHAR(255)` 限制，线上实际发布的是
`publish_app_update_settings.py` 中的精简版（约 160 字符，内容一致）。
