# StarChat Agent 与维护者指南

状态：Current（维护入口），更新于 2026-10-23；具体版本、生产状态需现场检查。

本指南补充[根 AGENTS.md](../../AGENTS.md)，不覆盖它及下级规则，也不自动授予发布、财务或受保护变更权限。[合并后 CodeGraph 梳理](../reports/2026-10-23-codegraph-merged.md)解释当前模块与调用关系；[最新验证](../verification/2026-10-23-project-maintenance-completion.md)记录本轮结果，前两轮失败仍保留在各自历史报告中。

## 1. 项目和文档入口

StarChat/畅聊是 Flutter + Matrix 加密通信、FastAPI 业务服务、Python Worker、原生 JavaScript 管理台和官网的多语言仓库。Matrix 负责通信；身份、客服、账本、红包、钱包由业务 API 权威管理。

开始工作依次确认：根规则 → [移动交付流程](mobile-delivery-workflow.md) → [当前状态](../workflow/current-state.md) → 关联[任务记录](../workflow/tasks/)与[批准计划](../superpowers/plans/)。修改产品行为前读[产品规格](../superpowers/specs/2026-08-12-starchat-product-modernization-design.md)，受保护变更需要批准 ADR、领域和质量/安全审查。

文档分层遵守 [docs/README.md](../README.md)：runbooks 是现行流程，reports/architecture 是参考，verification 是证据，workflow/tasks 是单项任务记录。历史记录不代表今日生产，也不构成新发布授权。新任务使用[模板](../workflow/task-template.md)，不覆盖别人的 current-state 改动。

## 2. 目录速查

| 路径 | 维护入口 |
| --- | --- |
| `apps/mobile_flutter/lib/main.dart`、`core/`、`features/` | App 装配、会话/缓存、业务与聊天页面 |
| `apps/mobile_flutter/android/`、`ios/`、`third_party/` | 平台工程及受跟踪的 Matrix/媒体 SDK 补丁 |
| `frontend/admin.html`、`frontend/src/` | 管理台，`admin-home.js` / `admin-api.js` / `admin-session.js` |
| `frontend/download.html`、`frontend/downloads/`、`frontend/site/` | 下载入口、元数据和官网 |
| `services/business-api/app/main.py` | FastAPI `create_app` / `create_default_app` 装配 |
| `services/business-api/app/api/`、`modules/`、`core/` | 路由、领域服务、数据库/鉴权/Outbox |
| `services/business-api/migrations/` | Alembic 迁移；先查 heads，再按扩展/迁移/收缩方案操作 |
| `services/business-worker/app/main.py` | Worker 与事件处理器、维护任务装配 |
| `services/matrix-bot/`、`getui-bridge/`、`ios-call-gateway/` | 通知 Bot、个推桥接、独立 iOS 唤醒服务 |
| `packages/` | OpenAPI、事件、UI 契约 |
| `infra/`、`docker-compose*.yml`、`scripts/` | 运行配置、渲染、验证和发布 |
| `tests/`、`apps/mobile_flutter/test/`、`frontend/tests/` | Python/PowerShell、Dart、Node 测试 |

存在 `.codegraph/` 时先用 CodeGraph 定位代码，再按需读源文件；无索引时跳过，不自动建索引。2026-10-23 合并后的 main 索引为 2,731 files / 56,393 nodes / 234,850 edges，状态 complete、待处理项 0；本轮已执行 10 次真实查询。详见[当前图分析](../reports/2026-10-23-codegraph-merged.md)。入口示例：

```powershell
codegraph status --json
codegraph explore 'services/business-api/app/main.py create_default_app create_manual_wallet_runtime'
codegraph explore 'MatrixRoomTimelineAdapter sendTextWithTransaction'
```

不要把整个 `data/`、历史解包目录、`.worktrees/` 或凭据文件灌入上下文。

## 3. 环境依赖与 Shell

所有 Windows 命令使用 PowerShell 7。每次新会话先执行：

```powershell
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
Set-Location -LiteralPath 'D:\pythonProject\outsource\StarChat'
```

