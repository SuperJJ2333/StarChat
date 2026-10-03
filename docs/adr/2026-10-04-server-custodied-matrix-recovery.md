# ADR：服务器加密托管聊天恢复材料

状态：用户已授权目标及自主ADR决策；2026-10-04 00:56:59+08，具体设计经独立领域/规格→质量/安全有序复审PASS（报告server-custody-design-review.md，SHA a7eebb57c503ce1e3b4be830e14173cb057daf4e95643c0a702f9d9e45ddc28c）。批准内容hash075bdce1abf925e078e46594603ea095d6a60a2c8f5b81b06c8e63ed62d0c62f；本状态段仅记录审查结论。保护源码尚未实施。

## 授权与范围

用户最新直接要求“转变为服务器存储密钥”，正常使用不应要求用户管理恢复密钥。该指令在本任务中覆盖先前禁止服务器持有Matrix恢复密钥的用户规则。覆盖仅限通信恢复托管；财务密钥、钱包规则、消息/附件明文处理和敏感日志限制保持。服务器能够恢复托管的聊天密钥，产品不能再宣称服务器在密码学上无法解密这些托管历史。实现仅进行恢复材料托管，不提供管理员读取消息/导出密钥功能。

关联[规格](../superpowers/specs/2026-10-03-search-camera-history-design.md)、[计划](../superpowers/plans/2026-10-03-search-camera-history.md)、[原历史ADR](2026-10-03-account-recent-history-hydration.md)。原ADR独立游标、72h覆盖、不可变账号所有权、真实写入drain和内存限制仍有效；client-only恢复及手工密钥必经入口由本ADR覆盖。

具体提案为docs/verification/artifacts/2026-10-03/search-camera-history/server-recovery-custody-proposal.md，冻结SHA256 `76b44279a2f45a79ed8001702a41b7e2a54ec04cb8d7f9882c6caf9a2978684a`。提案§3–§9的鉴权、公开契约、持久化、移动端和验收要求纳入本决策；下述灾备选择和细化限制优先。它不是已实现/已部署证据。

## 选择

新增主进程专用Synapse RecoveryVaultModule和Matrix域独立托管集合。集合不使用或替换原生`/room_keys/version`，不写SSSS默认值、重置cross-signing或手动信任设备。服务端原子生成Curve25519私钥，AES-256-GCM信封加密后持久化；客户端使用固定SDK标准`m.megolm_backup.v1.curve25519-aes-sha2`加密本机已有Megolm session，归档到这个集合。新设备正常登录后自动取回同账号私钥及缺失session，验证、导入并有界重试本机密文。

独立集合允许原生备份锁定时迁入仍然可用的本机session，避免新原生备份覆盖现有材料或多设备同时首次创建的竞态。原生客户端对原生备份的修改不改变托管集合。无任何可用session/备份的旧密文不可凭新私钥重建；明确保留缺失状态，保护未来取得的材料。旧机已被既有单设备登录策略撤销时不能继续使用旧凭证上传；此任务不修改单设备策略，同账号新授权后迁移保留的旧本机SQLCipher材料须证明账号/库来源而非猜文件名。

## 身份与接口

资源基址`/_matrix/client/unstable/com.starchat.recovery/v1`。所有接口使用真实Matrix bearer和独立`X-StarChat-Session`当前业务bearer；不允许query token、body/path授权userId或管理员代取。Synapse从有效非guest/appservice/admin请求得到本地user/device；业务新增`POST /api/v1/auth/matrix-recovery-authorize`，按既有TokenService/mobile family/MobileMatrixSession/User.matrix_user_id核验当前同账号同设备，返回元数据，不接收任何托管密钥/session body。固定服务器调用地址，无正向授权缓存；外部await后在敏感释放/注册提交前重新核验，业务服务不可用即503。授权基于明确的服务端决策点，不承诺释放字节后分布式瞬时撤销。

| 方法/路径 | 约束 |
| --- | --- |
| GET /status | 仅元数据，返回唯一活跃集合的version/algorithm/public key/revision或真实不存在 |
| PUT /enrollments/{operation_id} | UUID幂等键、If-None-Match:*、body≤1KiB；原子信封/集合/指针/操作/audit提交，响应丢失仍可取回同一材料；不同操作并发只产生一个获胜集合 |
| POST /material | 只取本人指定不可变version的绑定私钥；响应≤4KiB，no-store、不缓存到幂等表/日志 |
| PUT /sessions/{version}/{operation_id} | ≤80加密session、总body≤1MiB；逐session revision CAS和精确payload幂等，追加保留候选与receipt，冲突返回元数据并重协商 |
| POST /sessions/query | ≤64缺失(room,session)组合，响应≤1MiB；旧候选分页每页≤16，不全账号拉取 |

