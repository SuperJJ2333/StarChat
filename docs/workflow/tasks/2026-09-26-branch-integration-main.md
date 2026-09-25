# 2026-09-26 分支集成与 GitHub main 推送

## 恢复入口

- 目标与授权：用户要求把其他分支的已完成修改合入 `main` 并推送 GitHub，保持分支整洁；本任务仅做源码集成和 Git 推送，不发布新的 APK、IPA 或生产服务。
- 工作树：`C:/Users/Administrator/.codex/worktrees/merge-main-20260926/StarChat`，集成分支 `codex/integrate-branches-20260926`。原 `D:/pythonProject/outsource/StarChat` 的 `main` 工作树有 23 个已修改跟踪文件和 44 个未跟踪文件；本任务未改动、暂存或清除这些文件。
- 原基线：本地及远端 `main` 均为 `b9eca8a4`。合并 `codex/auth-login-2178` (`0ec8106a`) 产生 `49d9cac0`，再合并 `codex/online-room-refresh` (`0279b899`) 产生 `c2fe9f05`。首次推送后远端回读为 `c2fe9f05b6ce17648fe53815b06af1c836534d48`。
- 当前状态：源码已合并、验证并首次推送。此任务记录提交后再次回读远端 `main`，以该回读为最终状态。
- 最后更新时间：2026-09-26 05:38 +08。精确开工时间未记录。
- 下一步：提交本记录，推送并回读最终远端 SHA；保留其他任务的工作树与分支。

## 分支审计与集成决定

| 分支 | 处理 | 依据 |
| --- | --- | --- |
| `codex/auth-login-2178` | 合入 | 含 2179 四位 build、登录修复、全链路诊断与视频转码诊断；原分支验证和规格/安全审查已完成 |
| `codex/online-room-refresh` | 合入 | 含 iOS 旧身份保留恢复及 2173 分发源码；ADR-0086 与原分支审查、Mac 原生门禁已记录 |
| `codex/performance-debug-mi6` | 随前者合入 | `c000ebc1` 是 `codex/auth-login-2178` 的祖先 |
| `codex/performance-diagnostics` | 不重复合入旧提交 | 104 个原改动路径均在后续集成链中；75 个同内容，其余为后续帧归因、视频尝试等演进；未发现缺失的独有功能 |
| `codex/auth-login-six-fixes` | 不重复合入旧提交 | 23 个原改动路径均已由 `12d7fe5b` 等后续提交覆盖；未发现缺失的独有功能 |
| `codex/bill-balance-api-fix`、`codex/refresh-restore` | 无新改动 | 前者与原 `main` 同 SHA，后者为其祖先 |

三个文本冲突分别在 `app_config.dart`、`pubspec.yaml` 和 `current-state.md`。保留当前源码 `0.4.13+2179`、四位 build 精确归一化、iOS `olm` 直接依赖，并保留 2173 历史发布记录。自动合并的认证、会话、Matrix/E2EE 路径经独立静态复核，未发现合并引入的阻断问题。

## 验证台账

日志位于 `docs/verification/artifacts/2026-09-26/branch-merge/`（忽略目录），均针对集成工作树。Windows Flutter 3.44.9 / Dart 3.12.2；证据源码为 `c2fe9f05`，文档追加不改变可执行输入。

| 门禁 | 结果 |
| --- | --- |
| `flutter analyze --no-pub lib test` | exit 0，`No issues found` |
| Flutter 定向登录、身份恢复、Matrix、构建号与性能测试 | exit 0，263 通过；独立交叉审查另跑相关 41 项通过 |
| `flutter test --no-pub` | exit 0，4443 通过、9 跳过 |
| `npm test`（frontend） | exit 0，311 通过 |
| `pytest tests/mobile -q` | exit 0，238 通过、1 跳过 |
| `pytest tests/infra -q` | exit 0，147 通过 |
| `pytest tests/getui_bridge -q` | exit 0，28 通过；2 个既有弃用警告 |
| `pytest tests/matrix_bot -q` | exit 0，9 通过 |
| UI contract、OpenAPI check、Compose render、Alembic 单头与离线升级 | 均 exit 0 |
| `scripts/verify.ps1` | exit 1：独立工作树无 `.env`，停在配置渲染；此前 Repository/Deployment policy 与 TemplateTools 均通过。尝试从示例配置生成临时 `.env` 被自动审批以 `blocked by policy` 拒绝；未创建该文件，也未绕过审批 |
| Business API/Worker 全量 | 复用 2179 原分支 `verify.ps1` exit 0 的 2905 通过、75 跳过：本次 iOS 分支合并未改变 `services/business-api`、`services/business-worker`、`tests/business_api`、`tests/business_worker` 的任何路径。一次重复运行到 16% 后主动中止，保留中止日志，不把它记作本次通过 |

## 剩余限制与回退

- 本次没有新包或生产服务部署。2179 真正的视频发送结果仍需设备实测；iOS 2173 的健康旧机保留数据覆盖与 Mac 原生门禁沿用原分支证据，未把 Windows 测试写成 iOS 真机验收。
- iOS 身份恢复取消后页面内缺少直接续行入口，是原分支既存体验限制，不是此次合并产生。
- 原 `main` 工作树的未提交修改与未跟踪文件归其他任务所有，未纳入 GitHub 推送。其他任务的工作树和分支不删除、不重置。
- 此次仅普通快进推送；如需回退，先依据远端后续提交和发布状态另行审查，不强推覆盖。

## 阶段计时

| 阶段 | 起止 | 类型 | 证据 |
| --- | --- | --- | --- |
| 审计与隔离工作树 | 精确起止未知 | 主动/工具并行 | 分支/工作树状态与 merge-base 盘点 |
| 合并与冲突复核 | 精确起止未知 | 主动/独立审查并行 | `49d9cac0`、`c2fe9f05`，仅三处文本冲突 |
| Flutter 全量 | 2 分 42 秒 | 工具 | `flutter-full.log` |
| 其余分项验证与推送 | 截至 05:38 +08 | 主动/工具 | 本节退出码、远端回读 |

总墙钟因开工时间未记录，保持未知；未将并行工具时间相加。
