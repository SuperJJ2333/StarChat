# Outbox 消费契约与生产配置漂移修复

## 恢复入口

- 用户授权：2026-09-27明确要求解决持续新增的 Outbox 死信与模板/线上网关既有漂移；包括必要的回归测试、分批生产发布及验证。
- 当前阶段：2026-09-28 02:15+08已完成。Worker a508/aed固定00:34:17启动，6045.611秒实际观察374PUBLISHED/374匹配回执、0新增DEAD/失败/相关错误，103056历史完整行保持。模板同步、renderer0及两地12严格TLS路由通过；最终helper47bb全字段检查及独立ACCEPTED_BY_FROZEN_CONFIG、六份私有快照metadata验证通过。旧7fc/VERIFYING journal与失败指纹原样保留，不声称旧指纹相等。API及44其他容器保持，监控active/enabled，未重放或删除历史事件。
- 文件所有权：Root负责本任务记录、规格/计划、验证总报告及 current-state 本任务段；Outbox和配置实现文件在根因确定后单独登记，禁止重叠写入。
- 上一批基线：[SG/TURN/S3部署任务](2026-09-27-edge-s3-deployment.md)。431为21:31的兼容后创建且当前DEAD快照，并非累计发生速率或媒体失败。
- 调查阶段运行身份变化：只读守卫发现API在13:44:25UTC起为e3043e9a…；当时worker为0e011134…且healthy。新发布仅切Worker至a508/aed，不能使用历史1aa6配置覆盖新API。
- 边界：金融业务状态、历史账本、原始事件和失败记录保留；未知事件继续显式告警；不注册空消费者或伪造成功。保持PHONE修复、S3读写、原有鉴权路由、TURN五条和Synapse模块参数。
- 下一可执行步骤：本任务完成，无待发布步骤。现有独立验收标记已核验，不得重复accept；后续任何重建须先保存完整旧Inspect/image/network/effectiveCompose私有快照。历史DEAD处置或新增契约另立任务，保留本次固定观察起点和证据。
- 实现所有权：Outbox agent仅audit/writer.py、worker main.py、新internal_publication.py及两份专属测试；Root明确扩展授权修改既有test_wallet_operations_wiring.py以保持原handler对象和新11项装配契约。配置agent仅两份模板、test_render_config.py和gateway-*证据工具；发布与观察agent分别持有worker-release-*、outbox-postrelease-*证据工具；Root持有发布基线、门禁、验证总报告/索引。独立worktree见计划，972当前非秘密输入SHA已冻结。

## 阶段计时与证据（早期历史检查点）

| 阶段 | 时间（+08） | 输入身份 | 结果 |
| --- | --- | --- | --- |
| 恢复上下文/调查 | 21:40–进行中 | 生产镜像、运行挂载、源码静态topic白名单 | 未执行业务写入；API并行变化被守卫拦住 |
| 当前源码基线测试 | 21:58左右，精确墙钟见tool输出 | worktree-source-baseline.json | Outbox/Worker133通过、renderer10通过；不代表新缺口已修复 |
| Outbox最终规格/源码安全 | 22:25–22:52，精确时间见各JSON | 六项冻结源码、142闭合契约 | 185含真实PG并发通过；独立规格185通过，安全184通过/1PG条件跳过并复用同SHA真实PG证据 |
| 网关守卫复审 | 22:33–进行中 | 原154版与新增82eb版分别保留 | YAML键类型、实际挂载/PID1/SHA两阻断已TDD修复；66通过。实际CLI运行比较差异尚在诊断 |
| 完整verify | 22:26–进行中 | attempt1/2/3各有日志与阶段输入SHA | 前两次缺开发配置及第三方源码/错误验证junction均显式保留；补齐合成环境后的第三次仍在运行 |
| 只读真实契约校验 | 22:50:38 | 当前0e/f20、候选三源码及manifest5936 | 762未截断；active两类均合法，4invalid仅旧DEAD；数据库只读，无receipt写入/重放 |
| MAIN回填 | 时间见JSON | main-source-integration.json | 九项先统一CAS检查再复制；其它并行文件保持，生产不变 |

