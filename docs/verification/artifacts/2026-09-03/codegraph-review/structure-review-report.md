# ChatFlow（畅聊）即时通讯 APP — 项目文件结构审查报告

- 审查对象：`D:\pythonProject\outsource\StarChat`（产品展示名：畅聊 ChatFlow；内部标识：liuhetong）
- 审查日期：2026-09-03
- 审查方式：**codegraph CLI v1.6.0 索引核查**（`.codegraph/codegraph.db`，审查前执行 `codegraph sync` 刷新：914 文件 / 13,403 符号节点 / 36,299 边；语言分布 python 406、dart 323、javascript 127）+ 文件系统 walk + `git ls-files` 交叉验证
- 核查产物（脚本与原始数据）：
  - `docs/verification/artifacts/2026-09-03/codegraph-review/analyze_structure.py`（分析脚本）
  - `docs/verification/artifacts/2026-09-03/codegraph-review/codegraph-analysis.json`（完整数据）
  - `docs/verification/artifacts/2026-09-03/codegraph-review/codegraph-files-tree.txt`（codegraph files 输出）
  - `docs/verification/artifacts/2026-09-03/codegraph-review/analysis-console.txt`（控制台汇总）

---

## 一、文件/目录命名与职责歧义（codegraph 依赖图结论）

**图规模**：codegraph 索引中 file→file `imports` 边共 **1,933** 条；跨一级目录的导入边共 **760** 条，**全部**发生在 `docs/verification` 证据快照与 `apps/` 之间，正式代码区（backend / services / apps / frontend / design-demo）之间**零条**跨区依赖——域隔离（Matrix 域 / 业务域 / 客户端）在依赖图上是干净的。

### 1.1 严重问题：后端存在"一套代码、两条被跟踪路径"

| 项目 | 证据（codegraph + git + 文件系统） |
|---|---|
| 现象 | `backend/`（130 个 git 跟踪文件）与 `services/business-api/`（130 个）内容**字节级一致**（`diff -rq` 退出码 0） |
| 根因 | 磁盘上 `services/business-api` 是指向 `backend` 的 **NTFS Junction**（`Get-Item` 显示 `LinkType: Junction`），git 对两个路径都建了索引 |
| codegraph 证据 | 索引把两份各计一遍（backend 125 + services/business-api 125 个 py 文件），并产生一个**幻影循环依赖**：`backend/app/modules/audit/__init__.py ↔ services/business-api/app/modules/audit/__init__.py` |
| 工具链分裂 | `docker-compose.yml` 用 `services/business-api/Dockerfile` 构建；`scripts/verify.ps1:64` 的 PYTHONPATH 却是 `backend;services/business-worker/app`，`verify.ps1:86` glob `backend/app/**/*.py` |
| 风险 | 任何新克隆（无 junction）会得到两个**真实目录**，后续任意一侧的提交都会造成静默分叉；codegraph/统计/检索全部双计 |
| 建议 | 按已批准规范的 §4 保留 `services/business-api` 为唯一路径：`git rm -r --cached backend` 后删除 junction，同步修改 `scripts/verify.ps1`；改完后重跑 `codegraph index`（注意先落地当前 backend 下 3 个未提交改动） |

### 1.2 严重问题：`frontend/` 与 `design-demo/` 整树重复

`diff -rq design-demo frontend` 退出码 0 —— 两个目录（各 398 个跟踪文件，含 328 张截图、2.4MB 资产）**完全相同**。同时规范要求管理后台位于 `apps/admin_web`（React+TS+Vite），而 `frontend/` 实为纯 JS 演示站（`frontend/src` 仅 4 个 .js 文件），并未承担该职责。另有空目录残留：`design-demo/design-demo/src`、`frontend/design-demo/src`。

### 1.3 真实循环依赖（codegraph SCC 检出 3 个，其中 2 个为真实环）

| # | 环成员 | 验证 |
|---|---|---|
| 1 | `apps/mobile_flutter/lib/core/business_api_client.dart` ↔ `lib/features/auth/login_controller.dart` / `registration_controller.dart` / `invitation_validation.dart` | 已逐行核对 import（core 反向导入 features，**分层倒置**） |
| 2 | `lib/features/matrix/device_gallery_source.dart` ↔ `gallery_video_preview.dart` ↔ `image_picker_page.dart` | 已逐行核对 import，三角环 |
| 3 | `backend/.../audit/__init__.py` ↔ `services/business-api/.../audit/__init__.py` | junction 双路径造成的假环，随 1.1 整改消失 |

建议：环 1 将 auth 相关 DTO/会话结构下沉到 `lib/core/` 或以接口反转；环 2 抽出共享的选图/预览契约文件。改动前后可用 `codegraph impact` 验证影响面。

