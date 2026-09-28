# 按服务实际运行路径验证续期协议镜像门禁 ADR

- 日期：2026-09-28。
- 状态：**用户已批准（2026-09-28）**；仓库内修复及聚焦测试完成，生产门禁已安装。批准时业务服务尚未切换；随后独立恢复 r2 的候选/回退 API 与 Worker 镜像逐角色检查通过，r2 已仅切换 API，管理台 A1–A5 截至 2026-09-28 17:41 UTC 尚未切换。实施证据见[恢复验证](../verification/2026-09-28-restore-identity-moments.md)。
- 适用：`business-api`、`business-worker` 的候选与回退不可变镜像；受控发布器的 `check`、`freeze`、`deploy`、`rollback`。

## 已核实的问题

现行 `business_release_guard.py` 对每个镜像运行同一份 `business_refresh_image_probe.py`。探针固定把 `/opt/business-api` 放到 Python 导入路径首位，再创建 ASGI 应用并执行 9 项移动端/后台续期协议断言。2026-09-28 管理台候选 API 镜像与当前生产 API 镜像分别用**原始门禁**单独运行，均 9/9 通过。现行 Worker 镜像单独运行失败；它实际以 `/opt/business-worker/app/main.py` 启动，业务 `app` 包从 site-packages 导入。Worker 内另一份 `/opt/business-api` 是不参与 Worker 运行的旧副本；site-packages 只包含 Worker 所需业务包，不提供完整 ASGI 路由，故不能对该镜像真实执行 API 的 9 项 HTTP 断言。原 `check` 聚合三个镜像失败，未写入部署资格，线上服务、静态和数据库均未切换。

当前[续期发布规则](../runbooks/refresh-release-guards.md)要求最终 API 与 Worker 镜像都通过协议门禁。按旧路径强制测试 Worker 的非运行副本，不能证明其运行能力；省略 Worker 镜像也不能满足双角色检查。

## 获批决策

发布门禁为每个镜像显式绑定 `api` 或 `worker` 角色，检查候选与回退两侧的实际不可变 SHA、与实际 Compose 服务的对应关系。缺角色、角色错配、镜像漂移、探针异常或证据不完整时，均在写冻结配置或切换前失败关闭。

`api` 角色继续在最终镜像内按现有禁网、只读、无额外能力的容器条件执行原 9 项 ASGI 续期协议断言；既有断言、接受标准和候选/回退两侧要求不放宽。`worker` 角色在同等隔离条件下，以 Worker 的实际入口和导入路径执行 8 项检查：运行路径、身份凭据事件注册与安全字段边界、共用 TokenService 的同结果不延寿/超前结果/错配重放/旧式轮换，以及 T2 链源精确超时只记 `MANUAL_SOURCE_UNAVAILABLE` 事故且不自动暂停；同时核对 Worker 告警模块的导入来源。告警投递由现有 Worker 专项测试另行证明。探针必须校验导入来源，防止回落到旧 `/opt/business-api` 副本。Worker 不能提供的 ASGI 路由不再作为其通过依据。两种证明连同镜像 ID、探针版本及 Compose 快照写入 0700 发布记录。

门禁脚本和探针的改动先在仓库内测试，经过规格/领域及质量/安全审查，再按原有主机密钥与跳板流程安装。安装前保存生产门禁与探针原件、权限和 SHA，安装后校验两个新 SHA。发布器清单同时绑定新门禁与探针 SHA；旧发布包和原先的失败检查不得当成新包的证明。`check` 必须提交至少一份 `--api-image` 与 `--worker-image`；`deploy/rollback` 必须从完整 Compose 验证两角色，即使只用 `--service` 切换 API。候选与回退两侧的 API 9 项和 Worker 8 项都必须由最终镜像证明。回退仍通过同一门禁检查回退镜像与实际配置；不撤销已发生的密码变更、安全审计或 Outbox。

## 验证与发布条件

1. 测试先证明旧门禁会针对现行 Worker 的非运行 API 副本失败，再证明新门禁拒绝角色缺失/错配、可变镜像、非运行导入路径、失败或缺项的 Worker 探针，并在任一失败时不写冻结配置、不切换。
2. 对候选和当前回退 API 镜像运行原 9 项 ASGI 协议断言；对候选和回退 Worker 不可变镜像运行新增 8 项实际运行路径探针。候选与回退必须各自关联到不可变镜像和角色；若两侧 Worker 使用相同 digest，可复用同一镜像内证明。全部证明使用禁网、只读、无额外能力的临时容器，记录退出码及去敏结果。
3. 仅在新清单的精确文件 SHA、0700 备份、隔离 PostgreSQL 恢复和四项账号并发竞争、最终 Compose/schema/静态重冻，以及两阶段独立审查均通过后切换。生产不为验收触发真实短信、邮件或资金写入。

批准此 ADR 不等于批准某个发布包上线。独立 r2 恢复已经完成门禁安装、对应最终镜像证明和 API-only 切换；管理台 A1–A5 仍需其最终镜像证明、隔离 PostgreSQL 竞争测试、发布前重冻与现网验收，见[管理台验证记录](../verification/2026-09-28-admin-entry-merge.md)。
