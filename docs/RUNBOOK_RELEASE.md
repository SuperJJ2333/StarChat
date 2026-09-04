# 发布流水线 Runbook（CI/CD + 一键发布脚本）

## 5. 主发布路径（CI 构建 + 服务器下行拉取）

**为什么**：本地→服务器上行受本地出口带宽限制（代理绕行时 ~70-110KB/s，
180MB 约 30 分钟；直连可能被上游重置）；GitHub Actions 云端构建 +
服务器数据中心下行拉取（公开仓库 Release 匿名下载，无需凭据）。
签名密钥只进 GitHub Secrets——分发服务器只持有已签名产物，不持有
签名能力。

```powershell
# 前置：递增 pubspec.yaml + app_config.dart 到同一版本并 commit
# （工作树必须干净——CI 只构建已提交内容）
pwsh -NoProfile -File scripts/release_ci.ps1 -Version 0.3.36 -Notes "0.3.36 更新：……"
```

自动执行：

1. **预检**：版本三方一致（pubspec ↔ app_config ↔ 参数）；工作树干净
   （apps/mobile_flutter/.github/scripts/services 无未提交变更）。
2. **tag 触发**：要求 `v<版本>` tag 已推送到 origin（android-release.yml
   在 tag 上构建并创建 GitHub Release，附 APK×3 + SHA256SUMS；
   tag↔pubspec 版本一致性由工作流强制）。
3. **等待 Release 资产就绪**（匿名 API 轮询，构建约 15-25 分钟；
   失败时附 Actions 运行链接直接中止）。
4. **服务器下行拉取**（`scripts/server_pull_release.sh`）：GitHub
   Release → 服务器 /tmp → **sha256sum -c SHA256SUMS 强制校验** →
   部署到 downloads/ → 保留上一版回滚包、清理更旧 → `ln -sfn` 别名。
5. **publish（更新弹窗）**：`scripts/publish_app_update.py`（release.ps1
   内嵌脚本的参数化抽出）在 business-api 容器内执行，幂等键防重复。
   `-SkipPublish` 可只部署不发布。
6. **公网回拉验证**：本地下载 arm64 → SHA256 对照 **GitHub Release 的
   SHA256SUMS**（而非本地构建产物——CI 构建哈希必然不同）→ aapt
   versionCode/versionName 双验。

**与本地构建的本质差异（红线）**：CI 构建的是 **git 已提交内容**。
工作树脏时 `release_ci.ps1` 拒绝发布（"测过的=发出的"）；这与
`release.ps1`（本地工作树直接构建）不同——后者保留为降级路径。

## 1. 降级路径：一条命令本地发布（release.ps1）

```powershell
# 前置：pubspec.yaml 与 app_config.dart 已递增到同一版本
pwsh -NoProfile -File scripts/release.ps1 -Version 0.3.35 -Notes "0.3.35 更新：……"
```

脚本自动执行（`docs/verification/artifacts/<日期>/release-<版本>.log` 落档）：

1. **预检**：版本三方一致（pubspec ↔ app_config ↔ 参数）；flutter analyze；
   全量 flutter test；`scripts/verify.ps1`（仓库聚合门禁）。
2. **构建**：`build_mobile_public_domain.ps1`（origin 探测 + aapt 版本守卫 +
   libapp origin 守卫 + SHA256 输出）。
3. **上传+别名+回滚**：scp 三 ABI → 服务器端 SHA256 核对 → **ln -sfn**
   别名（0.3.32 cp 穿透事故的硬规矩）→ 保留上一发布版、清理更旧版本。
4. **发布**：容器内 JWT → PUT `/api/v1/admin/app-update-settings`
   （幂等键 `app-update-publish-<版本>-<日期>`）→ LATEST 校验 PASS。
5. **回拉**：公网下载 arm64 → SHA256 + aapt versionCode 双验。

常用开关：`-SkipBuild`（用现有产物重放）、`-SkipPublish`（只传包不发布，
人工确认后再发）。