| 工具 | 要求/来源 | 本机实测 |
| --- | --- | --- |
| Git | 分支/worktree 管理，凭据使用本机配置 | status、worktree list、fetch 可用 |
| Python | business-api `>=3.12,<3.13` | `py -3.12` 为 3.12.10；裸 `python` 为 3.11.11，不能混用推断环境 |
| Flutter/Dart | Android CI 固定 Flutter 3.44.9；Dart SDK 受 pubspec 约束 | `C:\src\flutter\bin\flutter.bat` 3.44.9 / Dart 3.12.2；未在当前 PATH |
| Node | ES modules 与内置 `node:test` | 22.22.2；前端未声明统一 engines 版本 |
| Docker Compose | 配置渲染、服务构建/启动 | Compose v5.5.1；本轮经用户批准重启后 Engine 29.8.2 恢复，固定镜像 PostgreSQL 16.9 的 14 项并发测试通过 |
| Android | Android SDK、项目 Gradle wrapper、适配 JDK | 本机 JDK 17 路径可发现；TODO：实际构建前按当前 Gradle 校验匹配，不视为编译通过 |
| iOS | macOS/Xcode、相应 CI 与签名资料 | TODO：Windows 无法执行原生 iOS 构建/签名，使用对应 macOS 门禁 |

使用隔离 Python 3.12 环境。本次已在验证目录创建 venv，消除了外部 `tests` 包遮蔽。原始业务锁含 `uvloop==0.22.1`，在 Windows 安装失败，在固定镜像 Linux Python 3.12.11 中原样安装及 `pip check` 通过。不要把下面的 Windows 初始化理解为可以直接安装 Linux 锁：

```powershell
$venv = 'docs/verification/artifacts/<日期>/<任务>/py312' # 用尚不存在的任务路径替换
py -3.12 -m venv $venv
# Linux：原样安装 services/business-api/requirements.lock，然后 pip check。
# Windows：先确认平台锁策略；本次仅在临时锁排除了 uvloop，未改生产锁。
```

运行前检查构建依赖；新环境必须排除 Git 跟踪，不提交它。不要卸载或修改其他项目的全局包。`verify.ps1` 显式调用 `py -3.12` 和 `python`，仅激活 venv 不保证两者都命中目标解释器，须分别检查 `sys.executable`、`app.__file__` 和 `tests.__path__`。本次用临时 PowerShell wrapper 将两个命令路由到同一独立解释器，并只在进程内设置短信有效期 15 分钟；未改根 `.env` 或业务代码。具体脚本、锁 SHA 和日志见[第二轮验证](../verification/2026-10-22-project-maintenance-followup.md)。TODO：项目尚未提供经过统一维护的 Windows 平台锁/解释器入口，应在独立任务中决定，不在本轮顺带修复。

## 4. 启动与构建命令

下列启动/构建命令已与脚本或配置核对；除特别标注外 **TODO：未实际启动/构建**。本次是文档与仓库维护，未连接生产或消费队列。

### 本地基础服务

仅在不存在 `.env` 时复制示例；编辑本机配置，不读取或复制生产秘密：

```powershell
if (-not (Test-Path -LiteralPath '.env')) {
    Copy-Item -LiteralPath '.env.example' -Destination '.env'
}
docker compose --env-file .env.example config --quiet
pwsh -NoProfile -File scripts/init_matrix.ps1 -RenderOnly
# 完成本地配置后再启动：
pwsh -NoProfile -File scripts/init_matrix.ps1 -StartAll
```

Docker 配置检查与 `RenderOnly` 在本次综合验证内通过。`RenderOnly` 会写 `data/` 配置；`StartAll` 不等于启动所有业务服务，它主要初始化 Matrix 基础栈。业务服务按 Compose 显式启动：

```powershell
docker compose up -d business-postgres business-redis
docker compose up -d --build business-api business-worker
```

TODO：仅在隔离本地配置与迁移/事件处理范围确认后执行。API 容器启动会迁移数据库，Worker 会运行任务。

### 业务 API 与前端

```powershell
Push-Location -LiteralPath 'services/business-api'
try {
    py -3.12 -m uvicorn app.main:create_default_app --factory --host 127.0.0.1 --port 8082
} finally { Pop-Location }

# 另一个 PowerShell 会话，从仓库根运行；默认 127.0.0.1:4173
npm --prefix frontend run serve
```

服务端 README 的 `Set-Location backend` 已过时，实际目录是 `services/business-api`。`Settings` 从当前工作目录读取 `.env`，须给服务提供正确的本地配置，不能假设根目录配置会自动加载。静态服务不自动代理业务 API；联调需正确 API base URL/反向代理。

### Flutter

```powershell
$flutter = 'C:\src\flutter\bin\flutter.bat'  # 本机已验证路径；其他机器先定位 SDK
Push-Location -LiteralPath 'apps/mobile_flutter'
try {
    & $flutter pub get
    & $flutter analyze
    & $flutter test
    & $flutter build apk --debug
} finally { Pop-Location }
```