每个加密session候选上限16KiB；JSON包装仍计入总大小，响应上限前停止并返回绑定owner/version/query的continuation，被分页省略的项不能标为不存在。限制转发链及字段长度，非法字段/私钥/明文session输入拒绝。所有接口no-store、严格字段/方法、固定错误代码和速率限制，不记录请求/响应body、bearer或异常locals。未知/他人version同样404；未知状态、损坏信封、缺master/schema、鉴权不可用绝不新建替代材料。接口无删除集合、管理员导出、普通用户master reset操作。

## 持久化与密码契约

Matrix PostgreSQL独立`chatflow_recovery_accounts/versions/sessions/operations/audit`和必要session head表；owner复合主键、唯一活跃指针与行锁保证并发注册。事务不等待网络。可信授权后生成未释放的候选，入短事务提交唯一owner集合；失败/并发落败候选从未用于加密上传，无须覆盖已提交私钥。客户端先记录账号范围operation，再注册/取回/验证，只有获胜集合可上传。session候选按作用域ciphertext digest去重，CAS选最低声明index/最短转发链/确定性tie-break；这些元数据仅是提示，客户端密码学验证才决定可用，旧候选不可丢弃。容量限制显式拒绝写入，不能静默清除恢复材料。

AES-GCM每次加密使用独立96bit nonce，256bit wrapping key；canonical AAD绑定format/server/owner/version/algorithm/public fingerprint/wrapping key ID。固定运行库cryptography43.0.3/PyNaCl1.5.0。真实Python生成→Dart OLM派生公钥→SDK加密session→导入解密互操作是启用门禁，不能仅stub。wrong owner/version/AAD/key、AEAD损坏、实际Olm session_id与声明不符、sender key与目标密文不符均拒绝，已有有效session保持。不能以SDK `isCached`/void返回称恢复成功。

独立expand-only模块迁移ledger和advisory lock，基于实际Synapse schema92（包含现有99_chatflow_media）增加表/index；不改核心schema head、不lazy创建、不破坏downgrade。核心媒体补丁、现有登录和S3持久化保持。

## 生产秘密管理与独立灾备

选择生产主机已验证的systemd255 `systemd-creds` OS凭据设施为本地生产secret provider，普通`.env`/DB/镜像不是provider。加密keyring凭据放root管理的`/etc/credstore.encrypted/`，root拥有的systemd凭据materializer将其解封到`/run` tmpfs；实际Synapse服务UID最小权限、主进程只读挂载，worker/业务/数据库备份容器无master访问。先验证effective worker_app并退出再访问schema/凭据，因worker继承主配置。精确unit/文件名、UID/ACL和重启顺序在交付runbook冻结，Linux实测后启用。

选择本工作站独立Windows DPAPI CurrentUser凭据库作为灾备provider，持久目录为`%USERPROFILE%/.chatflow-recovery-vault/credentials/207.56.8.8/`，只允许当前账户/SYSTEM访问，不在仓库/verification/镜像/DB备份中。不得复用APK签名密钥或DPAPI密码文件。远端master不以明文通过argv/stdout/工具输出传输：本机helper生成仅本次用的RSA-OAEP-SHA256接收密钥，公开部分经既有已验证SSH发送，服务器将master封装为密文返回；helper在内存解封后直接DPAPI保护并原子保存，不输出材料，清理临时句柄，只报告key ID/成功。网络仅走既有严格host-key SSH。独立provider目的为生产主机及其host credential key丢失后的恢复；不能把同机host-bound凭据副本当灾备。

隔离真实DB备份+独立DPAPI凭据的恢复演练必须证明取回相同wrapping key并成功解封原私钥，且全过程无秘密输出；先以隔离合成材料验证codec/OS/ACL，再保护生产凭据，不触碰用户密钥。未通过灾备/权限门禁只可disabled部署，不开放注册。双provider都丢失仍不可恢复，不能宣称无限灾备。轮换保留旧wrapping key，分批信封revision CAS重包同一私钥；旧DB备份仍需要旧key。禁止销毁旧key/集合或重新生成空keyring“修复”缺失。

## 移动端与历史边界

捕获Client/homeserver/user/device/DB generation/授权generation/业务family的单一owner覆盖secure-store/HTTP/crypto isolate/导出/导入/receipt/replay；每await后核验，不重新从全局绑定B账号。正常登录UI不等待完成；后台自动注册、迁移、缺钥恢复、72h补齐及有界退避。实际安全存储保护下载私钥和operation，非base64伪加密；账户注销/clear按明确本机策略清理，服务器托管保留。

