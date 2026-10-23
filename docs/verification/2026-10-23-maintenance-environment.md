# 可复现环境、模块门禁与归档维护

状态：环境、门禁、审查与归档保管验证完成，待合入及普通远程同步。基线 `22706244b287667ec8c39d354f2f3dc94ada7d6b`；[计划](../superpowers/plans/2026-10-23-maintenance-environment.md) · [任务](../workflow/tasks/2026-10-23-maintenance-environment.md) · [模块矩阵](../testing/maintenance-gates.md)。

## 已完成的环境修复

- `scripts/bootstrap-python.ps1` 创建 `.venv312`，拒绝覆盖既有环境；新环境 Python 3.12.10，锁定安装及 pip check 通过。
- `scripts/python_environment.py` 从业务生产锁和 `scripts/requirements-dev.lock` 派生开发输入。Windows 仅排除 uvloop；生产锁 SHA 保持 `f64b119c66265cb59b3272d074afe32b4560da1715f30499580c3a046346bf8f`。
- `scripts/verify.ps1` 直接使用同一绝对路径解释器，检查真实 venv、精确版本、stdin 哨兵、业务导入归属及配置；长门禁前失败，避免混用 3.11 全局包或空执行成功。
- pytest 使用新建任务目录的正斜杠、带引号路径；不沿用调用者可能含筛选条件或危险路径的 PYTEST_ADDOPTS，结束恢复调用者相关环境变量。
- 短信有效期保持既有 15 分钟校验；不改业务代码或原主树 `.env`。本轮完整门禁在独立工作树使用临时 `.env.example` 副本。

## 测试证据

本轮原始证据根目录（主树、Git 忽略）：`docs/verification/artifacts/2026-10-23/maintenance-environment/`。日志含命令结果；JSON 回执含起止时间和退出码。未记录探索起点，前期精确工时未知。

| 检查 | 结果及证据 |
| --- | --- |
| 开发环境派生/拒绝全局解释器 RED | 4 项预期失败，environment-red.log |
| 旧包装器吞 stdin 复现 | 退出 0、输出 0 行，stdin-original-wrapper-red.json；并非真正执行检查 |
| 新环境安装 | exit 0；bootstrap.json/log，pip check 无破损依赖 |
| 新入口行为 | 7 项通过；环境身份、锁、stdin、环境恢复、错误短信配置早失败、拒绝优化模式；environment-review-green.log |
| 优化模式绕过防护 RED/GREEN | 原实现未拒绝 `-O`，回归真实失败；修复后拒绝 `-O`/`PYTHONOPTIMIZE`，单独优化模式 preflight 也按预期退出 1；optimization-red.log、optimized-preflight-red.json |
| PostgreSQL 16.9 专项 | 39 passed / 0 skipped，exit 0；通信恢复 20、Worker 租约/隔离 14、动态草稿 5；postgres-selected.json/log |
| Worker 租约窗口补验 | 1 passed / 0 skipped，exit 0，1.15s；新的独立 PG 16.9 实例，postgres-lease-window.json/log |
| 最终版 infra 补验 | 919 passed / 20 skipped，exit 0，71.04s；20 项为同一组通信恢复 PG 条件，上行专项已覆盖；final-infra.json/log |
| 完整 verify | exit 0，末行 Verification: PASS；11:53:21.850 → 12:42:40.632 UTC+08，49m18.78s；full-verify.json/log |
| 长门禁分组 | 初始 infra 921/20 skip、Getui 51、Bot 9、API/Worker 4,040/142 skip（2,766.71s）、移动边界 399/1 skip |
| 长门禁后段 | UI 34 components/540 screens，API import、AST 288 文件、Alembic 单 head/offline SQL、OpenAPI、Compose 均通过 |

新入口测试区分两种条件：`tests/infra/test_python_environment.py` 不要求开发环境已安装，适用于现有普通 CI；`tests/development/test_python_preflight.py` 由 verify 在前置环境检查后执行，要求完整锁定 venv。避免让现有使用全局 Python 的 CI 因开发环境正向集成测试而产生假失败。

完整 verify 启动后，审查要求将三项依赖已安装 venv 的测试移至 development、增加独立执行步骤，并将安全条件改为显式分支、拒绝优化模式。最终入口及 infra 单独补验；不变的业务源码、生产/开发锁和业务测试命令复用同次长门禁证据，不称最终版脚本原样重复运行了全部流程。依赖固定到精确版本；本轮未建立包含构建工具链和 wheel 哈希的逐字节可复现安装。