本次实测 `analyze --no-pub`；Flutter 全量复用输入一致的 6,378 pass / 9 skip 历史证据，2,154 个输入文件及证据哈希已复核，详见[第二轮验证](../verification/2026-10-22-project-maintenance-followup.md)。TODO：未新跑原生构建或安装验收。`AppConfig` 当前默认指向正式域名，本地联调必须显式注入测试 homeserver/API 地址。Android 最终交付严格按 [APK 重建流程](android-apk-rebuild.md)执行：源码构建 → DEX/资源/清单常规重建 → zipalign → 稳定签名 → 验包。原始 Gradle APK 是中间件，不能自动充当最终交付包。

iOS 按 [mobile-release](mobile-release.md) 和对应 `.github/workflows/ios-*.yml` 在 macOS 构建。签名、Keychain、旧数据覆盖升级和真机证据分别验收；不在 Windows 假定其通过。

## 5. 测试、lint 和契约

从仓库根执行，Python 服务的 `app` 包同名，按测试组隔离 `PYTHONPATH`：

```powershell
pwsh -NoProfile -File scripts/verify.ps1

$env:PYTHONPATH = 'services/business-api;services/business-worker/app;' + (Get-Location).Path
py -3.12 -m pytest tests/business_api tests/business_worker -q

$env:PYTHONPATH = 'services/getui-bridge'
py -3.12 -m pytest tests/getui_bridge -q

$env:PYTHONPATH = 'services/matrix-bot'
python -m pytest tests/matrix_bot -q

py -3.12 -m pytest tests/infra -q
py -3.12 -m pytest tests/mobile -q
py -3.12 scripts/verify_ui_contract.py

$env:PYTHONPATH = 'services/business-api;' + (Get-Location).Path
py -3.12 scripts/export_openapi.py --check
npm --prefix frontend test
```

最新门禁已通过：Infra 915 pass/20 skip，Getui 51 pass，Bot 9 pass，业务 4,055 pass/127 skip，移动边界 399 pass/1 skip，前端 570 pass；合并后定向 235 pass。其他专用 PostgreSQL 和 Ruby 条件跳过、依赖弃用警告、AST stdin 补验及 Flutter 证据复用边界见[最新验证](../verification/2026-10-23-project-maintenance-completion.md)。本地合并提交 `b729766f`，没有推送。

以下表格仅为第一轮历史结果；[第二轮隔离环境复核](../verification/2026-10-22-project-maintenance-followup.md)保留后续复现，不覆盖首次失败：

| 检查 | 结果/限制 |
| --- | --- |
| 根 verify | 外层退出 1；业务 pytest 收集退出 2，12 errors，后续阶段未执行 |
| Repository/Deployment policy、Template、RenderOnly | 在 verify 中通过 |
| infra / Getui / Bot | 分别 905 pass + 20 skip / 38 pass / 9 pass；Getui 保留 2 条弃用警告 |
| frontend test | 563 total，556 pass，7 fail；失败不是浏览器实测结果 |
| Flutter analyze --no-pub | 退出 0，No issues found |
| UI contract | 退出 0，34 components / 535 screens |
| API import | `import app.main` 通过，未启动服务 |
| OpenAPI check | 退出 1，短信有效期配置校验失败；尚未确认文档漂移 |
| Alembic heads | 退出 0，单 head；offline upgrade 与真实迁移本次未执行 |
| Python AST | 293 文件语法通过；不等于类型检查或所有服务 lint |

Flutter lint 用 `flutter analyze`；前端没有 `npm run lint`/`build` script，不要编造。独立 iOS gateway 文档给出的 `ruff check gateway.py tests` 需在其目录、专用依赖下执行，TODO：本次未跑。全仓 Python 格式/lint/typecheck 没有在本次所读根验证脚本中统一定义，TODO：变更模块时依据其配置/CI补齐，不能把 AST parse 冒充这些门禁。

第二轮独立环境结果：main 业务 3,932 pass/127 skip/1 fail，候选业务 4,037 pass/142 skip/2 fail，候选前端 564 pass/6 fail；移动边界 main 有 1 个 Docker teardown error、候选有 1 个 iOS 版本契约 fail。两边后续 OpenAPI、UI 契约、API import、AST、离线 SQL/单 head、Compose 配置通过。候选新增 Worker PostgreSQL 门禁需明确的 `IM_WORKER_LEASE_TEST_DATABASE_URL`；跳过不能计通过。详细用例、配置条件和容器待确认状态以第二轮报告为准。

`npm --prefix frontend run verify` 包含 Node、浏览器 smoke 和截图；TODO：浏览器运行时/页面准备未验证。截图脚本有产物写入，不为纯文档维护无意义重复执行。

## 6. 常见修改流程

