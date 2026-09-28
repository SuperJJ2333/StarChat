# 恢复已发布资料规则与朋友圈互动隐私

## 恢复入口

- 目标与授权：用户于 2026-09-28 明确选择先按[独立恢复计划](../../superpowers/plans/2026-09-28-restore-published-identity-moments.md)修复已确认的资料审计与朋友圈现网回归，再以恢复后的生产镜像发布管理台 A1–A5；同次批准角色化双镜像门禁 ADR。恢复范围是 2026-09-24 已发布但当前生产回退的字素、审计、完成请求重放及朋友圈通知隐私/分页，不改变钱包、资金或 Matrix 行为。
- 当前状态（截至 2026-09-28 23:19 +08:00）：身份/资料与朋友圈红绿和完整 Moments 164/164 已通过，源码规格/领域审查及 r2 独立增量质量/安全审查均 PASS，后者无 P0–P3。首次完整 Business API 套件的五项现网旧断言经三个测试文件最小同步；修正 Worker tasks 的 PYTHONPATH 后，[完整复跑](../../verification/artifacts/2026-09-28/restore-identity-moments/business-api-full-pass-2.log)真实 exit 0：2837 passed、78 skipped、1 条环境弃用 warning，耗时 2252.75 秒。r1 探针失败审计原样保留。独立 r2 已完成上传、0700 私有备份、禁网构建与 PG 克隆探针、克隆清理及生产 API-only 切换；2026-09-28 15:14:50 UTC 的发布器 verify 通过。现网 API `sha256:8015e9637fb33c3cf07995612ba1680dbdd3acec4705dee062803517d4bd26d3`，Worker 保持 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`，schema 保持 `0091_moment_video_posters`。服务器及工作站跳板 SOCKS 严格 TLS 公网探针均通过；真实用户资料/互动仍待产品会话反馈。
- 负责人及文件所有权：独立受管 worktree `C:\Users\Administrator\.codex\worktrees\restore-identity-moments\StarChat`，分支 `codex/restore-published-identity-moments`，基线 `971fb50d193ab1a34610bd7908c2dbf6272db431`。Identity 代理只改 `services/business-api/app/modules/identity/{registration,profile,profile_text,models}.py`、`app/api/{identity,profile}.py` 及聚焦测试；Moments 代理只改 `app/modules/moments/service.py`、`app/api/moments.py` 及聚焦测试；根任务拥有依赖锁、OpenAPI、计划/台账、门禁与发布包。代理不得同时编辑同一文件。
- 现网基线：从管理台只读快照复制当前生产 API 43 文件、Worker 5 文件；追加按当前镜像 SHA 验证的 API `network_request_timeline.py` 和其他 11 个文件、Worker `avatar_cleanup.py`。完整清单为 API 248 个 Python 文件：本地仅 7 个预期现有 payload 路径与运行镜像不同，外加现网缺失的 `profile_text.py`；Worker 20/20 文件与运行镜像相同。`profile_text.py` 必须作为新增发布 payload 明确核对。此工作树无 `.codegraph/`。
- 最后更新：2026-09-28 23:19 +08:00。
- 下一步：等待真实产品会话对资料编辑、旧完成请求重放和朋友圈互动的反馈；管理台 A1–A5 须以本次**新生产 API 镜像**重新逐文件冻结、合入恢复行为后另行发布，旧 v3 包不得复用。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| R1 | 昵称 12、签名 20 个可见字素，复杂 emoji 计 1；旧长值可读、只校验改动字段 | 已实现 | 资料聚焦 RED 29 pass/10 fail、GREEN 39/39；相邻身份 43/43；完整 API 2837 pass/78 skip，exit 0 | r2 API 已发布；匿名探针通过 | 真实用户资料操作待反馈，资料不写入证据 |
| R2 | 旧 COMPLETED 请求仅精确键/身份/哈希只读回放，不重复审计、邀请消耗或 Outbox | 已实现 | 资料聚焦 39/39；空白推荐码同键重放 RED 1 fail→GREEN 1 pass、相邻 67/67；r2 禁网 PG 恢复和只读探针通过 | r2 API 已发布；匿名探针通过 | 真实请求重放待产品会话反馈 |
| R3 | 资料审计不记录原始昵称/签名 | 已实现 | 资料聚焦 39/39；规格/领域审查通过；上线后聚合日志无 JSON ERROR/CRITICAL | r2 API 已发布；匿名探针通过 | 真实资料写入审计待产品会话反馈，不采集原文 |
| R4 | 朋友圈 LIKE/REPLY 通知安全投影、失效关系保护、游标分页和未读数 | 已实现 | 现网互动 2 pass/20 fail、恢复后聚焦 22/22；完整 Moments 164/164 | r2 API 已发布；匿名探针通过 | 不代用户产生真实互动；产品会话待反馈 |
| R5 | 保留 0091 视频海报、手机号/用户名、Worker T2 与现行资金边界 | 本地回归通过 | 视频海报 27/27、用户名 17/17；Worker 本地 115/115，双角色镜像门禁通过；完整 API 2837 pass/78 skip，exit 0；发布 verify 0091/八目标/其他容器通过 | r2 仅切 API；Worker/静态/迁移未切 | 资金写入与真实业务路径不由匿名探针证明 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| r2 发布前 API 基线 | `sha256:2b847ef70e0257f4ba52e663812112d7664016ff427d454c32630da1b0c89a63` | 生产快照 | Docker | 管理台任务的只读 `live-source/api`，本工作树 43/43 匹配 | 2026-09-28，历史回退基线 |
| 当前生产 Worker | `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf` | 生产快照 | Docker | 同上 `live-source/worker`，本工作树 5/5 匹配 | 2026-09-28 15:14:50 UTC，未切换且 healthy/零重启 |
| 已发布行为参考 API | `sha256:c41dfffc30a3b52f0af179cf58aebfb0ce58db26c09d333881906a01755b7ba9` | 9 月 24 日最终覆盖件 | Docker | [发布记录](../../verification/2026-09-24-me-invitations-moments-interactions.md) | 历史基准，非当前生产 |
| 失败保留的恢复包 r1 | 候选 API `sha256:65e0974113572c8ca5777844261ce110e30e63d16a21ce3cc847bc65ce37ef13`，生产未切换 | 当前恢复工作树 | API 8 文件+离线 wheel | manifest SHA `9531c7da3311a59900e9df4f48ea4369e04509f5e52f2682ab2c55fb57c8bcb7`；archive SHA `f46ebe6385aefeedd8de4291fd5e8f5b78aaa6184fea01fb3895ccffb1e5237a` | 2026-09-28，隔离 PG 探针失败，保留审计 |
| 已发布的恢复包 r2／当前生产 API | `sha256:8015e9637fb33c3cf07995612ba1680dbdd3acec4705dee062803517d4bd26d3`；Worker 仍为 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf` | 当前恢复工作树 | API 8 文件+同字节离线 wheel，Worker/静态/迁移 0 | [manifest](../../verification/artifacts/2026-09-28/restore-identity-moments-release-r2/package/manifest.json) SHA `d69138a8499b71ccd28933b4bd0911b646736813a7fa3b541d0969075d34625e`；[archive](../../verification/artifacts/2026-09-28/restore-identity-moments-release-r2/restore-identity-moments-20260928-r2.tar.gz) SHA `4da255803e61a606970c4ddbd9bddbf630d6afe0d1205cc179fc5d6c9b40ad61` | 2026-09-28 15:14:50 UTC 发布 verify exit 0 |

