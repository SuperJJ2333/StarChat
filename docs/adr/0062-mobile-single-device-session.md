# ADR-0062：移动端单设备会话与精确 Matrix 撤销

日期：2026-09-10。状态：用户需求已授权；Root Domain Review 与 voice_2084 Quality/Security 设计评审已通过。实现仍须通过代码评审与验证。

## 决策

移动端密码认证在 User 行锁内创建业务令牌族并撤销旧普通令牌族；管理端会话独立。旧访问及刷新返回稳定 HTTP 401 `SESSION_REPLACED`。刷新和登录采用相同锁顺序，不能由旧刷新重新激活会话。登录失败不能撤销旧会话；业务认证成功、Matrix 尚未完成时为待完成登录。

新增兼容接口 `POST /api/v1/auth/matrix-session`，业务 Bearer 认证，请求 JSON `matrix_access_token`、`matrix_device_id`。Matrix token 只驻留请求内存，不写日志、数据库、Outbox、审计或异常文本。通过 Matrix whoami 校验稳定 MXID、device_id 与当前业务账号绑定；拒绝访客、其他账号和错误设备。

绑定在 User 行锁内重新验证业务 family 当前有效，保存 family 与 Matrix device 的对应关系。同步精确删除该账号历史绑定的其他 Matrix device，成功后响应 `{status: "ACTIVE"}`，客户端才宣布完整登录成功。失败返回可重试错误并保留待撤销记录和 Outbox；不回滚已完成的业务替换，不声称旧设备已下线。后续绑定重试必须幂等。

同一设备号被当前合法会话复用时保留该设备及 E2EE 身份，更新归属 family。异步撤销按稳定业务用户与目标 Matrix device 查当前绑定，持有同一 User 行锁执行精确删除；若目标已经成为当前合法会话设备，跳过。禁止全账号 logout-all/delete-all，防止迟到任务踢掉新会话。设备不存在视为幂等成功，网络或上游失败保留任务重试。

旧手机获 SESSION_REPLACED 或 Matrix token 失效时停止同步并显示明确顶号提示，保留账号隔离的本地数据库、消息、密钥及附件缓存；不自动清空或销毁。离线设备只能在下一次联网后感知失效，不能承诺立即显示通知。

## 边界与迁移

业务 API 不能根据客户端 display state 推断在线设备。Matrix 登录令牌仍遵循 ADR-0004，签发须在会话有效性复核内完成。当前数据库不存在业务/Matrix device 对应关系；初次绑定通过 Synapse 管理接口仅枚举经过 whoami 验证的同一 MXID 的设备，逐个精确删除除当前设备外的目标，并记录待重试目标，不能扩大到其他用户。旧版本必须强制升级后部署启用完整单设备承诺；已经发出的 m.login.token 可能在业务替换后才被旧客户端消费，旧版本跳过绑定时原桥接架构无法原子阻止该竞态。新客户端绑定检测已替换 family，拒绝完整登录并进入本地保留数据的失效流程；部署门禁必须明确这个兼容边界，不能把仅业务 token 撤销说成全部 Matrix 会话下线。

新增表采用 expand-only 迁移，回退应用不重新激活已撤销业务 family，不删除本地加密数据库。接口兼容新增、更新 OpenAPI。业务与 Matrix 无分布式原子事务，完整成功点以同步撤销已确认且当前 family 仍有效为准。

## 评审与验证

领域评审先于质量/安全评审：跨端互踢、同设备重登、管理员隔离、并发登录/刷新、错账号/设备绑定、被替换会话迟到绑定、撤销失败/重试/幂等、同 device 重新激活与迟到 Outbox、无明文或凭证持久化。PostgreSQL 行锁验证与 SQLite 功能测试分开记录，不能将 SQLite 成功当作并发证明。

Root Domain Review（2026-09-10）：通过。确认管理会话独立、两步成功点、whoami 身份验证、精确撤销和同 device 重新激活保护；要求遗留设备枚举只限当前 MXID，迟到 grant 消费的旧客户端绕过边界作为部署门禁。

voice_2084 Quality/Security Design Review（2026-09-10）：通过；whoami 缺少 device_id 必须拒绝，HTTP 异常不得包含令牌，遗留设备枚举必须受控，需真实 PostgreSQL 行锁验证；这不是实现代码的提前批准。

voice_2084 Quality/Security 服务端代码 Review（2026-09-10）：通过。发现并修复 logout/device revoke 的 User 锁协议缺口，password recovery 同样先锁 User；新增两条真实 PostgreSQL 等待锁测试验证撤销不能穿过 Matrix 绑定/签发临界区。whoami、精确设备目标、Outbox当前device保护、异常脱敏及expand-only迁移审查无其他阻塞。客户端增量实现单独复核。

## 补充决策：公开 Matrix 登录必须经业务授权代理（待 Q/S 设计评审）

本节替代上述“仅升级新客户端后承诺”的临时边界。Root 已原则批准最小 broker 方向，以下细化需要独立 Q/S 评审后实施。

### 入口及兼容

`/auth/matrix-login-token` 保持响应形状，改为签发高熵随机 opaque grant；仅保存 SHA-256、user/family、到期时间与消费状态，不再把真实 Synapse login token交给公网客户端。公开 Matrix `m.login.token` 请求消费这个 grant，原有 SDK 与旧客户端无需新增主动 bind 才受约束。旧的未登记 native grant 一律拒绝。GET login 仅广告 m.login.token。现有 matrix-session 接口保留作 whoami 与恢复检查。