### 1.4 同名文件与命名歧义

- **可接受（惯用法）**：后端按模块重复的 `models.py ×10`、`service.py ×9`、`enums.py ×2`（经 1.1 双计后在 services 侧显示 ×11/×9）；Flutter `test/**` 与 `lib/**` 同名镜像属约定。
- **需注意**：`docs/verification` 证据快照内含 121 个与正式代码同名的 dart/py 文件（baseline/rollback 副本），被 codegraph 一并索引，污染检索结果——建议在 `.codegraph` 层面或检索习惯上固定排除 `docs/`。
- **命名分层冲突**：规范文档 `docs/superpowers/specs/2026-08-12-...md` 仍以"六合通"为展示名，而 `CONTEXT.md` 词汇表已规定展示名为"畅聊 ChatFlow"且明确 _避免_ "六合通"；同一仓库内还有 `liuhetong-business-api`（包名）、`com.liuhetong.mobile`（Android 包名）、`changliao-component-registry.json`（UI 契约）三层标识并存。内部标识保持稳定是对的，但**面向用户的文档应统一引用 CONTEXT.md**，spec 需加修订注记。
- 文件/目录命名规范本身**零违规**（py/dart 全部 snake_case；无空格/大写目录；唯一例外见 2.3 的 `assets/SE`）。

### 1.5 变更热点（codegraph 扇入 Top）

`backend/app/core/database.py`(116 次被导入)、`lib/ui/foundation/wechat_tokens.dart`(99)、`backend/app/core/config.py`(94)、`backend/app/core/errors.py`(87)、`backend/app/modules/identity/models.py`(62)。热点集中在 core/foundation 层，符合分层预期，但 `wechat_tokens.dart` 与 `business_api_client.dart`(52) 是全客户端耦合点，改动需配 `codegraph impact` 评估。

**结论**：模块化骨架（backend 的 modules/api/core/integrations、Flutter 的 features/ui/core、根级 tests、packages 契约）设计成熟、域隔离经依赖图验证成立；但 1.1/1.2 两处"双轨"与 2 个真实环使当前结构**不足以安全支撑长期维护**，必须先去重、解环。

---

## 二、静态文件存放规范性

真实静态资源（图片/字体/音视频）共 **1,726** 个；`src/lib` 内的 .js/.css 属源码不计入。

### 2.1 存放位置总览

| 位置 | 数量 | 判定 |
|---|---|---|
| `apps/mobile_flutter/assets/`（emoji 56、emoji_vector 225、sounds 15、SE 7、branding 4、html 1、landing.png） | 309 | ✅ 符合 Flutter `assets/` 约定，pubspec 已声明（SE 除外，见 2.3） |
| `apps/mobile_flutter/android/**/res/`、`ios/Runner/Assets.xcassets/` | 59 | ✅ 平台资源标准位置 |
| `design-demo/assets/`（含 branding） | 6 | ✅ 演示站自带资产 |
| `docs/verification/**`（截图、APK 审计 res 导出等） | ~530 | ✅ 依据 AGENTS.md 属验证证据，但体量大（见 4） |
| `build/resources-manifest/5/emoji/*.gif` | 54 | ❌ **根级 Flutter 构建产物被 git 跟踪**（源图已在 assets/emoji） |
| `design-demo/artifacts/screenshots/` + `frontend/artifacts/screenshots/` | 328+328 | ❌ 同一批截图两份（整树重复所致） |

### 2.2 具体问题与建议

| 问题 | 路径 | 建议 |
|---|---|---|
| 构建产物入库 | `build/resources-manifest/5/emoji/*.gif`（54 个 gif + resource-manifest.json，共 55 个跟踪文件）；`.gitignore` 未覆盖根级 `build/`（仅 `apps/mobile_flutter/.gitignore` 覆盖自身） | `git rm -r --cached build`，`.gitignore` 增加 `/build/` |
| 截图双份 | `design-demo/artifacts/screenshots/`、`frontend/artifacts/screenshots/` | 随 1.2 删除其中一个目录自然消解 |
| 证据错位 | `design-demo/docs/verification/artifacts/2026-08-27/chatflow-ui-refinement`（及 frontend 副本） | AGENTS.md 要求临时验证产物只能放在根 `docs/verification/artifacts/<日期>/`，应迁出 |
| 根目录杂物 | `design-demo - 快捷方式.lnk`（未跟踪、未被 ignore） | 删除，`.gitignore` 增加 `*.lnk` |
| 字体 | 应用内无任何字体文件（用系统字体） | 无需处理，仅备注 |

### 2.3 归属含糊

