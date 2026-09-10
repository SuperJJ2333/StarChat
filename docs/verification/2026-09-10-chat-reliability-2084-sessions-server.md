# 2084 单设备会话专项

范围：业务身份 API、Matrix 绑定与精确撤销、Worker 补偿、客户端顶号事件及恢复门禁。未部署、未提交、未登录或踢出生产账号。

## 问题现象

同账号 iOS/Android 可同时持有有效业务与 Matrix 会话。新手机登录未使旧手机业务令牌失效。L03 不能被解释为“已在其他设备在线”。

## 复现步骤与根因排查

CodeGraph 定位 `TokenService.issue_pair`，它仅追加 RefreshTokenFamily；单设备替换仅在管理端 `issue_admin_pair` 存在，ADR-0059 明确排除普通用户/Matrix。`MatrixLoginTokenService.issue` 原先只有 user_id，没有业务 family 复核。Gateway/Worker 原先不存在 Matrix 设备撤销链路。

测试向同一用户先发 iOS、再发 Android（另测同设备重登），旧 access token 仍成功，失败记录见 `artifacts/2026-09-10/chat-reliability-2084/sessions-server/red.txt`。L03 源码对应 `login_controller.dart` 的 `switch_local_clear`，是本地切换清理阶段，交由 root 单独修复；它不是在线冲突错误码。

## 修改要求与实现

- 普通登录在 User 行锁内复核密码、创建新 family、撤销旧普通 family 与设备标记，保留管理会话独立。登录/刷新/设备撤销/退出/密码找回统一 User 锁保护会话变更，旧访问和刷新稳定返回 `SESSION_REPLACED`。
- 兼容新增 `POST /api/v1/auth/matrix-session`，请求业务 Bearer + JSON `matrix_access_token`、`matrix_device_id`。token 仅在内存，经 whoami 校验 MXID/device/非访客；同 User 锁内枚举该用户设备，保留当前 device，精确删除其他设备。仅全部成功返回 `{status: ACTIVE}`。网络错误保留待完成登录；精确撤销失败返回 `MATRIX_SESSION_REVOKE_PENDING`/503 并提交无凭据 Outbox。
- Worker 领取 `identity.matrix_session`，仅按 payload user_id/device_id 精确撤销，重新锁 User 并检查当前绑定设备；目标已成为当前设备则跳过。新增 expand-only 0061 绑定表，回退保留表和数据，不重新激活已撤销 family。
- 客户端 `MatrixSessionCompletionGateway.completeMatrixSession` 仅接受 ACTIVE。业务请求收到 SESSION_REPLACED 不重复刷新；序号一致才清除业务授权及广播。旧请求/刷新/登出通过 epoch 和存储写队列防止修改新会话。Bootstrap 自动订阅后停止 Matrix、关闭旧页面访问，保留本地数据库；SessionGate 明确提示“账号已在其他设备登录…本地聊天记录已保留”。前台恢复及每60秒轻量 heartbeat 检查；网络失败不清本地会话，不周期强制旋转 refresh。

## 验收证据

临时证据均在 `docs/verification/artifacts/2026-09-10/chat-reliability-2084/sessions-server/`。

- 初始 tokens/recovery 基线 6 通过；单设备红灯 2 失败，绑定缺失红灯 6 失败；网络错误误作401、旧设备列表残留分别有独立红灯。
- 身份全套：207 通过、5 跳过、1 既有 Starlette/httpx 弃用提示；跳过项须配置隔离 PostgreSQL URL。
- API、Matrix Gateway、移动单会话、Worker 定向：47 通过，覆盖请求身份、日志/响应不回显 Matrix token、绑定拒绝被替换 family、精确目标、网络重试与补偿、Worker注册。运行少量 Worker 文件时曾因全局模型导入顺序缺 wallet_deposit_intents 报错；随 API 应用模型注册的组合定向运行全部通过，不修改无关钱包模型。
- 本地真实 PostgreSQL **18**（非生产16）：5 测试通过，包括四路并发登录唯一 family、刷新竞争不复活旧 family、logout/device revoke 等待 User 锁、新迁移与回退保留绑定数据。不可将此说成生产 PostgreSQL16 或真实 Synapse 联调证据。
- Alembic 单一 head 为 `0061_mobile_matrix_session`，完整 offline migration SQL 生成成功；OpenAPI已更新。
- Flutter 当前组合43测试通过，含顶号弹窗、暂停Matrix且不清库、旧401不踢新账号、完整绑定成功点与既有恢复/登出竞态；之后新增启动被顶、网络探测断网、组件挂载前已被顶三条，独立专项共8通过。五个修改文件 `flutter analyze --no-pub` 无问题。OpenAPI `--check` 通过。
- 仓库 `scripts/verify.ps1` 已启动，策略/部署策略/模板/配置渲染/Infra131/Getui28/MatrixBot9通过，BusinessAPI+Worker全套仍在运行，尚不能宣称总门禁通过。慢测试已用py-spy抓栈确认在 Moments fixture 构造httpx客户端的SSL证书加载路径，不是会话User锁死；`verify-stack.txt`记录。不关闭TLS、不跳过测试。全套进程交 root 集成时继续观察。

