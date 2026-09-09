# 内容寻址媒体与千人群执行记录

> 后续真实容器与200/500VU实测已执行，见[2026-09-10实测报告](2026-09-10-media-capacity-runtime.md)。本文件保留上一阶段的环境阻塞和验证历史，不代表当前运行状态。

计划：docs/superpowers/plans/2026-09-09-content-addressed-media-thousand-member.md

## 授权及裁定

用户明确确认共享 media_id＋独立引用、可信哈希缓存，随后要求执行，替代原提案过强限制。
Ruling: 热缓存以内容哈希为准，不比较 key/iv；错误信封的冷热结果差异是定义的协议语义。
Ruling: 引用粒度为上传者/媒体，不能从加密事件推算消息数量。
Ruling: 当前 checkout 有大量未提交依赖，普通新 worktree 缺少这些依赖；按明确文件所有权在当前 codex 分支实施，不移动或提交其他修改。临时证据仅在 docs/verification 下。

## 接口预审

|任务/接口|检查及裁定|
|---|---|
|1|授权修订，千人为目标非实测|
|2|SDK 所有媒体预处理先于加密|
|3|固定派生，调用方不可覆盖生成摘要|
|4|实际字节校验，保留旧缓存/总配额|
|5|正文和缩略图独立摘要，已解密事件可信|
|6|共享 ID 必须有引用/隔离/并发/回收|
|7|主与 worker 同镜像、Redis 独立|
|8|隔离负载，HTTP 与 E2EE 验收区分|
|9|先规格后质量安全，真实输出|
|2→3|最终明文预览＋加密信封，不再变换字节|
|3→5|chatflow_media v=1 及两个 hex 字段，缺失兼容畸形拒绝|
|4→5|可选 contentSha256，内存/磁盘键一致|
|6→7|compose 根协调者唯一拥有|
|7→8|只渲染隔离配置，禁止改运行 data 作为源码|

## 进度

Tasks 1–7：本地实现及顺序代码评审通过。Task 8：隔离脚本实现及顺序评审通过；真实容器与负载验收受环境阻塞。Task 9：全量门禁退出0通过，最终Task 8修正后infra100项通过。
Docker daemon 初检及隔离启动重试均不可用，详见环境限制。

## 已完成实现与顺序评审

- 领域设计复核 media_domain_review 通过，然后 Quality/Security 设计复核 media_security_review 通过，范围为本地实现；未授权生产部署。
- Tasks 2–5：确定性加密、SDK prepared envelope、内容缓存、所有接收/转发接线已实现。原有 crypto 包提供 HMAC，按 HKDF 定义实现固定两块 expand，并用独立 Python 向量验证；不新增依赖。具体类保留 preEncrypted 字段覆盖所有媒体类型，代替两个会丢音视频元数据的特定子类。
- Task 6：共享 media_id、引用视图、pending 发布意图、失败补偿、retiring 回收恢复、隔离锁、固定来源补丁和镜像已实现。基镜像真实 manifest digest 为 3036ec25dfb5fcc5120942465788c1e1f2bb3671e28b04d7b3a1db4400ac84f4；所有5个上游源文件及补丁结果 hash核对通过。两阶段预分配ID上传保持原ID不去重，但执行相同隔离检查。
- Task 7：worker、独立Redis、PG连接池、presence、邀请限流、模板登记和nginx路由已实现。采用 instance_map.main（固定版本拒绝旧字段）；宿主18081避免bot8081冲突，容器仍8081。
- 实现后领域评审发现并修复发布失败重复实体及回收顺序、冷缓存明文URL旁路；再经质量安全评审修复worker旧配置与端口冲突。最终领域与Quality/Security代码配置复核均通过，运行时验收仍未替代。

## 当前测试证据

- Flutter analyze --no-pub：No issues found，15秒，mobile/analyze-root.log。
- Flutter test --no-pub：1396/1396通过，约84秒，mobile/flutter-full.log。
- Python tests/mobile：66/66通过，349.58秒，mobile-boundary.txt。
- SQL/文件/适配器/补丁：16项通过，pending-green.txt；覆盖补偿返回空列表仍可恢复、并发上传与回收、隔离、关开关、独立引用及失败事务。框架类型/锁调度为模拟，不称为真实PostgreSQL跨进程验证。
- Worker：5项通过，包括真实compose默认端口唯一性、模板渲染及漂移。pinned-worker-guard.txt是执行固定上游AST复制守卫，非完整WorkerConfig/进程初始化。
- 全量 verify.ps1：退出0，Verification: PASS（verify-full.txt）。当时 infra88通过、Getui28通过、MatrixBot9通过、业务1400通过/34跳过、移动边界66通过；UI契约17组件/330屏、AST192文件、迁移、OpenAPI、Compose渲染通过。后续新增Task 8测试由独立infra复测覆盖。

## 环境限制（真实输出）

隐藏启动Docker Desktop后，Docker daemon仍不可用；WSL启动报“系统资源不足，无法完成请求的服务”，错误码 Wsl/Service/CreateInstance/CreateVm/HCS/0x800705aa。证据 container-environment.json。不变更用户全局虚拟机/内存配置、不终止其他任务来强行启动。容器build/启动、PostgreSQL真实跨进程集成及200–500 VU实测尚未完成，不能标记千人群验收或部署就绪。未来1000成员测试仍按原授权留待新集群。
## 隔离压测准备及最终复核

- capacity.py prepare 实际执行成功；随后 up 实际执行失败：dockerDesktopLinuxEngine 命名管道不存在。保留 capacity-prepare.txt 和 capacity-up.txt；没有执行 bootstrap 或伪造负载结果。
- 隔离 Compose dry render 已通过；最终根协调者重新运行完整 infra：100/100通过，13.37秒，infra-endpoint-final.txt。包含Task 8全部17项，替代中间90/94项输出。
- 领域评审发现重复 invocation 事务ID复用、sync失败后发送重复计数、bootstrap加入限流未重试，均已修正并取得红绿回归证据；测量阶段的真实限流必须保留，不借脚本隐藏。
- 运行目录和 pytest 临时目录加本地 .gitignore，实际 git check-ignore 确认临时凭据/签名key被排除；不发布整个运行目录。
- 本次涉及的 tracked 文件 scoped diff --check（cr-at-eol）通过；整个工作区还有其他任务既存修改，不对其作清洁声明。

门禁保留34个既有条件跳过（PostgreSQL隔离环境未启用及SQLite不支持的跨进程/序列化场景），不计为通过。现有依赖警告为 Starlette TestClient/httpx 弃用和 Getui BridgeSettings 的 Pydantic class Config 弃用，本次未修改这些依赖；没有关闭警告。Compose渲染通过不等于容器启动通过。

最终Task 8领域复核通过后，质量安全评审发现Docker context可指向远程。已新增local_docker端点检查、显式固定本地Unix/npipe、拒绝远程SSH/TCP，并覆盖Compose与stats。质量安全最终复核通过，独立17项通过。根协调者用最终入口实际重试up，仍因本地dockerDesktopLinuxEngine管道不存在退出1（capacity-up-final.txt），不是目标校验错误，也不是实际容器验收通过。

## 交付状态

本地实现、文档、单元/适配器回归及仓库门禁完成，未提交、未部署。尚欠实际补丁镜像构建、Synapse/PostgreSQL/Redis运行集成、200–500VU实测与旧客户端/真机互通；这些不能由上述离线通过替代。压缩以APP最终输出字节计算摘要，只有精确相同字节复用，不承诺视觉相似或不同压缩器输出具有相同哈希。压测操作见 docs/runbooks/thousand-member-capacity.md。
