# 恢复已发布资料规则与朋友圈互动隐私 Implementation Plan

状态：**用户已批准先独立恢复并发布，再发布管理台**（2026-09-28）；角色化镜像门禁 ADR 同次获批。独立 r2 已于 2026-09-28 15:14:50 UTC 完成 API-only 发布与 verify，后续严格 TLS 匿名探针通过；真实产品会话反馈仍待用户。执行证据见[恢复任务](../../workflow/tasks/2026-09-28-restore-published-identity-moments.md)与[验证记录](../../verification/2026-09-28-restore-identity-moments.md)。这是 2026-09-28 管理台完整门禁中发现的现网回归，独立于 A1–A5；恢复的是 2026-09-24 已批准并发布的行为，依据 [ADR-0085](../../adr/0085-profile-visible-character-limits.md) 与[当次发布记录](../../verification/2026-09-24-me-invitations-moments-interactions.md)。两次发布使用独立清单和回退单元。

## 恢复前已核实的基线和影响（历史）

- r2 发布前生产 API 镜像 `sha256:2b847ef70e0257f4ba52e663812112d7664016ff427d454c32630da1b0c89a63`、Worker `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`，schema 为 `0091_moment_video_posters`；当时管理台尚未切换。2026-09-24 发布的 API `sha256:c41dfffc30a3b52f0af179cf58aebfb0ce58db26c09d333881906a01755b7ba9` 由 `release-preserve-046/api-overlay` 再叠加 `cursor-v2` 的 Moments 修复构建，曾验证资料 12/20 字素、审计去原文与互动通知隐私/分页；后续生产镜像退回旧实现。
- 恢复前 `registration.py` 与当时运行容器相同，相关注册文件聚焦为 17 passed/5 failed；邮箱注册昵称 13 字素可通过，且恢复 12 字素规范时缺旧摘要的兼容判定，重放重复写创建审计。当时旧哈希规则下的原样请求仍可重放，不能称幂等机制整体缺失。当时 `profile.py` 把原始昵称和签名写进审计，`profile_text.py` 与锁定 `regex==2026.2.28` 依赖在旧镜像缺失，ORM 资料字段仍映射旧长度，虽然数据库已有 0088 的 `Text` 列。
- 恢复前 `moments.py` 与 `moments/service.py` 均与当时运行容器同 SHA，互动相邻测试聚焦为 2 passed/20 failed；旧通知投影可暴露失效关系下历史 LIKE actor，缺回复通知、安全 DTO、游标分页和失效历史保留。已发布新客户端遇到缺 `target_available` 的旧响应会将互动视为不可查看。该历史证据未证明从此路径直接泄露评论正文。

## Task 1：隔离与精确合并

- [x] 建立独立工作树和任务记录，声明本恢复任务拥有身份/资料、Moments 两个模块及 OpenAPI 对应文件；不得编辑管理台工作树的同名文件。读取当时运行镜像、Compose、schema、源码和 9 月 24 日私有发布 overlay 的精确 SHA，逐文件列出本次恢复差异。
- [x] 将 ADR-0085 已批准的字素校验、默认昵称截断、旧 COMPLETED 幂等回放、不重复审计与资料审计去原文，移植到当时生产源码：`app/modules/identity/{registration,profile,profile_text,models}.py`、`app/api/{identity,profile}.py`。保留现行手机号注册、用户名声明、管理会话和 0091 数据模型。使用 2026-09-24 已核验的 `regex==2026.2.28` Linux wheel（SHA256 `d6b08a06976ff4fb0d83077022fde3eca06c55432bb997d8c0495b9a4e9872f4`），固定锁文件和离线安装方法，并在最终镜像中验证实际安装、版本与导入。已有 0088 表结构保持，**不新增或重跑迁移**。
- [x] 将已发布互动通知的 REPLY、历史泛化安全投影、受众复核、keyset 分页、未发布/失效状态门槛移植到当时 `app/modules/moments/service.py` 与 `app/api/moments.py`；保留现行 0091 视频海报、草稿和媒体权限。更新 OpenAPI 并核对移动客户端解析字段。

## Task 2：红绿与双审查

- [x] 复用已记录的注册 5 项和互动 20 项红测及真实退出码；新隔离输入变化时再跑相应基线。补跑资料明文审计/字素专项红测。新增必要测试只覆盖风险：旧 COMPLETED 摘要兼容回放不重复邀请消耗、Outbox 或审计，昵称/签名字素边界、审计无原始值、失效互动 actor 泛化、REPLY 与游标分页、现行手机号/用户名/视频海报不回退。
- [x] 最小实现后重跑以上专项、相邻身份/媒体/朋友圈测试、OpenAPI `--check`、唯一 Alembic head/offline 升级，以及可运行或按同输入复用的相关门禁。`scripts/verify.ps1` 在独立树缺 `.env` 的限制仍按[验证记录](../../verification/2026-09-28-restore-identity-moments.md)如实记录，不把未跑门禁写作新通过；Business API 完整复跑 2837 passed/78 skipped、exit 0。
- [x] 先做已批准行为的规格/领域审查，再做质量/安全审查，尤其核对审计/Outbox、现行手机与用户名路径、失效互动隐私及账本/钱包模块未变。

## Task 3：独立受控发布与回退

- [x] 完成已获用户批准的[角色化镜像门禁](2026-09-28-role-aware-refresh-image-gate.md)的本地/生产安装验收；r2 最终不可变 API/Worker 候选和回退镜像全部通过。
- [x] 用当时生产镜像做最小 API 覆盖和锁定 wheel 构建，冻结 SHA/Compose/schema/静态，做 0700 私有备份及禁网隔离 PostgreSQL 恢复。Worker 未重建、未覆盖 T2；候选 API 保留 0091、T2 与后续已发布手机/用户名行为。验证回退镜像和 API 契约后，单独切换此恢复包。
- [x] 用服务器及工作站经 jumper 的严格 TLS HTTPS 核验 API JSON 健康、未授权拒绝、路由/资源/镜像身份与其他容器不变；有权限的真实用户互动、注册与资料修改仍单列人工反馈，不代用户触发真实短信、PII 或资金写入。
- [x] 恢复包稳定后，以其**新生产镜像**重冻管理台 A1–A5 候选和回退基线，重新跑受影响专项与精确发布清单，不复用旧 v1/v2/v3 管理台包的 SHA；管理台发布另按其自身计划与验证记录继续。

## 审批点

用户已确认先按本计划隔离修复、验证并独立发布，再以恢复后的镜像发布管理台；角色化门禁 ADR 也已批准。r2 的最终镜像、隔离恢复、双审查与现场校验已通过并完成 API-only 切换；管理台生产切换仍按独立计划及最终候选门禁执行。