## 阶段计时

| 阶段 | 开始（含时区） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 恢复授权与隔离基线 | 2026-09-28 20:58 +08:00（近似） | 2026-09-28 21:07 +08:00 | 工具等待与主动核对交错 | 根任务、Identity、Moments、门禁文档 | 新 worktree 创建；48 文件 SHA 一致；无生产写入 | 红测与最小移植 |
| 生产基线补齐与门禁安装 | 2026-09-28 21:25 +08:00（近似） | 2026-09-28 21:37 +08:00 | 主动核对、工具运行 | 根任务、恢复包、朋友圈 | API 248 文件清单仅余 7 个预期差异；Worker 20 文件镜像一致；门禁安装包 SHA `3a15381b…`，旧版私有备份 `role-aware-guard-20260928-d0_vhuqs`，新 SHA `78b2beb6…`/`d77a83e8…`，当前镜像 API 9/9、Worker 8/8 | 候选/回退双角色检查 |
| 源码冻结与本地发布包 | 2026-09-28 21:38 +08:00（近似） | 2026-09-28 21:55 +08:00 | 红绿、审查、工具运行交错 | 根任务、Identity、Moments、规格、恢复包 | 朋友圈 164/164；空白推荐码红绿/相邻 67/67；规格通过；248→249 仅 8 差异；包 23/23 与归档 SHA `f46ebe63…` | 完整 API 与质量安全审查 |
| r1 隔离探针失败与根因定位 | 2026-09-28 22:00 +08:00（近似） | 2026-09-28 22:08 +08:00（近似） | 私有备份、候选构建、失败复现与诊断 | 根任务、质量安全、排障 | 0700 备份 SHA `a0629a8d…`；候选镜像 `65e09741…` 与回退双角色通过；禁网克隆 0091 恢复成功；探针 exit 1；同备份新诊断克隆测得地址 `127.0.0.1/32`、只读 `on`、0091、138 表，r1 错比 `127.0.0.1`；生产未切换 | 新 r2 探针/发布 ID |
| r2 独立准备与隔离验证 | 2026-09-28 22:08 +08:00 后（近似） | 截至 2026-09-28 22:21 +08:00 | 本地探针 RED/GREEN、全新服务器私有备份/构建/克隆验证 | 根任务、恢复包、质量安全 | r2 archive `4da25580…`、manifest `d69138a8…`；独立 root 0700 发布目录；validate/preflight 0091；private 0700/文件 0600，备份 SHA `c32fea3a0df88ee34c92f072517cb181c22dc01184c64ca7f49e834e835011e7`；候选 API `8015e963…`、Worker 原镜像，regex 2026.2.28、候选/回退双角色门禁通过；禁网克隆探针 true、finalize 已删除克隆；生产未切换 | 完整 API 套件结束后再核对切换 |
| 首次完整 API 与旧测试断言核对 | 完整 suite 起点以日志为准 | 2026-09-28 22:26:53 +08:00（日志最后写入） | 工具 2265.06 秒；五项聚焦红绿及独立审查 | 根任务、恢复包、质量安全 | 首次完整 suite 2832 pass/78 skip/5 fail；搜索函数现网与恢复源码片段 SHA 均为 `a58f91521c35bd0ab18ef1cad3579fa97ea01b3cab425820c663978dc7adfcc4`；仅三测试文件更新，五项 RED→GREEN 5/5、三文件 171/171、枚举收紧后相关 9/9；增量质量/安全审查 PASS 无 P0–P3 | 正确 PYTHONPATH 下复跑完整 suite |
| 完整 API 复跑环境修正 | 2026-09-28 22:33:26 +08:00 前（首次复跑日志） | 2026-09-28 23:12:53 +08:00（成功日志最后写入） | 首次复跑缺 Worker tasks PYTHONPATH，收集 2 错、4.05 秒；修正环境后重启 | 根任务 | `business-api-full-pass.log` 的 2 个 `ModuleNotFoundError: tasks` 属测试收集环境；[成功复跑日志](../../verification/artifacts/2026-09-28/restore-identity-moments/business-api-full-pass-2.log)真实 exit 0、2837 pass/78 skip/1 环境弃用 warning，测试自身 2252.75 秒 | 生产切换前预检 |
| r2 生产切换与双路径验收 | 完整 API exit 0 后；精确开始时间未记录 | 2026-09-28 23:14:50 +08:00（发布器 verify UTC 时间） | 预检、API-only 切换、服务器/工作站公网核验 | 根任务 | 切换前 preflight exit 0、schema 0091；deploy exit 0，API `8015e963…`，Worker 原镜像未切；verify exit 0，八目标 SHA、schema 0091、其他容器不变。服务器及工作站跳板 SOCKS 严格 TLS ready JSON + 两项未授权 401 均 exit 0；工作站隧道已关闭。API/Worker healthy、重启数 0；上线后日志 Traceback 0、JSON ERROR/CRITICAL level 0，含 `ERROR` 字样行仅聚合 `event=client_diagnostics`。 | 等待真实产品会话反馈；管理台 A1–A5 重冻新基线 |

