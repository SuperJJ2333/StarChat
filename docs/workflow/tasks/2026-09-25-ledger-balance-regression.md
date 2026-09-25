# 全部账单逐笔点钻余额回归

## 恢复入口

- 目标与授权：用户 2026-09-25 报告最新 Android/iOS“全部账单”页点钻余额不显示，要求确认 API 原因并修复。仅恢复已批准的只读账单余额投影；不改账本写入、钱包余额或移动端签名包。
- 关联计划：`docs/superpowers/plans/2026-09-24-announcement-wallet-support.md` 第 2 项及其 9 月 24 日验收记录。隔离分支从 `9cfcd00c` 建立，修复提交已重放至 `main` 的 `2442f0ab` 之上；生产发布以当次运行镜像为基底，仅覆盖两文件。
- 当前状态：全仓门禁通过、API-only 生产发布及机器验收完成；待 Android/iOS 真机页面回馈。
- 负责人及文件所有权：`codex/bill-balance-api-fix`，`C:\Users\Administrator\.codex\worktrees\bill-balance-api-fix\StarChat`；仅本任务修改 ledger API/读投影、对应测试、OpenAPI 与本文档。
- 最后更新：2026-09-25 18:18 HKT。
- 下一步：用户在 Android/iOS 重新打开并刷新“全部账单”；若仍显示未知，收集匿名请求结果并核查客户端缓存/刷新状态。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| BILL-01 | 账单列表/详情展示两位小数的逐笔点钻余额 | `StatementService` 按用户 CAIBI 流水的 `(created_at,id)` 顺序累计，`StatementItem.balance_after` 返回字符串 | 首个测试 red：`KeyError: balance_after`；green：账单测试 18/18，OpenAPI check 退出 0 | API-only 已发布；运行时 OpenAPI 字段存在 | 两端 0.4.7 源码已核对，真机仍待用户回馈 |
| BILL-02 | 筛选、搜索、分页不改变该笔余额；他人不可见 | 全量用户流水先累计，仅所请求行返回 | SQLite 18/18；隔离 PG 生产恢复只读抽查 10 账户/50 条；独立 synthetic PG 精度/分页/隐私探针通过 | 已发布 | 无生产账号，不伪造真实账单读取 |
| BILL-03 | 新 API 恢复时保留当前鉴权和其他服务 | 基于当前镜像仅覆盖 `app/api/ledger.py` 与 `app/modules/ledger/statements.py` | 候选 `2547aafd…` 协议 9 检查通过；239 Python 源文件仅两项差异；配置除 image 外等价，81 项 env 匹配 | 已发布：健康、restart0、未授权 401、其他 27 容器未变 | 只切 API，worker 未切换 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源 | 观察 |
| --- | --- | --- | --- |
| Android 正式包 | V0.4.7/2172，APK SHA256 `7741e45a9c2c8b70a0ad46977a657f96b86f9500f7a1fa4bd04155e08906c773` | 发布记录及本地工件重新计算 | 来源 `e7ba46a4`；账单页面读取 `balance_after` |
| iOS 正式包 | V0.4.7/2173，IPA SHA256 `29d9946b3469d59c64d73d679838623873930f8a7c2ae7c087eb2e5589acc3d0` | 发布记录及本地工件重新计算 | 来源 `9eb41e8f`；与 Android 账单相关代码相同 |
| 生产 Business API | `sha256:25954c6a1f1b1fd5f11d9a5150d99d3a70629d45e29a953674afaba8aee21cff` | 2026-09-25 线上容器只读核查 | 健康，运行时 OpenAPI `StatementItem` 缺 `balance_after`；匿名账单请求 401 |
| API-only 候选 | `sha256:2547aafdc52bec1ef5b8a931ee5cec6f9c7ea7af3161de9c0a4eec983a64d3f4` | 当前镜像离线两文件覆盖 | 239 源文件仅两文件差异；新字段模型及隔离数据验证通过 |
| 隔离分支 | 基于 `2442f0ab`；最终修复提交以分支 HEAD 为准 | `codex/bill-balance-api-fix` | 源码修复与证据，非生产镜像基线 |

## 阶段计时

| 阶段 | 开始/结束 HKT | 结果 |
| --- | --- | --- |
| 审计与根因 | 2026-09-25，本轮 | 运行中响应模型及读服务均缺字段；精确时间未记录 |
| test-first red | 2026-09-25 17:38 左右 | 单项测试退出 1，预期 `KeyError` |
| 实现与专项 green | 2026-09-25 17:42 左右 | 18 项账单测试与 OpenAPI 检查退出 0 |
| 全仓门禁 | 2026-09-25 17:43 起，约 25 分钟 | 首次尝试因隔离工作树缺 `.env` 退出 1，随后用 `.env.example` 创建忽略的本地测试配置重试；最终 `verify.ps1` 退出 0，后端 2735 passed/78 skipped，移动边界 108 passed/1 skipped |
| 候选隔离验证 | 2026-09-25，本轮 | 生产 0088 备份 25,213,726 字节，隔离恢复、只读角色抽查 10 用户/50 条，列表 P95 23.13ms（该样本，不代表全量分位数）；synthetic PG 精度/分页/隐私通过 |
| 生产 API-only 切换 | 2026-09-25，本轮 | `business_release_guard.py deploy` 退出 0；服务器/工作站 HTTPS 200、账单匿名 401，运行时字段存在，日志 0 error/0 traceback，其他 27 容器未变 |
| 主线重放影响测试 | 2026-09-25 18:16 左右 | 仅后续 3 个提交涉及钱包监控与手工储备，账单源码未变；账单及相关钱包 126 passed，OpenAPI 检查退出 0 |

## 交接与回退

- 根因：生产 Business API 曾发布 `balance_after`，后续镜像丢失该只读字段；新版页面读取缺失值时显示未知。运行时 OpenAPI 同样缺字段，说明不是单纯客户端缓存。
- 范围：字段是历史流水顺序的累计读投影，不是交易提交时快照；目前不变更任何账本/财务写入。
- 风险：窗口查询随该用户历史流水增长，发布后观察账单延迟 P95；若候选未通过或线上回归，以当前运行 API 镜像与冻结配置回退。
- 隔离 PostgreSQL 测试包含 `drop_all`，只能使用确认是本任务独占的测试库，绝不能指向生产或共享数据库。
- 发布状态：候选镜像 `2547aafd…` 已作为生产 API 单服务发布，运行冻结配置 `/opt/starchat/releases/guarded-3v1b02yk/compose.json`。没有生产认证用户样本，不能声称真实用户账单已验收。候选/回退配置及数据库备份在服务器 0700 目录 `/opt/starchat/releases/bill-balance-20260925-01`，回退目标为切换前 `25954c6a…` 镜像；旧 `0087` 发布脚本不适用于当前 `0088`。独立测试 PG 容器已按其 ID/网络隔离核对后清理。