`apps/mobile_flutter/assets/SE/`（7 个音效）：目录名**大写**、未在 `pubspec.yaml` 的 `assets:` 声明（同名职责已有 `assets/sounds/`）。建议改名 `assets/se/` 或直接并入 `sounds/` 并补声明。

---

## 三、测试文件存放规范性

git 跟踪的测试文件共 **218** 个，另有 `docs/verification` 内 15 个 dart 测试副本（证据快照，非活测试）。

### 3.1 分布与约定符合度

| 区域 | 数量 | 命名 | 结构判定 |
|---|---|---|---|
| `apps/mobile_flutter/test/**` | 119 | `*_test.dart` 统一 | ✅ 与 `lib/` 同路径镜像；65 个与 lib 文件一一对应，54 个为聚合型 widget/flow 测试（惯例允许） |
| `apps/mobile_flutter/tool/generate_brand_assets_test.dart` | 1 | — | ⚠️ 唯一位于 `test/` 之外的测试，建议移入 `test/tool/` |
| `tests/business_api/**` | 48 | `test_*.py` 统一 | ✅ 模块子目录（identity 17、ledger 3、redpacket 3、wallet 3…）与 `app/modules/*` 镜像；13 个 API 级测试置于该层根 |
| `tests/business_worker/`、`tests/matrix_bot/` | 7 / 3 | `test_*.py` | ✅ 与 `services/*` 对应（bot 仅 3 个，覆盖偏薄） |
| `tests/mobile/` | 7 | `test_*.py` | ✅ 移动端契约/边界测试（python 实现），职责清晰 |
| `tests/powershell/`、`tests/repository/` | 3 / 2 | `Test-*.ps1` | ✅ 对应 `scripts/*.ps1` 与仓库策略 |
| `frontend/tests/`、`design-demo/tests/` | 9 / 9 | `*.test.mjs` | ✅ 自身镜像（两目录本身重复，见 1.2） |
| 源码树内 | 0 | — | ✅ 无 `test_*.py` 混入 `backend/app`、无 `*_test.dart` 混入 `lib/` |

### 3.2 缺口

- **后端**：`backend/app/modules/` 共 12 个业务模块，`tests/business_api/` 缺 `settings` 模块子目录（其余 11 个均有对应）。
- **Flutter 同名覆盖率**：`lib/` 198 个源文件（排除 `*.g.dart`/`*.freezed.dart`）中 133 个（67%）无同名测试；缺口最大的为 `lib/features/matrix`（27/56 无测试）、`lib/ui/chat`（25/26）、`lib/ui/components`（17/17，由聚合测试 `wechat_components_test.dart` 等部分覆盖——此指标衡量"文件级镜像"，非绝对覆盖率）。
- 6 个 `tests/business_api` 根层测试（`test_complaints.py` 等）按文件名找不到同模块文件，抽查确认它们指向 `app/api/support.py`、`app/api/app_update.py` 等**跨名路由**与 `packages/api-contracts`——属 API 级测试正常形态，非错放。

---

## 四、目录作用说明与规范度评估

### 4.1 一级目录

| 目录 | 设计用途 | 现状评估 |
|---|---|---|
| `apps/` | 规范中的客户端区（mobile_flutter + admin_web） | ⚠️ 仅有 mobile_flutter（结构优秀：lib/test/assets/android/ios 齐备）；admin_web 缺位，其位置被根级 frontend/ 顶替 |
| `services/` | 规范中的服务区（business-api、business-worker、notification-bot） | ⚠️ business-api 被 backend/ junction 双轨（1.1）；worker/bot 结构清晰；bot 命名 matrix-bot 与规范的 notification-bot 不一致（历史名，建议规范补注） |
| `backend/` | （无规范地位） | ❌ services/business-api 的镜像路径，应撤销跟踪 |
| `frontend/` | （规范中无此目录） | ❌ design-demo 的整树副本，未承担 admin_web 职责 |
| `design-demo/` | 设计演示站 | ⚠️ 内容自洽（src/tests/scripts/assets），但被复制成 frontend/，且内嵌 docs/verification 违反证据放置规则 |
| `packages/` | 跨端契约（api-contracts、event-schemas、ui-contracts） | ✅ 三份契约文件各就各位，是单仓架构的正确实践 |
| `infra/` | 部署配置（synapse/nginx/element） | ✅ 得体；compose 文件位于根（规范写 infra/compose，轻微偏差可接受） |
| `scripts/` | 构建/校验脚本（verify.ps1 等 10 个） | ✅ 得体，ps1 配套 scripts/lib 模块 |
| `tests/` | 根级集成/契约测试 | ✅ 分区与 services/apps 对应良好 |
| `docs/` | adr/runbooks/superpowers/verification | ✅ 得体；verification 下证据体量大（含整 APK res 导出），建议设保留策略 |
| `build/` | （不应存在） | ❌ 55 个构建产物被跟踪 |
| `data/` | 本地运行时数据（postgres/synapse/...） | ✅ 已 ignore，未入库 |
| `migration-artifacts/` | 本地迁移备份（20MB，未跟踪） | ✅ 已 ignore；建议定期清理或外移 |
| `.github/workflows/` | CI | ⚠️ 仅 ios-testflight.yml，CI 覆盖薄 |
| `.agents/.claude/.superpowers/.zcode/.codegraph` 等 | Agent 工具链 | ✅ 工具目录，不参与构建；`.codegraph` 内建 .gitignore 未入库 |