导出最多80session/页、一页body；missing query≤64，一次请求；优先房内交互并yield。SDK接口必须直接分页读DB，不能全量getAllSessions后slice。独立vault receipts与原生uploaded flag分开；改进firstKnownIndex重新排队，未知上传结果重试相同已保护payload/op，不能同幂等键随机换密文。只有服务器真实提交receipt才算托管成功。用真实Olm import/merge最早可用index，所有写入await并登记，落盘后在同owner发session-key信号并有界重读ciphertext，不伪造live sync或未读变化。

原ADR历史80event/页、两页body/两房间请求、32页或2秒yield、8秒响应deadline、1/2/4/8/16/32/60秒重试、截止顺序锚/真实exhaustion、terminal/空/state/循环页、checkpoint CAS及limited sync/重登离线空隙要求继续成立。真实DB/key写Future不能被timeout假完成后关库；5秒drain失败保留资源到真正settled，readonly迟到网络不再入写。数据隐藏/清空/撤回规则不因恢复而解除。

认证设置展示“聊天记录同步”及下载/已托管/已解密/缺失统计，自动重试；HTML/registry随Flutter同步。正常用户没有恢复密钥输入或SAS门禁。无密钥的历史准确显示部分不可恢复，不能以空白、注册成功或zero-import冒充完成。

## 审查、验收及发布

提案§8九组真实RED/GREEN是验收最低集，含真实PG双连接并发、response-lost/crash/CAS、双token错配/撤销/管理员拒绝、秘密日志捕获、真实Python↔SDK密码学、账号A→B全部held边界、批量working-set、Linux挂载、独立灾备/轮换/回退、三天真实SDK事件覆盖与新设备恢复。按先领域/规格后质量安全审查；已完成搜索/相机不重复重做。

分别执行服务端实现与移动端实现，每阶段仅一个源码implementer，明确交接公开接口。生产冻结实际运行镜像/Compose/schema/hash，最小增量保留现有API续期协议、财务和S3/Getui。isolated rehearsal→secret provider/expand schema→authority endpoint→main vault disabled→真实路由/拒绝/配置→已授权隔离或测试账号E2E→兼容客户端。未获真实测试账户时不得伪造生产会话或读用户key表。回退disable并保留所有密文/凭据/表，切已冻结兼容镜像，不降级/删除数据。Android固定重建签名debug和同源iOS原生门禁仍按交付流程完成。

## 独立审查修订 D1/Q1（优先于固定提案措辞）

D1：固定SDK `generateUploadKeysImplementation`加密的字段为algorithm、forwarding_curve25519_key_chain、sender_key、sender_claimed_keys、session_key；标准payload没有room_id/session_id。owner/version/request绑定的外层room/session是选取及落盘范围，不是密码学证明。新consumer接受这个实际格式，导入前从真实Olm InboundGroupSession派生session_id与请求比较，并校验算法、目标密文的sender key。不得靠注入room/session标签“通过验证”；新exporter若可选附带这两项只能作额外一致性检查，不要求旧标准备份具有它们。

恢复session激活会触发既有Timeline解密，故必须在共用SDK的decryptRoomEventSync构造明文Event和写解密索引之前增加窄的decryptedPayload.room_id == 当前Room.id验证。实际固定源码没有这个检查；不能只在之后的replay/UI过滤，或谎称继承现有保护。错误/缺失room binding不投影、不计解密成功、不修改重放索引。标准producer真实session→新consumer→真实事件解密的互操作RED/GREEN须覆盖外层session改名、sender不匹配、owner/version错误和加密payload指向另一房间，保留已有有效session。

SDK解密索引的discarded Future及catch路径runInRoot出站session操作也属于实际写入：新恢复/replay路径和它触发的共享解密回调必须在调用写操作之前进入捕获owner的写入登记/撤销检查，并追踪真实Future至settled。仅await周边replay函数不算drain证明；hold这两处实际写入后切账号/clear/suspend的测试必须证明未提前关库、未在撤销后启动新的旧owner写入。接口实现可等价，但不得用timeout wrapper或fire-and-forget绕过。

Q1：wrapping key采用逐key状态机 `primary_inactive → independent_protected_and_readback_confirmed → active_for_writes → bounded_rewrap`。每一个新key ID（包括首次和每次轮换）必须先完成独立RSA密封传输、DPAPI原子保存、读回及合成信封解封确认，再提交非秘密确认状态；只有这之后可以切active-write key或开始CAS重包。未知/丢响应/灾备未确认时旧active key继续，新key不可使用；重试相同key，不能换新空材料。两provider跨重启/回退保留全部仍被live或历史备份引用的key ID。

