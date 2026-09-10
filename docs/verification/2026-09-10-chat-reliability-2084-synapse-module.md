# Synapse 私有移动登录模块验证

范围：已批准 ADR0062 broker 补充中的 Synapse 模块及打包。业务 API、grant 表、公开代理和部署配置由 server_sessions_2084 负责。本报告不是部署验收；没有修改或重启任何生产服务。

## 实现

- `third_party/synapse/chatflow_mobile_login.py`：固定 Synapse **1.132.0**；其他版本拒绝加载；worker 不注册资源。主进程资源 `POST /_synapse/client/chatflow/mobile_login` 使用原生 admin bearer 认证，仅接受本地、正常、已批准且未锁定/停用/暂停的普通用户。请求字段 user_id、generation（正 int64，不接受布尔）、device_id（1–255）、可选 initial_device_display_name。
- Synapse Linearizer 对 MXID 串行，账号状态在取得锁后复核。扩展表只保存 user_id/generation；以数据库 UPSERT 的严格递增条件持久消费 generation，再执行 native register_device。成功/失败代次都不能重放，表不删除、无回退重置。
- 新 token 验证 user/device/token_id 后，调用固定版本原生 `delete_access_tokens_for_user(user, device_id=当前设备, except_token_id=新token)`，撤销当前设备所有其他 access tokens 和所有旧 refresh tokens；逐个精确删除该用户其他设备。保留当前设备及其 E2EE keys，不读取消息、私钥或房间密钥。
- 不签发 refresh；返回标准 user_id/device_id/access_token，原生有 expiry 时返回 expires_in_ms。撤销等阶段失败时只精确补偿新 token，绝不删除当前设备；失败响应不含 token、上游异常或响应原文。补偿本身失败仍保留已消费 generation，由下一次成功登录收敛。
- Dockerfile 复制该模块到固定上游镜像的 site-packages；不修改上游文件/新依赖。测试故障注入模块只位于 tests/infra，不复制进生产镜像。

## 真实集成发现与修复

1. 初版 `/_synapse/admin/v1/...` 路径被 Synapse admin 叶资源截获，真实 HTTP 返回 404。改为独立 `/_synapse/client/chatflow/mobile_login`，已与业务代理协调；公开 nginx 必须明确封闭该路径。
2. 固定 1.132.0 Linearizer.queue 返回异步 context manager，不能使用旧版 `with await` 约定。真实调用初版返回 503，检查固定源码后修为 `async with`，单元 fake 同步纠正。
3. 独立 Q/S 建议排队后复查账号状态；新增回归红→绿并移入锁内。

## 验证证据

路径前缀：`artifacts/2026-09-10/chat-reliability-2084/voice/`。

- synapse-red.log：模块缺失的初始红。
- synapse-queued-state-red.log：排队期间账号变为不可用的回归红。
- synapse-green.log：7 项 coordinator 安全/竞态测试通过。
- synapse-integration.log / synapse-integration-v2.log：真实路由与原生接口假设失败的记录。
- synapse-integration-v3.log：固定 Synapse 1.132.0 + SQLite 真实 seed/restart 验证通过。
- synapse-build-final.log：仓库完整第三方 Dockerfile 构建通过；基础镜像版本及 digest 固定，构建 network none。
- synapse-integration-pg-final.log：**最终打包源** + Synapse 1.132.0 + PostgreSQL 16.9 的 38 项检查通过。覆盖未认证、非管理员、远端/管理员/锁定账号、布尔 generation 拒绝；同 device 两个旧 access 和另一个设备 access 全部 401；旧 refresh 401；原有 E2EE 公钥完全保留；无关账号仍可用；仅一个 device/token；HTTP 客户端真实超时断开后较新代次完成，旧代次不能撤销新会话；发 token 后故障返回 503 且无 access，补偿保留此前有效 token；重启后成功与失败 generation 均拒绝重放；扩展表只含 user_id/generation。
- synapse-packaged-hash.log：运行容器所加载生产模块 SHA256 与本地最终源一致：`d164566dbf51936a73926a3853ab5d44fa51d4cb56a5f1c8a69979ce1abe2526`。
- synapse-cleanup.log：按明确名称、验证标签和无公开端口约束，已删除本任务七个测试容器、其匿名 volume、两个 internal network、专用镜像标签和各独立目录中的合成凭证。没有停止或删除生产资源。

