# 文档归并验证

基线2525e63a；用户授权docs根目录和runbooks归并。纯文档变更。

- 22份历史正文归档到docs/archive/2026-09-20；6份资料迁入architecture/testing/runbooks。
- 28份正文与Git基线逐份比较：仅重定位Markdown链接和添加状态说明，内容无丢失。
- 改动中本地Markdown路径检查295条通过；新增任务/报告索引另作最终复查。
- Repository policy和Deployment policy通过；应用全量/构建不适用于本次纯文档任务。
- 原文SHA、映射及检查结果保存在docs/verification/artifacts/2026-09-20/docs-consolidation/；不删除财务、加密或历史验收证据。

当前入口：[文档总索引](../README.md)、[运行手册](../runbooks/README.md)、[归档索引](../archive/2026-09-20/README.md)。旧路径保留兼容短页。

最终全改动路径检查：68份Markdown、415条本地链接，无新增失效；current-state原有media-engine-phase4/deployment-evidence.md为未随Git分发的本地工件，独立worktree缺失，未伪造补齐。
归并映射及原文SHA：[归档清单](../archive/2026-09-20/catalog.json)。