总墙钟待完成后按事件时间计算；开始时刻近似，不作为精确计费依据。重复工作：沿用管理台任务已有只读生产快照，发布前再作现场确认。

## 交接与回退

- 根因：当前生产镜像在 9 月 24 日已发布的资料规则和互动投影之后构建，却包含旧实现；具体覆盖阶段仍需通过候选差异证明，不据此猜测操作者或部署原因。
- 待办：真实产品会话中的资料编辑、完成请求重放与朋友圈互动反馈仍待用户；匿名 ready/401 探针不能替代业务操作验收。管理台 A1–A5 下一步必须按新生产 API 镜像重新冻结，并保留本次已恢复的八个 API 文件及锁定依赖。
- 发布状态：r1 已上传并完成私有备份、候选构建及克隆恢复，但探针失败；其 `restore-running.json` 绑定已删除的克隆 ID，不能覆盖或伪造后继续，原私有审计保留。r2 在全新 `/opt/starchat/releases/restore-identity-moments-20260928-r2`（root 0700）完成备份/构建/禁网恢复和探针 finalize，随后仅切换 API；Worker、schema 0091、静态未切换。2026-09-28 15:14:50 UTC verify exit 0，严格 TLS 双路径匿名探针通过。
- 回退：按 r2 冻结包的已审查回退流程仅恢复旧 API 镜像与 Compose；Worker、schema 0091 和独立管理台静态保持原状，不执行数据库 downgrade 或回灌。回退前重查当前镜像/Compose/其他容器和目标 SHA，不能跨越后续发布。