2026-10-23 续办状态见[最新维护验证](../verification/2026-10-23-project-maintenance-completion.md)。上文第二轮失败数字为历史基线；本轮修复了测试夹具、诊断枚举、未签名 CI 版本和旧发布断言，不能沿用历史失败推断当前结果。完整门禁以最新报告的真实退出码为准。

Windows 的 `PYTEST_ADDOPTS` 会按 shell 规则拆分：`--basetemp` 使用正斜杠路径（例如 `D:/.../docs/verification/artifacts/<日期>/<任务>/pytest`），否则反斜杠会丢失。只在本任务的隔离工作树从 `.env.example` 创建测试副本，结束时验证哈希后清理；不要覆盖原主树 `.env`。

自定义 PowerShell `py`/`python` 包装函数还必须转发管道 stdin；不能仅检查参数调用。`verify.ps1` 的 AST 阶段将 here-string 传给 `python -`，包装器丢失输入时可能空执行并退出 0。本轮已用同一检查直连解释器，得到 288 文件 PASS；没有输出的空运行不作为证据。

1. 领取有边界的任务，声明文件所有权；记录 HEAD、工作树、已有改动、验收 ID 与授权来源。共享文件不得并行编辑。
2. 行为修改先写失败用例并确认失败原因，再最小实现。纯文档无需制造运行时测试，做链接/事实/规范一致性检查。
3. 业务接口同步 OpenAPI、迁移、配置和客户端；UI 同步 Flutter/HTML 契约，按 [UI 流程](ui-development.md)验收。
4. 定向测试后预检完整门禁；复用证据须相关输入/环境/覆盖一致，失败/取消记录不可覆盖成通过。
5. 先规格符合性审查，再质量/安全审查；受保护变更补领域审查与批准 ADR。
6. 用任务模板记录时间、命令退出码、源码/锁文件 SHA、工具/OS、日志和未执行项。临时资料只放 `docs/verification/artifacts/<日期>/<任务>/`。
7. 生产/后台改动先读 [admin-production-workflow](admin-production-workflow.md)，发布按 [release-metadata](release-metadata.md)；只有已有用户授权才发布，默认使用既有 jumper 和 `scripts/starchat-server.ps1`。

## 7. 调试方法与常见问题

| 现象 | 已知诊断方法/下一步 |
| --- | --- |
| `No module named tests.business_api` | 本轮 `import tests` 指向 `D:/pentest_ws/strix/tests/__init__.py`，检查 `sys.executable`、`tests.__file__`、`app.__file__`、editable 包和 sys.path；使用隔离环境复现，不能全局卸载其他项目包 |
| `aliyun sms code validity must be 15 minutes` | Settings 会读取 CWD 的 `.env`；本轮实际输入为 5。对照示例/验证器修复该任务的本地测试配置，保留校验；不要输出秘密或直接改生产配置 |
| 下载页测试要求 2213/2205，而页面为新版本 | 核对页面、registry、候选源码、发布记录及真实已授权版本；不可只为测试变绿回退下载页 |
| `flutter` 找不到 | `Get-Command flutter -ErrorAction SilentlyContinue`，检查本机 `android/local.properties` 中 SDK 路径；本机已验证 `C:\src\flutter\bin\flutter.bat` |
| API 无法 import/服务路由错位 | business-api、matrix-bot、getui-bridge 都含 `app` 包，分别设置工作目录/PYTHONPATH，检查 `app.__file__` |
| 消息重试/切号后状态错位 | 从 UI → timeline/outbox → room capability → Matrix SDK 追踪 txn ID、会话代次、租约和远端确认；不要导出聊天明文/密钥，也不以清数据替代定位 |
| 钱包显示与通知不一致 | 查业务 API/事务审计/Outbox；通知不是账本权威；只读追踪，禁止手改跨模块表 |
| Worker 活着但不处理事件 | 检查 handler topic 注册、claim、重试/死信及 MaintenanceHealth，保留幂等和权限边界 |
| Windows 测试通过仍无法发布 | Linux 权限/锁、Android 原生、iOS 原生/签名/真机分别有门禁，不能替代 |
| 测试从 verification/artifacts 加载脚本后 FileNotFoundError | 已将四份同哈希来源的 Worker 夹具纳入 `tests/fixtures/support_worker_probe.py`；其断言保持。新测试依赖必须受版本控制，不依赖被忽略的历史工件 |
| Dart 诊断枚举与服务端 allowlist 不同 | 本轮已同步 11 个 PerformanceStage wire 值及生成 OpenAPI；继续保留固定白名单、未知值拒绝和双端兼容测试 |
| Docker info/rm/ps 长期不返回 | 对探测设置上限，只终止本任务阻塞 CLI并保留结果和容器身份；重启共享引擎需明确授权，不清理他人容器。本轮已获授权并恢复引擎，旧测试容器确认不存在 |