## 审查及发布边界

ADR-0062 Root Domain Review 通过；voice_2084 Quality/Security 设计、服务端代码及客户端新增块审查通过。代码审查发现旧 logout/device revoke 未遵守 User 锁，已修复并用真实PG等待锁用例验证。0061对齐现有认证迁移，显式拒绝DDL downgrade，采用保留数据和版本的应用回退；真实PG验证拒绝DDL回退后绑定仍保留。

客户端Q/S结论：epoch前后校验及存储写队列阻止旧401/清理覆盖新登录，网络错误不删除本地库，失效仅suspend，60秒/前台恢复检查及弹窗状态复核合理。HTML demo/registry已补齐，最终跨模块规格符合性由root整合。

Synapse设备枚举与单设备 DELETE 路径已按[官方用户管理接口](https://element-hq.github.io/synapse/latest/admin_api/user_admin_api.html#user-devices)核验；实际HTTP使用MockTransport验证，尚无生产或独立Synapse实测。

初版主动绑定方案存在旧客户端及未消费grant绕过，已由下面的公开登录broker方案替代。仍须区分服务器在线约束与旧客户端本地数据行为：旧iOS 2073在M_UNKNOWN_TOKEN时会自行清库，服务端不能修复该历史版本逻辑。用户真实账号的顶号验收必须先把双端升级到保留数据库的修复版；旧SDK兼容测试使用隔离合成账号。离线手机只能联网后收到明确顶号提示。

生产门禁：服务端迁移与Worker共同发布、强制升级策略、真实双手机/iOS与Android顶号及离线恢复、Synapse删除设备后本地密钥复用与消息解密验收，均需 root 集成完成。此报告不声称这些实机/部署项目已完成。


## 严格 Matrix broker 补充（2026-09-10）

Root Domain、voice_2084 Q/S补充设计已通过。`/auth/matrix-login-token`保持旧SDK响应字段，但发随机opaque grant并只保存hash/family/expiry/消费时间。`/auth/matrix-broker`保留Matrix GET flows与POST m.login.token协议；公开nginx的api/v1、r0、v3、unstable登录及尾斜杠均路由至它，真实native旧grant不再可在公网消费。公开get_token/register/guest/refresh/SSO及Synapse私有资源全部拒绝；机器人继续私网访问，基础及production Compose均loopback发布8008。

新增0062 expand迁移保存grant和每账号单调generation。User锁内先提交消费意图与generation，然后再锁User复核当前family及最新generation，调用Synapse私有模块。模块返回已完成精确撤销的新Matrix token之后才提交binding及SUCCESS审计。新family不能用旧Matrix token直接调用matrix-session宣布ACTIVE，必须经broker。恢复原business family且已绑定的有效token仍可whoami确认。

HTTP超时、模块部分失败、模块成功但业务commit失败都属于未知结果；不向客户端返回成功，不承诺跨数据库原子回退。一次性grant已消费，重试须新grant/更高generation；模块的持久generation防迟到旧请求撤销新ACTIVE会话。模块同device保留keys、撤销旧access/refresh链及其他device的真实Synapse验证由voice专项交付，不能用BusinessAPI fake替代。

验证：broker基础red3→green3，完整API/身份组合36通过；后续Domain边界red6→green12（显式无效device拒绝、token expiry透传）。真实PostgreSQL6通过，其中broker完整上游调用期间并发新登录等待User锁；与broker功能组合12通过，证据broker-pg-final.txt。追加审计后保留原有token脱敏。Infra组合139通过1个现有capacity本地HTTP连接失败；该失败与新ingress测试单独复跑3通过，分别记录infra-broker.txt与infra-retry.txt，不隐藏第一次失败。

HTML交付：新增 `auth-login-session-replaced`，registry 332屏幕/22组件；复用app-dialog，只有“知道了”确认，点击关闭回到登录表单。新增state测试red→green；frontend 146通过，verify_ui_contract通过。证据session-replaced.png为393×852真实Chrome截图，已目视确认提示完整、单按钮居中，没有新增token。演示URL `http://127.0.0.1:4184/?screen=auth-login-session-replaced&capture=1`（临时本地server在验证后停止）。

首次总verify已结束1667pass41skip2fail，原0060迁移head断言未跟进新增迁移。并行wallet任务同时新增head，root协调由wallet任务合并到0063且保留0060祖先，不改其他任务的业务实现；最终统一全量门禁由root协调完成后记录。三个迁移基线/预检文件归wallet任务维护，本专项不再编辑。


最终跨模块Q/S修订：原生admin DELETE在HTTP超时后可能继续，绕过模块generation锁影响新会话。Root确认本轮新增旧topic从未部署，批准退休；matrix-session现仅校验currentfamily/device+whoami，旧topic仅校验后ack，不发任何原生删除。新红→绿测试通过并检查非法payload拒绝。生产preflight须确认旧topic数量0。上述初版Outbox/主动bind说明为历史排查过程，最终撤销仅在Synapse模块中执行。

最终验证增量：identity+worker完整367通过9跳过（无PG环境的并发用例另已真实执行），1条现有Starlette/httpx弃用警告，231.25秒。第一次命令worker PYTHONPATH少app目录导致collection失败，修正路径后全部通过，分别留存；不是忽略产品失败。退休链路后的API组合44通过；新增第13项grant过期拒绝及第14项退休零删除/非法payload拒绝，UI计数固定断言同步22/332。Synapse模块最终固定版本真实38checks见同日synapse-module专项报告。完整仓库verify接着重新执行。

最终业务broker跨模块Q/S实现复核：voice_2084通过，独立33项模块/ingress/broker/session测试通过（voice/broker-review-tests.log），确认退休零删除、两阶段锁/代次、响应白名单及全部入口。部署及真实旧手机验收仍由root完成，不能混同本地测试结论。

全仓门禁阻塞修复：最终verify第一次仍在capacity本地HTTP重试测试失败。该测试Handler未消费POST请求体，在Windows快速关闭连接存在重置响应风险；仅增加按Content-Length读取body，不改产品重试预算/TLS。全Infra从1fail139pass变为140pass（21.06秒），证据infra-body-drain-green.txt。最终全仓再运行日志repo-verify-final-v2.txt；保留第一次失败记录repo-verify-final.txt。

最终全量API+Worker：1714通过、45跳过，1153.65秒；2条现有弃用警告为Starlette/httpx testclient与Alembic path_separator旧配置，均保留原输出。真实PG0062迁移补充1通过（pg-broker-migration.txt），证明消费grant与generation在拒绝DDL降级后仍保留。当前全仓脚本后置移动边界/迁移/OpenAPI/Compose门禁继续执行，最终退出码待记录。


## 最终全仓结果

`scripts/verify.ps1` 最终退出0，`Verification: PASS`，日志 `artifacts/2026-09-10/chat-reliability-2084/sessions-server/repo-verify-final-v2.txt`。Repository/Deployment policy、TemplateTools、配置渲染、Infra140、Getui28、MatrixBot9、BusinessAPI+Worker1714通过45跳过、mobile70通过、UI contract22组件332屏幕、API import、Python AST204文件、唯一head0063与offline全迁移、OpenAPI drift和Docker Compose config全部通过。

mobile70项耗时447.27秒；只读堆栈确认秘密字面量测试递归扫描源代码/文档/验证产物，未跳过产物或缩小检查范围。API全套慢点为Windows SSL CA加载，未关闭TLS。Getui既有Starlette/httpx及Pydantic配置弃用、API既有Starlette/httpx及Alembic path_separator弃用均保留日志，未隐藏。

最终`server-files.json`为本专项32个源/测试/文档文件的SHA256清单；其中受保护实现已通过Domain与独立Q/S。该清单不含其他wallet任务文件，也不含root已提交的Flutter/native变更或voice模块独立交付。部署增量必须以root协调的最新wallet生产基线为基础，不能整目录覆盖；本专项未部署或登录/踢出真实生产账号。生产发布及双端升级后的真实账号验收由root继续执行。
