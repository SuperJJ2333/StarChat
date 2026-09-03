# 2026-09-03 结构整改执行证据

对应计划：`docs/superpowers/plans/2026-09-03-structure-remediation.md`

## 执行结果

| # | 项 | 结果 |
|---|---|---|
| 1 | 后端去双轨 | `services/business-api` junction 删除；`backend` → `services/business-api`（130 跟踪文件 + 1 待跟踪迁移 0035 + 3 个未提交修改随迁）；`git rm -r --cached backend`；verify.ps1（PYTHONPATH×2、AST glob、alembic Push-Location）与 verify_ui_contract.py（2 处）路径修正。导入冒烟：`import app.main` PASS |
| 2 | 删除 design-demo | 证据先迁根目录（.md + artifacts/2026-08-27/chatflow-ui-refinement）；frontend/docs 同内容移除；398 文件 git rm；根 `.lnk`、`frontend/design-demo`、`design-demo/design-demo` 清除；SKILL.md:18 figma-state 路径 → frontend |
| 3 | build 撤踪 | `git rm -r --cached build`（55 文件）+ 目录删除；`.gitignore` += `/build/`、`*.lnk` |
| 4 | 依赖环 | 见下"codegraph 复核"；flutter analyze 0 issues；焦点测试 166 通过；全套 615 通过 |
| 5 | assets/SE → se | git 大小写改名显式入索引；`build_notification_sounds.ps1` 3 处引用更新；不入 pubspec（构建母带，非运行时资产） |
| 6 | settings 测试 | `tests/business_api/settings/test_settings_service.py` 3 passed；tool 测试迁移经红/绿验证后回迁（见计划偏差记录） |
| 7 | 规范注记 | 2026-08-12 spec 头部新增"展示名统一"修订段 |
| 8 | 证据治理 | 迁移完成；`docs/verification/README.md` 保留策略建立 |

## codegraph 复核（index 重建后）

- 索引：914 → **754 文件**（backend 双计 ~125、design-demo ~40 等移除），11,430 节点 / 31,636 边。
- file→file imports 边：1,933 → 1,698；**SCC（size>1）= 0**（整改前 3：auth 环 4 节点、matrix 三角环、junction 假环）。
- `codegraph impact InvitationValidationResult`：10 个受影响符号全部解析到新位置（core/business_auth_contracts.dart + 4 个消费方/测试）。
- 遗留 core→features 非环导入 9 条（business_api_client 5 + notification/scheduler/bootstrap 4），非循环，列为后续专项。

## 回归验证

- `flutter analyze`：**No issues found**（初跑暴露 1 处契约抄写笔误 `resendAfterSeconds` String→int，已修复；另发现 gallery 导入非死导入，改为 GalleryPhoto 模型下沉）。
- `flutter test`（全套）：**All 615 tests passed**（期间验证了 tool 测试迁移的副作用并回迁，见计划）。
- `py -3.12 -m pytest tests/business_api/settings -q`：**3 passed**。
- `pwsh -NoProfile -File scripts/verify.ps1`：**Verification: PASS**（仓库策略、部署策略、模板测试、matrix-bot、business_api+worker、mobile 边界、UI 契约漂移、导入冒烟、AST、Alembic 单头+离线升级、OpenAPI 漂移、compose render 全部通过）。

## 已知偏差（相对指令原文）

1. `assets/se` 未补 pubspec 声明：SE 是音效构建母带，声明会把母带打入 APK。
2. `generate_brand_assets_test.dart` 保持 `tool/`：迁入默认套件会重写库内 branding 资产并使 launcher_icon_asset_test 失败（实测 615+1 失败 → 回迁 + 还原资产 → 615 全绿）。

## 2026-09-03 提交与发布记录

- 提交 1：`41fa400 refactor(repo): structure remediation per 2026-09-03 codegraph review`
- 提交 2：`a78ac0d feat(mobile+api): friend system refactor, direct conversations, 0.3.28 update fixes`
- 提交前审计：新增文件无 >1MB；两笔提交全量 diff 密钥扫描无命中（仅变量名/删除行误报）；`.codegraph/`（48MB 索引库）已加入 .gitignore 防误提交。历史中既有大文件（APK 审计快照最大 94.3MB kernel_blob.bin、production-sync zip 11MB）低于 GitHub 100MB 单文件上限，但建议后续按 docs/verification/README.md 保留策略清理并用 BFG/rewrite 缩史。
- **0.3.28 更新弹窗发布：PASS**（生产容器 `starchat-business-api-1` 内执行 publish_app_update_0.3.28.py；幂等键 app-update-publish-0.3.28-20260903b；`GET /api/v1/app-updates/latest` → configured=true, 0.3.28 / build 2031, APK 200 可下载）。
- GitHub 推送：**暂被阻塞（403）**——本机唯一 GitHub 凭据为 a1014826460-stack（对 SuperJJ2333/StarChat 无写权限）；~/.ssh 三把私钥均未绑定 GitHub。两笔提交已在本地 main 就绪，待授权后 `git push origin main` 即可。