### 4.2 关键二级目录（摘要）

| 目录 | 用途 | 评估 |
|---|---|---|
| `backend(app)/app/modules|api|core|integrations|cli` | 12 个业务域模块 + 15 个路由 + 基础设施 | ✅ 分层标准、职责单一；`api/`（HTTP）与 `modules/`（领域）边界清楚 |
| `apps/mobile_flutter/lib/features|ui|core` | 业务特性 / 组件 / 基础设施三层 | ⚠️ 分层清晰但存在 core→features 倒置环（1.3） |
| `apps/mobile_flutter/{test,assets,android,ios,tool}` | 测试/资产/平台壳/工具 | ✅ 标准 Flutter 布局 |
| `services/business-worker/app/{tasks,integrations}`、`services/matrix-bot/app` | 异步任务 / Bot | ✅ 小而清楚 |
| `docs/{adr,runbooks,superpowers,figma,verification}` | 决策/手册/规范/证据 | ✅ 得体 |
| `tests/{business_api,business_worker,matrix_bot,mobile,powershell,repository}` | 见第三节 | ✅（缺 settings） |

### 4.3 总体评级：**需改进**

**理由**：单仓的"骨架"（模块化后端、Flutter 三层、根级 tests 镜像、packages 契约、域间零跨区依赖——均经 codegraph 图数据验证）达到良好水平；但存在三处高风险结构性债务：① 后端双路径（junction + 双跟踪，任何克隆后必然分叉）；② frontend≡design-demo 整树重复；③ 根级 build/ 产物入库；外加 2 个真实循环依赖。这些不是风格问题，而是会随时间放大的正确性/成本风险，故综合评级为"需改进"。

### 4.4 改进建议（按优先级）

1. **[P0] 消除后端双轨**：保留 `services/business-api`，`git rm -r --cached backend` + 删除 junction + 修改 `scripts/verify.ps1` 的 PYTHONPATH 与 glob；完成后 `codegraph index` 重建（幻影环随即消失）。
2. **[P0] 二选一删除 `frontend/` 或 `design-demo/`**；若 frontend 保留作管理端落脚点，应清空重建为规范要求的 `apps/admin_web`（React+TS+Vite）。同删根目录 `design-demo - 快捷方式.lnk` 与空目录 `design-demo/design-demo`、`frontend/design-demo`。
3. **[P0] `git rm -r --cached build` 并在 `.gitignore` 增加 `/build/`、`*.lnk`。
4. **[P1] 解除两个 Flutter 依赖环**（core 不导入 features；matrix 三角抽契约），用 `codegraph impact` 复核。
5. **[P1] `assets/SE` → 小写并并入 pubspec 声明（或并入 `sounds/`）。
6. **[P2] 补 `tests/business_api/settings/`；`tool/generate_brand_assets_test.dart` 移入 `test/tool/`。
7. **[P2] 术语统一**：为 2026-08-12 规范增加修订注记（展示名以 CONTEXT.md 的"畅聊 ChatFlow"为准）。
8. **[P2] 证据治理**：`design-demo|frontend/docs/verification` 迁至根 `docs/verification/artifacts/`；为 docs/verification 设容量/保留策略（当前含 326 张复制的演示截图与整包 APK res 导出）。

---

### codegraph 核查结论一览

| 核查项 | 结论 |
|---|---|
| 索引规模 | 914 文件 / 13,403 节点 / 36,299 边（sync 后）；1,933 条 file→file imports |
| 循环依赖 | 3 个 SCC：2 真实（Flutter auth-core 环、matrix 三角环）+ 1 junction 假环 |
| 跨区依赖 | 760 条全部来自 docs 证据快照；正式代码区间为 0（域隔离成立） |
| 重复路径 | backend↔services/business-api（junction 双跟踪）、frontend≡design-demo（diff 零差异） |
| 扇入热点 | core/database.py(116)、wechat_tokens.dart(99)、core/config.py(94) 等，集中于基础层 |
| 命名违规 | 正式代码区 0；大写目录仅 assets/SE；docs 快照含大量同名副本（可索引排除） |
