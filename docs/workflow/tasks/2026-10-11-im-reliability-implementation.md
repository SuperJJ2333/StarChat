# 2026-10-11 即时通讯可靠性修复执行记录

## 授权、范围和基线

用户已明确授权继续修复，并由执行者决定产品修改、服务重启与部署。执行已评审的[修复计划](../../superpowers/plans/2026-10-11-im-reliability-remediation.md)，不重复请求上述授权。Android 厂商推送尚在审核；最终 iOS 签名与真机、长时观测属于各自依赖门禁。

基线 main `5c83a08a09b985146bc507a1608cb2153d361e48`。主集成工作树 `C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat`，分支 `codex/im-reliability`。原工作区评审文档保留。临时证据限定 `docs/verification/artifacts/2026-10-11/`，不采用技能默认根目录临时产物位置。

## 任务台账和文件所有权

| ID | 状态 | owner / 实施边界 | 下一步 |
| --- | --- | --- | --- |
| R0 | 外部身份/设备门禁待补 | root；保留现有最终包证据 | 核对可获取最终签名资料，不猜测已安装身份 |
| R1 | 已部署；真实用户恢复仍需分桶观察 | root；commit c8342ca4；固定8082 | 生产聚合后验，不读取用户恢复材料 |
| R2 | 已部署；设备到达率待测 | 46c853f4（原9d32bdfd）；精确候选51PASS | 观察真实业务与设备回执 |
| R3 | 已部署；实际媒体流量样本待补 | 53757826；精确候选15PASS、API/worker guard通过 | 线程池/对象内存仍有后续任务 |
| R4 | 已集成及双审 | 6999a563；138Flutter、24JVM、analyze0 | 共享候选/成品/真实配额与锁屏 |
| R5 | 网关已部署；客户端已集成双审 | 服务端95fc1927；客户端ddfa73b9含远端5分钟对账/429硬期限/真实Managed gateway与IANA DND元数据 | 共享候选、iOS原生及真实APNs/Focus |
| R6 | 已集成双审；135项R5/R6联合PASS | c772a503/6ee91ed7/1f527262/8242b89f；真实settle保留房间额度与离页registry ownership | 最终共享候选与设备弱网 |
| R7a | 固定分页与checkpoint修复已集成双审 | 75d2c969/1284772e；独立32PASS；256正文/页、维护租约不跨网络等待 | 真机profile；ID元数据仍O(N) |
| R7b | worker哈希与大seed预览已集成 | bee0891c/4662f576；一次worker proof、64KiB小对象例外 | 最终共享候选与设备峰值 |
| R7c | 已提交及双审 | root；7454986f；40PASS/analyze0，独立17PASS | 共享候选与真实冷温热启动 |
| R7d | 热查询块索引已集成双审；冷查询待后续 | b888e282；43相邻+8独立PASS；1M warm仅2624 ID；冷构建仍O(N) | 实机profile、cold/提及元数据另验 |
| R8a | 上传前预检及SDK/lease接线已集成双审 | 8475a0b4/8d3a38f3/3e0ce735；独立14PASS | 最终共享候选 |
| R8其余 | 活动预算候选已集成；持久任务/缓存索引实施中 | 9b9ab4d7（原82a8eca5），127专项PASS；native53bd03f4+bdbaab66，6+11相邻Android PASS；durable独立owner | 预算双审、native复审/macOS、真实持久接线后共享候选 |
| R9 | 日志轮转已部署；其余待实施 | root；commit b307704a | 峰值观测/隔离冗余/历史治理仍待 |
| R10 | 有界脱敏运行采样实施中 | fix_scheduler_r6；固定分桶、守恒分母、不输出原始URL/正文 | 采样器测试/独立审查；实机/群容量单列 |
| R11 | 外部审核依赖 | 厂商通道申请 | 获批后按固定包名签名接入 |

并行实现使用独立工作树及不相交文件；实现者不部署。root 汇总后按规格/领域→质量安全顺序审查。历史脚本/证据不能代替当前候选门禁，未完成的测试不标通过。

## 阶段时间（UTC+08）

| 阶段 | 开始 | 结束 | 证据/结果 |
| --- | --- | --- | --- |
| 隔离与任务分配 | 2026-10-11 10:20（近似） | 进行中 | 主工作树创建成功，R2/R3/R4已分配 |
| R1 环境预检 | 2026-10-11 10:24 | 10:27 | 本机 Docker29.8.2可用；宿主 Python 无 Twisted，原生门禁改用隔离 Linux 镜像；不冒充已通过 |
| R1/R9测试与双审 | 2026-10-11 10:27 | 10:53 | R1单元16、真实PG16.9计20、旧HTTP503 RED→候选Twisted14PASS；infra925PASS+jsonschema环境缺库1失败，已有依赖环境单项补验PASS；R9三RED→三GREEN及实际轮转 |
| R1/R9生产切换 | 2026-10-11 10:53:36 | 10:54:12 | 三容器healthy，HTTPS Matrix200/APIready200/recovery未授权401，其他容器ID保持 |
| R2/R3精确候选与切换 | 约11:00 | 11:16:39 | 51/15候选专项PASS；候选/回退双角色guard；切换11:16:10–39 |
| R7c实现/验证/双审 | 约11:18 | 约11:29 | 长等待/真实main/首帧指标三组RED，最终40PASS、独立17PASS、analyze0 |
| R5b服务端构建/验证/切换 | 约11:24 | 11:29:50 | 精确server候选11PASS；SPEC/domain→QUALITY；切换11:29:46–50 |