**SSH 限流**：所有远程操作经 `Invoke-Remote` 指数退避（30s→2m→5m→9m）；
服务器防护层对高频连接限流最长约 25 分钟（历史记录
`docs/verification/2026-09-03-release-0.3.29.md`），脚本会自动等待重试。

**回滚**：`release.ps1` 不会自动回滚。手动：①`PUT` 回上一版设置
（改 publish 脚本常量为上一版本号/号）；②服务器
`ln -sfn ChatFlow-<上一版>-arm64.apk latest-arm64.apk`（及另两 ABI）。

## 2. GitHub Actions CI（push/PR 自动，无需 Secrets）

`.github/workflows/android-ci.yml`，三 job：

| Job | 内容 |
| --- | --- |
| backend | python 3.12：tests/infra + getui_bridge + business_api + business_worker + mobile（边界）+ UI 契约 + OpenAPI 漂移 + Alembic 单头/离线 SQL + compose 渲染 |
| flutter | Flutter 3.44.9（固定）：pub get + analyze + **全量 flutter test** |
| android-debug-build | 无需签名：`flutter build apk --debug --flavor standard`（验证 gradle/依赖/manifest 合并） |

守卫测试 `tests/mobile/test_android_ci_workflow.py` 防工作流被静默弱化
（版本固定、全量测试在门禁、Linux PYTHONPATH 分隔符等）。

## 3. 签名 Release 构建（GitHub Actions，需一次性 Secrets 配置）

`.github/workflows/android-release.yml`：
- **tag `v*.*.*` 触发（主路径）**：版本一致性校验（tag ↔ pubspec ↔
  app_config）→ 从 Secrets 还原签名 → 同一构建脚本（含全部守卫）→
  **创建 GitHub Release**（APK×3 + SHA256SUMS，`gh release create`，
  tag 重推幂等 `--clobber` 补传）→ 服务器下行拉取部署（§5）。
- **手动 dispatch**：只构建存 workflow artifact（不建 Release——发布
  产物必须挂不可变 tag）；可选直连上传服务器（PROD_SSH_KEY，备用）。
- **publish 永远不自动化**（工作流内无 app-update-settings 调用；
  守卫测试 `tests/mobile/test_android_ci_workflow.py` 断言）。

### Secrets 配置（用户一次性操作）

仓库 Settings → Secrets and variables → Actions → New repository secret：

1. **`ANDROID_KEYSTORE_BASE64`**：本地执行
   `powershell -c "[convert]::ToBase64String((Get-Content -AsByteStream 'D:/secure/liuhetong/liuhetong-release.jks'))"`
   （Linux/Mac：`base64 -w0 liuhetong-release.jks`），输出粘贴为 Secret 值。
2. **`ANDROID_KEY_PROPERTIES`**：`apps/mobile_flutter/android/key.properties`
   的完整内容（4 行 storeFile/storePassword/keyAlias/keyPassword）。
   storeFile 行会被 CI 的 `KEYSTORE_FILE` 环境变量覆盖，值本身无所谓。
3. **`PROD_SSH_KEY`**（仅当要 CI 直接上传服务器）：部署私钥全文；
   对应公钥需追加到服务器 `/root/.ssh/authorized_keys`：
   `ssh-keygen -t ed25519 -f ci-deploy -C starchat-ci`，公钥放服务器，
   私钥进 Secret。

**安全红线**：keystore/密码只进 GitHub Secrets（加密存储，日志自动脱敏），
绝不进仓库；CI 日志只打印 key.properties 的字段名（`cut -d= -f1`）。

### 触发

```bash
git tag v0.3.35 && git push origin v0.3.35
# 或 GitHub → Actions → android-release → Run workflow（勾选 upload_to_server 可选上传）
```

## 4. 已知边界

- 仓库已公开（匿名 ls-remote 可达）——Secrets 仅在 Actions 运行器解密。
- CI 签名构建在 Secrets 配置前 fail-fast（工作流内有明确错误提示指向本
  文档），不伪装成功。
- `release.ps1` 的 publish 段在服务器限流极端窗口（>退避上限）下会失败
  重试提示——按提示稍后重跑 `-SkipBuild` 即可（幂等键防重复发布）。