排查先最小复现，再找首个有效错误；记录错误码阶段和输入身份。不记录密码、token、完整钱包地址、明文消息、附件内容或提供方 secret。

## 8. 配置、依赖与代码规范

- `.env`、签名键、数据库、运行中的 homeserver 数据不进 Git；文档只写配置名和安全示例。
- 固定生产镜像版本/digest，禁止 `latest`。依赖变更同步 pyproject/lock 或 pubspec/lock，并审查 vendored patch 与原生兼容。
- Python 使用项目既有类型标注、Pydantic/SQLAlchemy 接口；Dart 使用 `analysis_options.yaml` 和已有组织方式；JS 使用原生 ES modules。保持当前文件的换行/格式，不做整仓格式化。
- PowerShell 用 `-LiteralPath`、显式 UTF-8 读写；搜索首选 CodeGraph（有索引时）或 `rg`，通配路径给 `rg -g`，不要假设原生命令会展开 PowerShell 字符串里的 `*`。
- 财务：Decimal/NUMERIC，CAIBI 两位、USDT 六位；账本追加、按资产平衡、关联冲正；所有金融写入含幂等键、reason code、actor、审计和事务 Outbox。固定 1:1 双向兑换已获批准，其他安全边界不变。
- 鉴权、RBAC、TOTP、审批、E2EE/密钥恢复、钱包状态、破坏性迁移/契约等遵循根规则，不能为消除测试失败降低校验。

## 9. Git 与 worktree 工作流

```powershell
git status --short --branch
git worktree list --porcelain
git branch -avv
git symbolic-ref refs/remotes/origin/HEAD
git fetch --all --no-prune
git rev-list --left-right --count origin/main...main
```

本仓当前目标分支是 `main`，现有历史包含保留来源的 merge 提交。新分支默认 `codex/`；任务需要隔离时先检查并复用合适工作树。**不要自动把所有本地分支合入 main，也不要因旧文档写“无 .git”就忽略实际 Git 状态。**

合并前：明确来源/目标与审查范围，保留未提交工作，刷新远程，运行候选输入的测试/构建检查。脏工作区、门禁失败或来源不明确时停止；不要自动 stash、reset、rebase 或 cherry-pick 以绕过。遇冲突立即列出冲突路径与双方意图，停止并交接，不擅自取一方覆盖。合并后记录前后 SHA、提交范围及复验；不强推、不改写历史。各轮实际提交和合并状态见最新维护验证，不沿用历史状态作为当前事实。

worktree 清理逐项检查：登记路径属于本仓且在 C 盘、不是主树/主仓库、真实路径未逸出；无 tracked/untracked 修改；HEAD 没有任何远程分支不可达提交；已合入目标或有明确废弃依据；无锁定/进程/打开句柄占用。detached HEAD 也必须检查独有提交。忽略文件可能是唯一签名、运行配置或验证工件，先明确保留方案。

确认全部条件后才用 `git worktree remove <精确路径>`，不加 `--force`，不递归删目录代替 Git。**本机 Git 2.51 的沙盒实测会沿被忽略的 junction 删除目标内容**：清理前必须以不跟随链接的遍历清点全部 reparse points，保存链接目标，保全必要文件；对确认忽略、未跟踪的目录链接只解除链接，复查目标仍存在及占用，再执行 Git 移除。不能把普通递归删除当作 unlink。`prune` 可能影响 D 盘残留条目，仅有必要且范围确认后使用。逐项清理结果见第二轮验证；首轮 39 项审计作为历史基线保留。

## 10. 维护检查清单

- [ ] 已读取当前任务、根/下级规则、批准计划，明确文件所有权。
- [ ] 源码、发布工件、状态文档和实际环境的版本分别核实。
- [ ] 已检查 Git/worktree、未提交工作和运行任务，未覆盖他人内容。
- [ ] 有索引用 CodeGraph；无索引明确写静态分析限制。
- [ ] 命令使用正确 CWD/解释器，导入路径和锁文件身份已记录。
- [ ] 行为修改有 red/green；文档修改有链接、符号、命令和规则检查。
- [ ] 聚焦测试与必要全量门禁真实通过，失败/跳过/TODO完整保留。
- [ ] 金融、加密、权限、迁移和平台边界没有弱化。
- [ ] 先规格审查，后质量/安全审查；相关文档/契约/证据同步。
- [ ] 未强推、未改写历史、未删未合入/未推送/脏工作树。
- [ ] 交接包含结果路径、退出码、未完成项、时间及下一条可执行操作。