规格审查的两项 P2（优化模式绕过断言、示例未检查前置命令退出码）均已修复并复核关闭；随后独立质量/安全审查未发现 P0/P1/P2。最终输入核对确认业务/移动/前端/契约未改、主树 `.env` 与 Android 最终 APK 哈希保持。新增文档链接全部可解析；扫描 current-state 全部历史正文时另发现 19 处原有引用在此工作树未解析（含未复制的忽略工件和历史相对路径），均已与 HEAD 正文确认原有，保留清单于 all-doc-links-baseline-findings.json，本轮不改写历史资料。代码差异空白检查通过。

## 条件覆盖与未执行项

历史 148 项分解为 144 项 PostgreSQL 配置缺失、3 项 SQLite 参数适用性、1 项 Ruby 缺失；完整列表见矩阵。此次长门禁未设置专用 PG 变量，出现 163 项跳过（infra 20、业务 142、移动 1），比历史多 15 项 Worker 场景；并非新增失败。额外 PG 检查覆盖其中通信恢复 20、动态草稿 5、Worker 14+1，均实际通过且实例已清理。其余真实 PG 用例未在本轮逐项重跑，不声称全部条件门禁通过。PG 参数有些仅在变量存在时才收集，不能机械用历史总数相减。

保留 Getui 3 条、业务 2 条既有弃用警告：Starlette TestClient/httpx、AnyIO BlockingPortal 别名及 Getui 的 Pydantic class Config。没有隐藏警告或无依据升级；后续依赖维护须分别验证兼容。

本轮未修改移动/前端源码；沿用上一轮相关输入不变的 Flutter/前端和工件证据，不重新打包 Android/iOS。Ruby hook、原生平台编译、企业签名保数据升级及真实设备反馈仍按对应任务执行。现有 CI 的未完全锁定安装流程尚未重写；本轮固定的是本地开发/验证入口，不能称所有 CI 平台已可复现。

## 归档保管

九个已清理 worktree 的 28 个归档/清单文件已复制到 `D:/StarChat-maintenance-backups/2026-10-22-worktrees`。每个文件校验复制前源 SHA、目标 SHA 和复制后源 SHA；访问控制只允许当前用户及 SYSTEM，禁止继承扩权。回执 `archive-copy.json` 与备份内 `backup-receipt.json`。

原候选 worktree 内的 vault 保留，不再作为唯一副本；`restore-smoke-rollback` 是既有 ZIP 的恢复验证目录，不是另一个独有原件，本次稳定副本保留全部九 ZIP、九清单、九链接解除记录和 ACL 记录。没有删除其他工作树；后续只有重新满足干净、已推送、已合入、无占用及忽略材料保全条件才可移除。

备份包含配置/数据，不进入公开 Git 仓库。恢复时先核对回执哈希，在受限的新目录内恢复；不可将归档中的 `.env`、密钥、数据库直接覆盖活动工作区。

## Git 同步审阅

远程 `SuperJJ2333/StarChat` 为公开仓库，默认分支 main。fetch 后 `origin/main=be207f0fece77f0a4585790d7c0932368ac63146`，原 main 领先 280/落后 0。

已扫描该范围全部 3,004 个新增可达 blob（含中间历史修订；3,002 文本/2 二进制，共 92,640,180 bytes）。没有 >90 MiB 对象、敏感文件名或私钥/平台令牌模式；5 处通用凭据赋值命中均确认是合成测试值。此启发式扫描不等于完整安全审计。

独立只读审阅确认：仓库内 main 触发的 Actions 没有生产部署；iOS CI 可能使用配置的签名资料生成 CI 候选 IPA，但 App Store 上传禁用。Android 生产上传仅 tag/manual 触发。本次普通同步只推显式 main，不带 tags；未检查外部 webhook/托管集成。Android2233/iOS2215 发布身份、移动输入和静态发布元数据与原验收一致。

完整门禁及规格、质量/安全审查已通过；本轮合入和普通推送待最终远程漂移复核。不强推、不改写历史，不发布生产。

## 本地资源

Docker 首次探测超时 15 秒，沿用用户既有重启授权，仅恢复 Docker Desktop 与 docker-desktop WSL 实例，恢复 Engine 29.8.2。两个专项 PG 实例 `starchat-maint-env-2091507e55fb`、`starchat-maint-env-b01c49507d22` 正常停止、移除并确认不存在；临时口令文件已删除。

完整门禁创建的 popup/publisher 两个容器由夹具销毁；依 Docker 事件确认精确容器 ID、固定镜像和 volume mount/unmount 归属，再逐一确认卷未被任何容器引用，删除其两个匿名卷。回执 docker-full-cleanup.json、身份链 docker-full-events.jsonl；没有使用全局 prune。临时 `.env` 按原哈希核对后删除，主工作区配置未修改。