实际远端测试经 root 明确授权，使用独立命名容器、内存/CPU 限额及独立数据。SQLite 网络为 none；PostgreSQL 场景为独立 internal network，所有测试容器端口绑定均为空，不连接生产数据库。故障夹具挂载目录只有测试脚本，最终 PostgreSQL 场景没有覆盖镜像内生产模块。测试只有随机合成账号、会话和公钥；凭证保留在隔离 fixture 中，不导出到本地日志。

## 固定上游接口依据与限制

固定上游源码确认：`registration.user_delete_access_tokens` 使用 user_id/device_id 删除 refresh_tokens，except_token_id 只保护新 access；新 register_device 默认不发 refresh。DirectServeJsonResource 仅对 `@cancellable` handler 在断线时取消，本模块没有该标记；实际超时测试亦覆盖继续执行的行为。

模块仅允许唯一主进程拥有资源；持久 generation 不替代跨进程全操作锁，不能在多主进程同时暴露该资源。Synapse 升级必须重新验证私有 adapter。公网 aliases、原始端口与机器人私有路径封闭需要结合业务代理集成和部署烟测证明；单独模块通过不能证明所有公开入口已封闭。未知结果/崩溃不是分布式事务：失败尝试不承诺旧会话保持有效，且下一成功代次负责收敛未完成凭证。

本机 Docker daemon 未运行，Hidden 启动 Desktop 被自动审批拒绝；未绕过。经 root 授权改用远端隔离实例后完成上述真实测试。

独立 Quality/Security 实现评审（video_2084，2026-09-10）：通过。复核最终私有路径、async with Linearizer、锁内账号复核、schema锁、持久generation CAS和实际 PostgreSQL/Synapse矩阵；另运行当时模块/broker/mobile session/ingress共32项测试通过。

跨模块最终 Q/S（voice_2084，2026-09-10）：发现旧 bind/Outbox 直接 native DELETE 在 HTTP 超时后可能迟到，绕过模块串行约束。Root 确认该 topic 本轮新增从未部署，Domain 批准退休。修订后的 bind 仅核对 current family/device 与 whoami，合法旧 topic 校验后确认处理，非法 payload 仍拒绝，不调用原生 DELETE。重读完整 broker/代理及退休代码后通过，独立最终 Python 3.12 运行模块/ingress/broker/mobile session **33 项通过**，证据 broker-review-tests.log。发布必须额外确认 topic 事件数为零、无旧实现在途，以及唯一主资源和公网入口封闭；本结论不是部署或真实旧手机验收成功。

## 发布候选权限修复与真实 UID 启动增量验证

首次发布候选启动失败并自动回退，原因是上传源码 0600 被 Docker COPY / shutil.copy 保留，模块归 root 所有，而生产 Synapse 主进程实际 UID 为 991。此前仅 root 导入验证未覆盖实际运行身份。仓库 Dockerfile 已使用 copyfile 并明确模块 0644、目录 0755；只放宽公开程序源码，不放宽运行配置或备份。

新增打包回归先失败（8 项中 1 失败），修复后模块与发布门禁合计 17 项通过。证据：voice/synapse-permission-red.log、voice/synapse-permission-green.log。

独立 startup-probe.py 在远端 internal Docker 网络恢复 Synapse PostgreSQL 备份，替换克隆配置中的数据库、Redis、签名与共享秘密；不挂载生产数据目录，不发布端口。修复候选以真实 UID/GID 991 启动主进程与 sync worker，两者 /health 返回 200，并在共同运行后重复检查；主进程私有登录资源无授权返回 401。容器、网络和克隆目录清理后才写 native-startup-proof.json，其内容绑定精确镜像及全部执行输入哈希。证据已保存 voice/native-startup-proof.json，原始运行日志留在服务器受限目录，未下载其内容。该验证只证明隔离恢复克隆启动成功，生产重试由 root 的发布门禁另行执行。

发布脚本独立质量/安全复核：重试只允许原始或精确目标数据库版本，保留 topic 为零、原镜像与运行配置一致、原 homeserver、原始或精确关闭版 nginx、钱包配置/代码不变等限制；必须四份当前 proof，并验证目标版本重复迁移不改变数据。审阅无阻塞。

排查期间一次工具输出误包含嵌套连接配置敏感字段；未写入文件、Git、截图或可下载产物，未复述字段值。已向 root 报告并停止读取该嵌套内容，后续仅输出白名单状态或布尔结果。本报告不包含可用凭据；未自行变更生产凭据。
