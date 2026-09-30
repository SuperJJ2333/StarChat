# Outbox 内部发布回执与配置漂移维护

本手册对应[修复任务](../workflow/tasks/2026-09-27-outbox-gateway-reconciliation.md)及[验证报告](../verification/2026-09-27-outbox-gateway-reconciliation.md)。运行身份以最新生产证据为准，旧任务镜像不能覆盖新 API。

## 内部消费者

Worker 对 11 个内部审计 topic 注册精确消费者：admin、friendship.events、identity、identity.staff、identity.wallet_access、ledger、moments、moments.events、recharge、wallet、wallet.incident。146 个 `(topic,event_type,aggregate_type)` 契约及完整 payload/header 校验定义于 `services/business-worker/app/tasks/internal_publication.py`，不得使用通配符或为未知事件注册空消费者。

生产者事务中的业务事实、原审计和 Outbox 已经提交。消费者只通过公共 `AuditWriter.record_internal_publication` 接口追加耐久内部发布回执，提交后才由既有 Worker 确认事件。回执 ID 由事件 ID 确定性 UUID5 派生；摘要覆盖完整稳定信封，排除租约和重试次数。回执只保存版本、topic、type 和 SHA256，不复制 payload、消息正文或媒体内容。重试严格核对原回执，冲突和存储失败继续显式失败。

此消费者不执行钱包、账本、充值等业务命令，也不替代 notification 公告分发或 wallet.alert 邮件发送。原九个 handler 保留。新增契约必须先找出真实公开 producer，包括继承的 `_audit` 调用链，写实际 producer→Outbox→Worker 的失败测试，再做规格/领域及质量安全审查。

## 死信与观察

历史 DEAD 保留原状态、错误、尝试次数和完整行；本批不重设 PENDING、不重放金融或未知事件。不要以旧死信总数判断新消费者是否有效，也不要清理历史记录来让监控变绿。确需处理某历史事件时，单独核实其业务语义、幂等及授权。

生产观察使用本任务冻结的 `outbox-postrelease-observe.py`：只读、REPEATABLE READ，连接/语句/锁超时分别为 5/10/2 秒，扫描上限 2000。历史集合 ID 仅存在服务器 root 私有目录；公开证据只包含数量和摘要。

发布观察的 cutoff 必须等于实际新 Worker 的 StartedAt，固定镜像及容器 ID，至少跨过 600 秒。`manual_reserve.published` 和 `wallet.funding_scan_discovered` 两类真实新事件都必须 PUBLISHED 且与确定性完整回执匹配；无新增失败/死信、非法信封、回执缺失或冲突、超期租约、截断及对应新日志错误；冻结历史集合完整行摘要必须不变。硬失败在宽限期内也立即失败，禁止移动窗口绕过早期失败。

## 发布与回退

读取[生产工作流](admin-production-workflow.md)，通过严格 SSH 跳板核实当次镜像、完整运行配置、实际导入路径、PHONE/S3 挂载与 schema。只有 Worker 是本批切换目标，源 Compose 中的旧 API pin 不能一同发布。

本任务服务器目录为 `/opt/starchat/releases/outbox-gateway-20260927`。公开 v3 候选只覆盖 Worker main、内部消费者及 AuditWriter 两个实际副本，共四路径；所有其他源文件保持。manifest、归档、FROM 和完整四条 COPY 逐一固定，COPY 按固定路径顺序校验，不能受 JSON 字典排序影响。先 prepare，隔离 Linux 实际源码与非空 producer 测试通过后再 publish，配置投影仅含 Worker，Compose 使用 `--no-deps --force-recreate business-worker`。

私有配置、源库存和发布 journal 留在服务器 0700/0600 目录，禁止下载或打印。发布工具检查祖先权限、持锁 FD/inode、运行配置、源码及其他容器身份，切换后再复核。失败时仅在当前候选仍属于本批、完整配置及其他容器没有漂移时，恢复冻结的 S3 主写 parent 与 Worker-only before 配置；保留追加审计回执，不执行数据库 downgrade。外部发布造成身份变化时停止恢复，重新调查。

后续 prepare 必须在重建前保存完整旧容器 Docker Inspect、镜像 Inspect 与 effective Compose 的 root 私有快照，分别固定 SHA、身份和权限；仅保存单个运行指纹不够，容器重建后无法逆推出差异字段。本批旧阶段存在这个证据缺口：旧 `VERIFYING` journal 和原不匹配指纹明确保留，不能改写为相等，也不能把当前候选快照伪装成旧容器快照。

针对该证据缺口，新的独立验收工具须完整核对冻结 before/candidate Compose 仅镜像变化、父/候选镜像配置相等，以及所有实际 Config/HostConfig/挂载/网络/安全/资源/日志配置；每个期望值均有冻结配置、镜像继承、固定 Docker 生成规则或单独明确批准的当前期望策略来源，未知选项直接拒绝。单独策略不能称为旧容器的历史默认值；本批完整 typed literal 策略及其精确 SHA 的批准另有证据。经规格与质量安全复审、精确候选身份/源码/私有锁及其他容器前后 CAS 通过后，才可另存完整当前私有快照及 `ACCEPTED_BY_FROZEN_CONFIG` 标记。该标记证明当前满足冻结配置及批准策略，不代表已还原旧指纹差异；禁止反复运行旧 publish 或为绕过守卫直接改旧 journal/hash。

该补充验收是一次性操作：发现已有canonical验收标记时，即使当次配置和快照校验通过，也不得自动判为首次提交完整成功，须独立核实完成证据。首次成功后读取标记与证据，不重复执行accept。若写入后的检查失败，必须以先前持有目录及marker FD的精确归属安全退休本工具标记，拒绝触及外来替换文件；不能让同一权限失败挡住撤销后遗留成功标记。

容量监控 timer 仅在短暂 prepare/publish 操作中暂停，等待其一次性服务结束；远端 EXIT trap 与本地 finally 双重恢复并验证原 enabled/active 状态。观察期内监控正常运行。

## 模板一致性

先做全字段且保留 YAML 类型的语义比较，验证实际 Synapse `/data` 挂载、PID1 配置入口、宿主/容器文件 SHA；不能仅比较配置路径。nginx 现网字节、登录 broker、register/SSO 拒绝、管理入口隐藏、iOS 限流、五条 TURN 和 S3 同步写均需保持。

模板同步后运行真实 `render_config.py --check --require-production`，确认退出 0。nginx 字节不变无需 reload；Synapse 全字段语义不变仅格式同步时保留 inode、UID/权限，无需 restart。用严格 TLS 的公开 ready/login/register/admin 路由分别验证香港和新加坡边缘。


## 本批已完成验收身份

2026-09-28 02:15+08现场已完成helper47bb03f9的独立ACCEPTED_BY_FROZEN_CONFIG，marker SHA c4ea05389ec8dfb63df01f4278f225c3101fbc6028228fd246ea81a0bd3c2c26。目录名固定为本批完整Worker CID、e8f777策略SHA及47bb工具SHA拼接，位于服务器private/worker-release/desired-runtime-acceptance下；完整文件不下载。六快照root0600及目录0700的metadata/SHA已验证。旧7fc06744/VERIFYING保留，历史指纹相等证明缺口不被此当前验收消除。不要再次执行`--accept-current-runtime`；后续发布重新建完整旧快照与新固定身份。最后观察6045.611秒374条全部发布及回执匹配，历史集合保持；该有限窗口不代表历史死信已清零。