## 发布与回退

R2/R3 11:16:39发布成功：Getui `sha256:0d3c204b0df4863a8826aef6b58556f0fc9c8a6c89d5ca0ec137eec81fe7f43c`，API `sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3`。schema0095保持，worker与其他容器ID未变。实际candidate内51项/15项分别通过；API初次夹具缺avatar.png导致setup错误，补齐固定夹具后15PASS，未修改candidate绕过测试。候选和回退API/worker均通过现场release guard。11:21:48聚合后验：API运行健康/零重启/零traceback，其他业务171次200/5次202/10次204；未观察到媒体样本，不能声明生产媒体延迟已达标。Getui零新日志样本，HTTP成功不冒充设备到达。

R5b Sygnal 11:29:50发布成功，镜像`sha256:90fa02ff684b44aaaa08971845c2ed21d1d838eb4fb38c9e649d69a5be360dd0`，原0.15.1镜像和runtime/config/mount保持可回退。两源文件SHA及mounted配置hash通过；空JSON返回400，未发送真实通知；HTTPS Matrix/API通过，其他容器ID保持。实际候选network-none/只读容器11策略测试通过。普通iOS pusher必须由新客户端携带策略后才启用DND，现安装旧客户端不宣称已获得新行为。旧日志硬链接完整保存，证书/私钥仅留原私有挂载。

R1/R9已部署：Synapse主/同步镜像`sha256:0e861d72f57d56367c393994959cb4e85a1c485142adef7928fe5662d565185d`；模块SHA`2210e152f422d57dc585acfd95e912d58a55596f2112efea0b8c764ce2b09ad7`。gateway镜像不变。三服务日志20m×10，旧Docker日志用同文件系统硬链接完整保留于服务器0700私有目录，未truncate。

服务器发布根`/opt/starchat/releases/im-reliability-20261011`，冻结回退Compose在`private/<service>-rollback.json`，原Synapse镜像`sha256:449fef97b26ba00d62b7c128bdff1e440a127349f89fedf0e6556721c3aa2876`。实际部署receipt为`core-deployment.json`，本地副本见artifact/core-deployment.txt。此阶段不写用户恢复数据、不改业务API/worker，不声明真实用户登录/恢复端到端已验收。

API/worker后续发布必须续期协议release guard。现场guard SHA78b2beb6…beec；probe为`business_refresh_image_probe.py`，SHAa2a74012…858f，与仓库当前文件完全一致（历史摘要d77值不用于此次发布）。生产配置/秘密仅留服务器0700目录。禁止自动重放历史财务DEAD、删除密钥或破坏性回退。设备通过声明绑定实际版本/成品SHA。

`scripts/verify.ps1`预检：工作树无`.env`，主脚本不能直接完成render；已分别完成repository/deployment/template/Compose/OpenAPI门禁，不声称整脚本exit0。全量共享候选门禁继续安排；R2/3具体报告保留两项环境失败及针对补验，不能把分次成功写成一次全绿。

## 12:40+08 阶段更新（客户端尚未发布）

当前正式两端仍为2213，不能将当前源码修复算入已安装包。Android/iOS成品构建、固定签名/回签、保留数据覆盖、真实锁屏与声音尚待；不把单元/模拟器作为实机结论。iOS旧最终包的身份连续性缺口仍保留。

R7d精确数据：旧百万未知ID冷/热10726/10926ms；新首次构建13081ms，热434ms/2624 ID；独立复核10090/320ms/2624 ID。这些是Windows合成数据而非手机指标，新冷构建没有变快。相关SQLCipher DLL与源码hash已归档，不随测试库入Git。

原生存储首审未签通过时已发现并修复两处边界：iOS目录占普通文件名、两端悬空optional链接。Android新增真实RED→17PASS；Swift新增同类XCTest待实际macOS结果。诊断CI绑定bdbaab660f521ccd686069740920aca418041861，run38112151641，2026-10-11T04:37:03Z开始。只推送专用codex/im-native-storage-20261011分支运行原生门禁，无产品分发、TestFlight上传或生产配置变更。

R8活动逻辑预算192MiB不是RSS上限；普通文件48MiB、图片/视频31.5MiB还取现有业务限制较小值。超过限制必须明确提示且不无限重试，RoomPage/pending UI由持久任务owner一并联测。当前队列驻留/相册native originalBytes入口仍待文件化，不声称OOM已经解决。

后续按序：预算与原生复审→持久任务/目录索引冻结集成→一次完整共享门禁及两端原生→递增版本构建/固定Android重建验证→授权范围内分平台交付。外部签名/设备仅阻断依赖步骤；R9 7–14天资源、隔离冗余/RPO/RTO、历史财务DEAD及R11厂商资质仍为明确未完成项。
