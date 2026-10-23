# 可复现开发环境与模块门禁

## 恢复入口

- 用户授权：本会话用户再次列出的五项维护方案；正常同步须先审阅范围并通过适用门禁。不授权生产发布或业务逻辑改动。
- [计划](../../superpowers/plans/2026-10-23-maintenance-environment.md)；基线 `22706244b287667ec8c39d354f2f3dc94ada7d6b`。
- 工作树：`C:/Users/Administrator/.codex/worktrees/maintenance-completion/StarChat`，分支 `codex/maintenance-environment-20261023`。
- 文件所有权：计划列出的环境脚本、开发锁、行为测试及维护文档；主树既有 `.env`、发布工件和生产锁保持。
- 状态：验证完成，待合入和普通同步。新环境、7 项入口测试、最终 infra 919 项、独立 PG 专项 39+1 项通过；规格及质量/安全审查通过，完整 verify 退出 0。
- 本轮证据：主树 `docs/verification/artifacts/2026-10-23/maintenance-environment/`。

## 验收台账

| ID | 预期 | 当前证据 |
| --- | --- | --- |
| ENV-1 | 同一隔离 Python 3.12、平台锁和 pip check | bootstrap.json/log；生产锁 SHA 未变 |
| ENV-2 | stdin 非空执行、错误配置早失败、恢复调用者环境 | 7 项测试；原包装器 empty-success 及优化模式 RED/GREEN 证据 |
| GATE-1 | 唯一正斜杠 pytest 临时路径及完整 verify | full-verify.json exit 0，49m18.78s；最终入口及 infra 补验通过 |
| GATE-2 | 按模块列出 148 项历史条件跳过和执行条件 | 36 文件矩阵完成，144 PG 条件 +3 SQLite 适用性 +1 Ruby；另补 Worker 15 项入口，PG 专项 39+1 通过 |
| ARCHIVE-1 | 工作树之外受限备份与哈希复核 | D:/StarChat-maintenance-backups/2026-10-22-worktrees；28 文件复制校验，原副本保留 |
| GIT-1 | 全待推送范围审阅、正常同步、远程 SHA 核对 | 280 提交/3004 blob 扫描；独立 CI/发布审阅通过；尚未推送 |
| RELEASE-1 | Android2233/iOS2215 身份保持 | 移动与下载元数据 Git diff 为空，Android 最终 APK SHA 和主树配置哈希保持 |

## 阶段计时

精确执行时间以本轮 JSON 回执为准；最初探索起点未记录，记未知，不估算。

## 交接

完整 verify 已结束，临时 `.env` 校验哈希后删除；任务容器及专属匿名卷已清理。归档副本包含敏感配置/数据，只向当前用户及 SYSTEM 授权，不加入 Git。下一步复核远程漂移、提交、合入及普通推送；全部原始失败、条件跳过、历史引用限制保留。
