# 全部账单点钻余额：Business API 契约回归修复

## 根因与范围

2026-09-25 线上运行的 Business API 镜像 `sha256:25954c6a1f1b1fd5f11d9a5150d99d3a70629d45e29a953674afaba8aee21cff` 健康，账单路由匿名请求返回 401，但运行时 `StatementItem`、OpenAPI 及读服务均没有 `balance_after`。已发布 Android 0.4.7/2172 和 iOS 0.4.7/2173 使用相同的账单读取代码，字段缺失时展示“点钻余额 —”。此前 9 月 24 日已验收的只读余额投影在后续 API 镜像中丢失；本次只恢复该两份 API 源文件，不修改账本、鉴权、worker 或移动端包。

余额按用户 CAIBI 流水 `(created_at,id)` 顺序计算，是历史累计读投影，不是交易提交时快照。筛选、搜索和分页不改变该笔余额；无法获得时仍以未知显示。

## 源码与测试

| 检查 | 命令/对象 | 结果 |
| --- | --- | --- |
| test-first red | `py -3.12 -m pytest tests/business_api/ledger/test_statements_api.py::test_my_statement_is_caibi_scoped_filterable_and_private -q` | 退出 1，预期 `KeyError: balance_after` |
| 账单专项 green | `py -3.12 -m pytest tests/business_api/ledger -q` | 退出 0，18 passed |
| OpenAPI | `py -3.12 scripts/export_openapi.py --check` | 退出 0，PASS |
| 迁移预检 | `py -3.12 -m alembic heads` 与 offline SQL | 退出 0，本地源码 head 0087；线上实际 head 0088，故生产只覆盖两文件，不整树重建或迁移 |
| 全仓 verify | `pwsh -NoProfile -File scripts/verify.ps1` | 首次退出 1：隔离工作树无 `.env`；从 `.env.example` 建立忽略的本地测试配置后重试退出 0：后端 2735 passed/78 skipped，移动边界 108 passed/1 skipped；仓库/部署策略、UI契约、AST、迁移 SQL、OpenAPI 与 Compose 全通过 |
| 基于当前 `main` 重放 | `git rebase main`，再跑账单及 5 份后续钱包监控测试、OpenAPI check | 重放退出 0；`main` 后续 3 提交未触及本次账单读投影/响应模型，专项 126 passed，OpenAPI check 退出 0；按变更影响复用上述全仓门禁，不重复 25 分钟的无关测试 |

规格/领域审查与质量/安全审查均未发现阻断项。候选仍需观察历史流水较大的账户列表 P95，因为每次读都做该账户累计窗口查询。

## 当前生产基线与隔离验证

- 当前 API 容器健康、重启数 0；`/api/v1/health/ready` HTTPS 200，未授权账单 401；业务数据库 head `0088_profile_grapheme_limits`。
- 候选镜像 `sha256:2547aafdc52bec1ef5b8a931ee5cec6f9c7ea7af3161de9c0a4eec983a64d3f4` 从当前镜像离线构建。两份候选源码 SHA256 分别为 `8ccd2bcac47a1b6c46f3de4f31ac930df2e105fde4b2fcac7078ff76459aef57` 与 `8e3fe82a22a3e57b6bff68bd9792e1f37514b7f8ee19a06302d14e6a86dc16ce`；239 份 Python 源文件清单中仅这两份不同。
- 新旧镜像均通过 `business_release_guard.py check --image` 的 9 项 `mobile-refresh-recovery-v1` 协议门禁。候选已在独立、无网络 PostgreSQL 容器中使用当前生产备份验证：备份 25,213,726 字节，SHA256 `6ff47d314f1904c082b8e134128714540cc44be92b96b4e75c115e55f39d3cbb`，恢复 head 0088；仅有 SELECT 权限的角色抽查 10 用户/50 条，列表/详情余额一致且他人不能读取，样本列表 P95 23.13ms。另一独立空 `synthetic` 库通过 PostgreSQL 大额 Decimal、同时间排序、分页、筛选与隐私探针。
- 运行候选探针时必须设置 `PYTHONPATH=/opt/business-api`：首次将脚本挂在容器根目录而未设此值，导入路径指向镜像内旧安装包，测试失败；按线上工作目录设置后退出 0。线上 Uvicorn 工作目录为 `/opt/business-api`。
- 生产冻结 Compose 复制到服务器 0700 目录 `/opt/starchat/releases/bill-balance-20260925-01`；候选/回退配置渲染结果除 `business-api.image` 外相同，运行环境 81 项匹配。回退目标严格为当前 `25954c6a…` 镜像；旧 0087 发布脚本不可复用。

## 发布与用户验收

生产切换前 `predeploy_check.py` 退出 0：运行 API 容器、镜像、健康、数据库 0088、备份 SHA、冻结配置与全部 28 个运行容器身份均未漂移。`business_release_guard.py deploy --compose .../candidate-api.json --service business-api` 退出 0，生成运行冻结配置 `/opt/starchat/releases/guarded-3v1b02yk/compose.json`。仅 `business-api` 切换到 `sha256:2547aafd…`，worker 未切换。

发布后 `postdeploy_check.py` 退出 0：API healthy、restart0、两份源码 SHA 匹配、运行时 OpenAPI 包含 `balance_after`、HTTPS ready JSON `database=ready`、未授权账单 401、数据库仍为 0088、其余 27 个运行容器身份未变。工作站使用既有跳板临时 SOCKS 并保持 TLS 验证，HTTPS ready 200/匿名账单 401，隧道已关闭。新 API 日志 290 行中 ERROR/CRITICAL=0、Traceback=0。隔离 PostgreSQL 测试容器已按准确容器 ID 与 `NetworkMode=none` 验证后清理，生产备份及回退配置留在服务器 0700 目录。

没有收集生产登录态或真实用户账单明细。用户于 2026-09-25 确认 Android 与 iOS 的 V0.4.7 在重新打开“全部账单”并下拉刷新后均显示点钻余额数字；这完成了两端页面验收。旧本地快照在刷新前仍可能短暂显示“—”。若需要回退，先确认运行镜像仍是本次候选、无后续第三次发布，再使用 `business_release_guard.py rollback --compose /opt/starchat/releases/bill-balance-20260925-01/rollback-api.json --service business-api` 回到切换前 `25954c6a…`，复核健康及续期协议。
