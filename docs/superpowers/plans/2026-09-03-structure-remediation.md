# 2026-09-03 结构整改（依据结构审查报告执行）

**状态：** 已批准（用户指令，逐条对应 `docs/verification/artifacts/2026-09-03/codegraph-review/structure-review-report.md` 改进建议）
**执行日期：** 2026-09-03

## 范围与文件所有权

- `services/business-api/`（原 `backend/` 整体迁入）、`scripts/verify.ps1`、`scripts/verify_ui_contract.py`
- `design-demo/`（删除，证据先迁出）、`frontend/`（保留；其 `docs/verification` 迁出、空 `design-demo/` 清理）
- `build/`（撤销跟踪并删除）、`.gitignore`
- `apps/mobile_flutter/lib/core/{business_api_client,business_api_error,business_auth_contracts}.dart`、`lib/features/auth/{login_controller,registration_controller,invitation_validation}.dart`、`lib/features/matrix/device_gallery_source.dart`
- `apps/mobile_flutter/assets/SE → assets/se`、`scripts/build_notification_sounds.ps1`
- `tests/business_api/settings/`（新增）、`apps/mobile_flutter/test/tool/`（自 `tool/` 迁入）
- `docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md`（展示名修订注记）
- `docs/verification/README.md`（新增保留策略）、`docs/verification/artifacts/2026-08-27/`（迁入错位证据）

## 任务清单（2026-09-03 执行完毕）

1. [P0] ✅ 后端去双轨：junction 已删、`backend` 物理迁入 `services/business-api`（含未提交改动与待跟踪迁移 0035）、索引改写、`verify.ps1` 4 处与 `verify_ui_contract.py` 2 处路径修正。
2. [P0] ✅ 删除 `design-demo/`；其验证证据已迁至 `docs/verification/2026-08-27-chatflow-ui-refinement.md` + `docs/verification/artifacts/2026-08-27/chatflow-ui-refinement/`；`frontend/docs/verification`（内容相同）随之移除；根 `.lnk` 与空嵌套目录已删；SKILL.md figma-state 路径已改 `frontend/`。`apps/admin_web` 重建另行立项。
3. [P0] ✅ `build/` 撤销跟踪并删除；`.gitignore` 增加 `/build/`、`*.lnk`。
4. [P1] ✅ 两环解除：
   - auth 环：`BusinessApiException` → `core/business_api_error.dart`（client re-export 保持兼容）；全部 auth 契约（`MatrixLoginGrant`、`DualDomainBusinessGateway`、`RegistrationGateway`、`RegistrationReceipt`、`RegistrationStatusReceipt`、邀请状态机与两个映射函数）→ `core/business_auth_contracts.dart`；`invitation_validation.dart` 删除，其测试迁为 `test/core/business_auth_contracts_test.dart`（保持镜像）；5 个消费方导入更新。**codegraph 重建后 SCC=0**。
   - matrix 环：`GalleryPhoto` 模型自 `image_picker_page.dart` 下沉 `device_gallery_source.dart`（页面以 `export ... show GalleryPhoto` 兼容），数据层不再导入页面。
   - 遗留：`business_api_client.dart` 仍有 5 条 core→features 非环导入（profile/contacts/redpacket 网关与模型），另有 notification/scheduler/bootstrap 4 条——非循环，建议后续专项下沉。
5. [P1] ✅ `assets/SE → assets/se`（git 按大小写改名已显式入索引）。**偏差**：未加入 pubspec——执行中确认 SE 是通知音效的构建母带（`build_notification_sounds.ps1` 据此生成 `assets/sounds/` 与 res/raw），非运行时资产，声明会把母带冗余打入 APK。
6. [P2] ✅ 新增 `tests/business_api/settings/test_settings_service.py`（3 用例：缺省读、新增行+审计事件、覆盖写+前后值审计）。**偏差**：`tool/generate_brand_assets_test.dart` 迁入 `test/tool/` 后经全量测试验证不可行——该测试是**生成器**（重写库内 `app_icon.png` 与 sha256 清单），进入默认套件会污染工作区并使 `launcher_icon_asset_test` 失败（615 通过/1 失败），已回迁 `tool/` 并还原资产（复跑 615/615 全绿）。后续如需纳入默认套件，应先把它改造为输出到临时目录。
7. [P2] ✅ 2026-08-12 规范头部已加"2026-09-03 修订（展示名统一）"注记。
8. [P2] ✅ 错位证据已迁移；`docs/verification/README.md` 已建立（结构、放置规则、分类型保留策略与现存清理候选）。

## 验证方式

- `codegraph index` 重建 + SCC 复查（期望 0 真实环；backend/services 双计消失）。
- `flutter analyze`（apps/mobile_flutter）+ 焦点测试（auth、matrix 媒体、invitation）。
- `py -3.12 -m pytest tests/business_api/settings -q`（PYTHONPATH=services/business-api）。
- `pwsh -NoProfile -File scripts/verify.ps1` 全量回归（如环境受限则逐段执行并如实记录）。

## 证据

- 审查数据：`docs/verification/artifacts/2026-09-03/codegraph-review/`
- 执行证据：`docs/verification/artifacts/2026-09-03/codegraph-review/`（本目录，随执行补充）
