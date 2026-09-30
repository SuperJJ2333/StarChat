# 新加坡边缘/TURN与S3分批发布计划

用户2026-09-27明确要求部署边缘/TURN与S3媒体，继承既有方案授权；无需再批准相同部署。主区仍香港，不购买RDS、不切主域名，不改变认证/E2EE/账本，不删除本地媒体。

## 执行顺序和所有权

1. 根代理：当次HK/SG运行基线、AWS权限、DNS/EIP、S3身份、任务/证据/本文/ADR状态。隔离worktree `C:/Users/Administrator/.codex/worktrees/sg-edge-s3/StarChat`，Git b9eca8a4；最新服务源码逐归属文件复制而非整棵脏树发布。
2. edge_implement：新建infra/edge、独立edge compose和专项测试；固定nginx/coturn镜像digest，hostnetwork防止Docker桥二重NAT，静态密钥通过保护文件挂载，不在args/env。SNI白名单、未知域拒绝、TURN私有/metadata目标阻断、端口/配额/日志上限。
3. s3_audit：API媒体adapter、legacy字节委托、reconcile后端分页、worker一致读取与固定SDK依赖/专项测试；默认local保持。single-write两种兼容回读模式，只有明确404才回落，权限/超时不可视为缺失，GC删除双副本失败保留重试。
4. 专项红绿测试后先规格领域审查，再质量/安全审查。真实镜像nginx-t及coturn双向中继必要；本机监听或allocation不算通话成功。完整verify先预检输入和环境，复用不变门禁。
5. 新加坡Docker/日志准备、候选镜像固定并配置验证；安全组/NACL/路由/EIP/DNS通过后公网边缘TLS和UDP/TCP双向TURN检查。通过后经render_config模板只追加SG TURN候选，不切正常API。保留HK候选；SNI透传真实IP仍不可信，所以正常业务不导流。
6. 私有桶SSE-S3/BPA全开/TLS-only，禁止自动删除lifecycle，无直接用户S3URL；实际HK访问对照区域延迟和流量再选择单一生产桶。先隔离CRUD/故障/GC/迁移/回退；业务+legacy+worker按实际live API/worker surgical overlay，无schema/OpenAPI变化。新写S3，本地按明确miss回读，旧对象有界幂等拷贝并验证长度/digest，暂不清理本地。回退local写仍读S3-only对象。
7. Synapse必须独立实现与发布：标准provider没有删除接口，需集成本项目共享引用、发布补偿、retiring、隔离墓碑/缩略图删除和失败重试。stock provider不能直接启用。真实隔离Synapse/PG/provider测试和恢复证据通过前保留local；不因业务S3上线而声称Matrix媒体已迁移。
   存量迁移用无HTTP监听/无后台清理职责的GenericWorker启动上下文，连接既有Redis复制并逐对象持有项目生命周期锁；DB分页授权内容与缩略图，禁止目录盲拷、跳过隔离/pending/retiring/无引用CAS。私有checkpoint/audit、严格现有对象碰撞和长度/SHA校验，保留本地。截止时间限制新工作与锁获取，已经开始的SDK操作按固定超时完成后才释放锁，避免线程继续PUT而锁提前解除；此行为先用实际隔离worker验证。没有通过前不执行生产拷贝。
8. 完成生产健康、未授权拒绝、源SHA/配置/无新错误、其它容器不变及成本报告，更新current-state和逐验收状态。真实设备通话和7–14天用户网络窗口单独记录，不凭SG服务器探针宣称主区优胜或体验提升实测。

## 回退与缺少输入

- TURN先撤SG新候选并排空已有allocation；直接停机会影响活跃SG通话。边缘测试路径无正常API导流。
- 业务切回local写+S3历史回读，不能直接关闭S3以免丢新对象；保留DB状态、旧镜像、配置、对象/迁移清单。
- [AWS输入清单](../../verification/2026-09-27-edge-s3-aws-access.md)：18:12+08角色/固定EIP/DNS/服务身份/指定秘密写入均已闭环；香港身份只经Secret Manager→SSH原生管道→受保护SDK文件，密钥不经本机。继续实际发布门禁，不把桶和源码候选视为生产媒体已使用S3。
