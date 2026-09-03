# docs/verification — 验证证据结构与保留策略

## 目录结构

```text
docs/verification/
├── <YYYY-MM-DD>-<topic>.md            # 单次验证的结论报告（日期前缀命名）
├── README.md                          # 本文件
├── screenshots/                       # 手工 UI 验证截图（按主题分子目录）
└── artifacts/
    └── <YYYY-MM-DD>/
        └── <topic>/                   # 当日某主题的原始产物（截图、日志、导出等）
```

## 放置规则（来自 AGENTS.md，重申）

1. 临时验证产物**只能**放在 `docs/verification/artifacts/<YYYY-MM-DD>/`（或 `docs/verification/` 下其他具名子目录）；仓库根目录不得出现 `MODIFIED_FILE`、`DIFF_FILE`、`VERIFICATION.txt`、`ROLLBACK.sh` 等验证产物。
2. 报告（`.md`）放 `docs/verification/` 根并用日期-主题前缀命名；原始大文件放对应 `artifacts/<日期>/<主题>/`。
3. 禁止在 `docs/verification` 之外（例如演示站或 app 目录内）建立平行的 verification 目录。

## 保留策略（2026-09-03 制定）

| 证据类型 | 保留期限 | 说明 |
|---|---|---|
| 财务/账本/红包对账、审计、E2EE 边界类验证证据 | **永久** | 属合规与审计链条，禁止清理 |
| 发布/回滚操作记录（ROLLBACK.sh、发布脚本副本、APK 审计） | 随发布归档，保留至产品下线 | 每次发布保留一份即可，重复的中间版本可清 |
| UI 截图 / Figma QA / 演示录屏等大体积媒体 | 自日期起 **90 天**，对应里程碑上线后即可清理 | 同一主题的多份重复截图只保留最终版 |
| 代码快照类证据（baseline/rollback 整目录拷贝、APK 解包 res 导出） | 自日期起 **30 天** | 仅供当次比对，git 历史可回溯，过期即清 |
| 一次性调试脚本（`*.ps1`/`*.py` 临时 dump） | 随所属主题证据一同清理 | 不作为长期工具维护；长期工具应上移 `scripts/` |

执行约定：

- 清理只删除 `artifacts/` 下的原始产物，**不删除**结论报告 `.md`（报告是证据索引）。
- 清理财务/审计/发布类证据前必须人工确认类别；拿不准时保留。
- 现存已知的清理候选（按上表口径）：`artifacts/2026-08-24/public-apk-audit-1/`（APK 整包 res 导出，代码快照类）、`artifacts/2026-08-28/admin-modernization/MODIFIED_FILE/`（整树快照，代码快照类）中与 git 历史重复的部分。
- 每次大批量清理在 `docs/verification/` 下新增一条日期前缀的清理记录（列出被删主题与理由）。