公开入口覆盖 Synapse v1.132.0 的 api/v1、r0、v3、unstable login aliases；规范化后的尾斜杠一并处理。拒绝公开 login/get_token、register（含 guest）、refresh、SSO/CAS/SAML/OIDC登录/回调及未知登录方式；当前配置没有SSO/JWT依赖，且注册关闭。业务机器人通过 Compose 的私有 `http://synapse:8008/` 保持现有内部认证；不能通过 UA 或可伪造请求头放行公开旁路。Synapse原始端口仅 loopback；生产已有 override，基础Compose也必须收紧。最终运行配置与公网入口烟测是部署门禁，部署须完成门禁后由 root 执行。

### 同 device 与超时的必要 Synapse 扩展

仅删除其他 device 仍有漏洞：同一 device_id 可以对应多个 access tokens。客户端提供 device_id 不构成可信物理设备证明。采用固定 Synapse v1.132.0 上的最小私有模块资源 `/_synapse/client/chatflow/mobile_login`，复用已认证的 admin bearer，并限制目标为业务确认的 MXID；资源只注册在主进程且公网路由拒绝。模块只处理设备/令牌，不接触E2EE密钥或消息内容。

模块通过 register_device 保留指定设备及 keys，取得新 token；枚举该 MXID 的设备，对当前 device 调用精确 device_id + except_token_id 的 access-token 撤销，对其他 device 精确删除。不得调用不带device_id的全用户令牌撤销，也不得删除当前device。客户端指定其他已存在device不能获得旧密钥；旧 token 同样被撤销，只有新token可用。新token及任何refresh token不写扩展表、日志或Outbox。公开refresh关闭，模块不签发refresh token。

业务 User 行锁保护 grant 消费与家族有效性复核。授权消费意图先提交：grant一次性已消费、每账号递增generation及目标device。随后重新取得User锁、确认family有效，再调用私有模块；该锁覆盖响应验证与绑定提交。若在两阶段间被替换，不调用模块。

为防 HTTP 超时后迟到旧请求踢掉已成功新会话，Synapse模块对每个MXID串行执行，并在扩展表持久保存最高generation（不含token）。旧或重复generation拒绝；generation先持久化再执行登录及撤销，同进程串行锁覆盖整个操作。部署限定该资源只在唯一主进程启用。新尝试必须取得新grant和更高generation，不能重放未知结果请求；新generation成功会清除任何较旧尝试产生的token。进程崩溃后已使用generation仍拒绝，未返回的新token由下一次成功尝试清除。

上游失败/超时/响应身份错误均不得返回登录成功。客户端收到可重试Matrix错误，重新申请grant重试；不持久化可恢复的响应token。成功必须已完成当前device旧token撤销及其他设备撤销。模块操作部分失败时不发成功响应，下一次更高generation收敛；本轮未部署的旧identity.matrix_session Outbox退休，仅校验payload后ack；matrix-session只验证当前family/device及whoami，不再发原生DELETE，避免HTTP超时后的迟到删除绕过模块generation锁。已ACTIVE的新会话受generation保护，尚未完整成功的尝试不承诺旧会话仍有效（网络/跨库事务不存在原子回滚）。

### 迁移、测试和回退

业务新增grant/operation表为expand-only；Synapse新增generation表保留不删除。应用回退不能重新开放原始登录入口或重置generation；若broker版本不可运行，暂停移动端新登录，保留现有会话读取，禁止以重新开放旁路作为回退。机器人/管理服务私有路径独立。

TDD覆盖：旧grant迟到与重复、所有公开aliases/方式封闭、并发消费与User锁、未知结果后新generation、迟到旧generation拒绝、同device多个旧token只留新token且keys不删除、不同device精确撤销、模块非admin/远端MXID拒绝、无token持久化日志、公开兼容Matrix响应与私有机器人路径。迁移head测试保留唯一head和0060共同祖先断言。

上游依据：[固定版本客户端路由](https://raw.githubusercontent.com/element-hq/synapse/v1.132.0/synapse/rest/client/login.py)、[模块注册设备与资源API](https://raw.githubusercontent.com/element-hq/synapse/v1.132.0/synapse/module_api/__init__.py)、[精确设备访问令牌撤销实现](https://raw.githubusercontent.com/element-hq/synapse/v1.132.0/synapse/handlers/auth.py)。内部handler调用属于固定版本适配，版本升级须重新契约验证。

Root Domain 与 voice_2084 Q/S 补充设计评审（2026-09-10）：通过。实现须证明精确旧refresh链撤销、部分失败单token补偿、锁生命周期与重启generation拒绝；设计批准不是实现批准。

实现补充：matrix-session只接受broker已建立的当前family/device，防新family使用旧token绕过；过期一天的grant在同账号再次签发时清理，generation永久保留。模块成功但业务commit失败是未知结果，新grant/generation收敛，不能宣称跨库原子回退。旧iOS2073自行清库行为必须双端升级后才对真实用户验收顶号。

最终Q/S竞态修订（Root Domain与voice Q/S设计通过）：broker之外不再发送原生设备删除，前述主动bind/Outbox撤销方案仅为历史设计、已被替代。root确认旧topic从未部署；发布preflight必须证明identity.matrix_session事件数为0，存在事件或在途旧实现时停止发布审查，不盲目ack。测试证明bind及有效退休topic均零删除，非法payload仍拒绝。

voice_2084 最终业务broker跨模块Q/S实现复核（2026-09-10）：通过。独立33项模块/ingress/broker/session测试通过，证据voice/broker-review-tests.log。迟到native DELETE旁路已移除；部署必须查topic0、唯一主进程及公网入口封闭，不等同真实用户双手机验收。