已证实两类持续新增内部事件为manual_reserve.published、wallet.funding_scan_discovered。原金融事实已提交；11个内部审计topic缺注册。真正notification公告分发topic现场0事件，禁止用内部回执冒充通知。服务器模板漏现网nginx安全块及Module声明，MAIN已有对应契约；修复是同步模板及严格发布验证。

非Git证据统一保存于 `docs/verification/artifacts/2026-09-27/outbox-gateway-reconciliation/`。读生产数据库必须READ ONLY、REPEATABLE READ并设连接/语句/锁超时；禁止导出payload、token、完整错误或账号标识。

## 2026-09-28 00:04+08恢复检查点

网关实际发布见gateway-publish-stage.json，最终工具9f9d…/模板7d4b…及dd815…；Worker最终catalog409915…/测试1a4e…的146个契约纳入四项继承好友审计调用，原4条真实DEAD仅验证为合法，未重放。独立源规格7a314…、安全e86d…；观察器489466…即时硬失败修复规格72c39…、安全e6695…均通过。完整verify第三次3242通过/93跳过/1旧OpenAPI包环境失败；当前四个packages输入补齐后5契约通过，移动输入补齐后127通过/1跳过，余下强制阶段均通过，见mandatory-verification-impact-closure.json，原失败不改写为exit0。

Worker首次prepare于23:51:49–23:51:55+08失败；monitor timer finally恢复active/enabled。只读诊断0494e…证实四项COPY/FROM/hash一致，JSON字典排序导致expected Dockerfile顺序错误。候选镜像标识/状态/配置快照均未建立，未执行生产up。不可放松四路径或包内容约束，需固定CHANGED_PATHS顺序并加入真实序列化往返测试。v3包3bb5…及manifest e5a1…保持不可变；私有基线固定103056条历史DEAD完整行摘要，数据库只读，原历史集合未改。

00:28+08补充：第二次prepare失败诊断ddd5e…证实v3包及source delta通过，仅隔离启动sys.path导致main找不到。candidate-image-id存在root600/SHA8b1e…，六项状态/私有配置/inventory均未建立，原0e/f20 healthy及监控active/enabled保持。只读诊断未执行prepare/build/up或DB写。新edf26 runpy启动器除isolated_command完整AST不变，包3bb5/manifest e5a1不变；归档先钉住driverSHA/祖先/持锁FD与精确IID，再hardlink独占存档并复核link后FD/path/bytes，禁止删除外来IID。

00:50+08阶段：第三次prepare实际通过，9940源库存仅四路径变化，Linux扫描241文件/65enqueue、11新内部topic及原9handler/SDK/真实synthetic tests exit0。publish已切至a508/aed但完整runtime指纹guard失败，automatic rollback也因同一guard拒绝，未执行回退；原journal VERIFYING明确保留。镜像配置完整相等、frozen before/candidate仅image差异、完整Env90typed、绑定/命令/资源等已逐项验证，44others确切未变，但单hash不能逆推出未知旧字段，禁止改成新hash冒充unchanged。新验收工具有独立完整配置来源及unknown failclosed要求，非忽略漂移。初次公网只读探针误用syncworker容器名失败，按实际docker inventory修正为starchat-synapse-sync-worker-1后全部12TLS/check0/4服务healthy0restart通过，失败log保留。临时PG容器及两精确自有网络已清理/端口关闭，见local-fixture-cleanup.json。


## 最终关闭（2026-09-28 02:15+08）

最终标签delta规格35473599→安全4ac4f5d1通过；Root Linux8case、只读全字段检查、one-timeaccept及六快照metadata均实际通过。marker c4ea0538，原journal7fc保持VERIFYING。最终6045.611秒/374真实回执及12严格TLS/check0通过，证据与各阶段起止见[验证报告](../../verification/2026-09-27-outbox-gateway-reconciliation.md)和本任务artifacts的root-runtime-*-final-stage.json。只切本批Worker，最终验收不重启、不写DB；历史103056固定集合不变。完整verify原失败及等价补齐阶段闭环保留，自有PG已清理。