实际隔离RED/GREEN注入DPAPI保存前、保存后ack前、active切换前、重包中途失败；完成后模拟主机及primary credential全部丢失，只从独立provider+含旧新key混合信封的DB备份恢复相同私钥。每key独立确认不是一次旧key演练可代替，秘密stdout/argv/异常/日志捕获须通过。

鉴权解释：拒绝staff/admin的console/service session种类，而非仅凭Business User角色拒绝。拥有staff角色的用户使用有效current mobile family与自己的非admin、非impersonated Matrix device时可恢复自己的记录；业务身份核验依据session_scope/AdminSession.family_id/current mobile binding，仍无跨用户能力。

## 真实路由修订 R1（2026-10-04）

实际固定Synapse1.132.0的client JsonResource是leaf；ModuleApi注册在`/_matrix/client/unstable/...`的更深节点虽然进入resource tree，却会被现有client leaf截断。隔离真实HTTP初次GET/status为核心404，不能用mock挂载成功作可达证据；证据task-3a-native-http-gate.log及固定app/rest/resource-tree源hash manifest。

保持客户端PUBLIC BASE `/_matrix/client/unstable/com.starchat.recovery/v1`及全部wire、双bearer、owner/version、CAS、密码/provider契约。主进程模块仅注册可达PRIVATE BASE `/_synapse/client/chatflow/recovery/v1`，专用Nginx精确public-prefix规则将路径映射到这个private-prefix，仍发送主Synapse；不覆盖`/_matrix/client`/`/_matrix/`，不修改/monkeypatch核心类、原生备份或现有客户端router。模块在私有实际request.path下进行同等严格路径/方法检查，公网的既有`/_synapse/client/`拒绝保持，publicprefix外不产生新增代理能力。

Vault public-prefix关闭access_log/body tracing/cache，避免被拒query token写入requestline；保留TLS及无重定向双bearer验证。真实隔离Nginx+Synapse HTTP必须证明public映射、private公网403拒绝、query-token拒绝、no-store/error/size限制以及原Matrix versions/login/whoami/nativebackup等关键路径仍走原处理。实际主UID991凭据RO读取、worker无凭据/earlyreturn验收保持。此路由细化需独立领域/规格→质量/安全定向设计复核通过后实施。

## R2：TRACE协议边界与前置安全访问日志（2026-10-04）

有序独立领域/规格与质量安全设计审查server-custody-design-review.md §7–8通过；真实TRACE405先于location，query合成sentinel进入父级访问日志，实施P1在真实复测之前保持未关闭。站立自主ADR/计划授权适用，无需再询问用户。

R1 JSON/no-store错误契约适用于进入recovery location/module的API请求。Nginx在location选择前直接拒绝TRACE，这是不支持的HTTP协议边界；允许固定、不回显URI/headers/body的405 HTML响应，无需namespace JSON/no-store头。TRACE不得进入Synapse/Business或执行密钥读写，不重定向、不反射凭证。普通GET/POST/PUT、进入location的其他方法、private拒绝、错误/size响应仍保持原JSON/no-store；HEAD只豁免HTTP规范要求的空body。此例外绝不豁免任何层凭据/正文日志保密。

HTTP上下文新增仅按$request_method的互补map（TRACE独立），与仅time/method常量TRACE/status/bytes/自动生成$request_id的安全log_format。现有Matrix listener/server内将有效access_log替换为两个条件分支：非TRACE逐一保留实际原目的地、format、options与其他原条件；TRACE在对应目的地仅安全元数据。不使用URI正则，不增加server-wide405重写，不关闭无关方法审计，不保留重复继承的rawTRACE日志。恢复location的access_log off维持。生产真实freeze为/var/log/nginx/access.log main；唯一已有/ios-call/location日志off维持。生产error_log /var/log/nginx/error.log notice维持，禁止DEBUG/bodytrace；不能根据隔离fixture的warn降低真实配置。最终部署需再冻结实际配置。

真实canonical/encoded/normalized/double-slash公共与私有TRACE独立query/Authorization/X-StarChat-Session/body sentinel，固定405无反射/跳转/上游或状态变更；逐一捕获实际access/error所有目的地并验证无sentinel、TRACE仅安全元数据；普通非TRACE控制保持原format目的地且API/no-store/normal405路由不回归。location内logoff及transport-onlyPASS不能替代此门禁。新http-context include与server directive在隔离语法/渲染/真实NGINX后验收；日志query泄漏未关闭之前不发布。
