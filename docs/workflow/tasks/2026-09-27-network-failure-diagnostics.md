# 请求失败细类与服务端时间线

## 恢复入口

- 用户授权：接受上一回复“补充不含用户信息的错误细分类及请求阶段，再关联服务器时间线定位”，允许实施代码、验证、只读服务器调查；服务候选准备完成后单独按发布流程交付。既有Debug保留数据安装授权继续用于本次诊断增量，正式Android/iOS分发未授权。
- [设计](../../superpowers/specs/2026-09-27-network-failure-diagnostics-design.md)、[计划](../../superpowers/plans/2026-09-27-network-failure-diagnostics.md)。current-state恢复入口已读取；前轮Debug2186/PHONE API1aa6是历史事实，新生产快照由server owner重读。
- worktree：C:/Users/Administrator/.codex/worktrees/network-failure-diagnostics/StarChat；native工具创建成功，HEAD91292717b93a8f28bdd4e7d4cf30900c5c2dc918，移动基线来自本轮已交付Debug，后端tracked基线较旧，需要精确非秘密依赖/生产源预检，不将旧仓库当新live。
- 文件归属见计划：client仅network请求与business constructor；client另承接chat spool；root仅collector/report/文档；server仅契约/tracing/newtimeline/专属API测试及OpenAPI。不同owner不得同时写同文件。
- 当前：客户端及服务端增量、采集关联工具完成，Debug0.4.18/2187已保留数据安装；API e3043e9a…1ec8f已按具体批准发布并验收。初始用户响应确切时刻未知，不编造总工时。
- 下一条：有新的2187失败记录时，运行闭合采集及同请求ID关联；缺单侧记录或覆盖不足仍标未知。正式包及iOS原生分发需对应交付授权和环境。

## 验收台账

| ID | 场景 | 当前状态 | 局限 |
| --- | --- | --- | --- |
| N01 | 错误细类和可信阶段，8秒预算/迟到响应 | 实现及专项通过 | HTTP接口不能准确分DNS/TCP |
| N02 | 每次请求随机ID、401重试独立、无身份/正文 | 实现及专项通过 | 未随新包安装就没有新字段 |
| N03 | 闭合兼容接收/spool限额/422恢复 | 实现及专项通过 | 新API已按明确批准发布 |
| N04 | bounded非阻塞服务端时间线、ASGI边界 | 实现及专项通过 | send返回不等于手机收到 |
| N05 | 闭合采集/join与历史58/15原因 | 历史原因未知；新工具及真实TCP fixture通过 | 无ID的旧摘要不能补造 |
| N06 | 实际构建/候选/验证/安全回填 | Debug已安装；API已发布并验收 | 真机及iOS环境另列 |

## 证据与交接

非Git验证及临时工件仅docs/verification/artifacts/2026-09-27/network-failure-diagnostics/。部署源码/config/容器/schema事实须重读，保留PHONE/S3/诊断，旧d392/e880候选不得覆盖live。原始log/env/数据库/账户或IP不导出。本设计不新增未登录入口或认证策略，受保护金融/Matrix规则不改。阶段开始/结束带+08和真实exit/hash；完整门禁等价输入仅执行一次。

## 本轮验证和交付

- 客户端170项检查点及最后91项影响复测、analyze无问题；collector真实red→green16项，独立规格/安全审查两项发现均已关闭。共同Dart/Python JSON golden准确roundtrip。
- 完整Flutter原运行4852通过/9跳过/4环境失败（旧后端契约、缺moments夹具）；候选契约与既有fixture补齐后，相邻37通过+唯一fixture失败再单例闭环1通过，版本相关已有断言通过。原全量exit1保留，不称最终整套重新通过。最终全analyze无问题。
- verify原运行20:48:22→21:19:06，API/worker2813通过/75跳过，仅旧worktree的OpenAPI源基线与实际生产候选契约不同导致1失败，整脚本exit1。主工作区339集成通过；当前契约/移动门禁131通过/1跳过/1单项按同项冻结源码检查替代，冻结源码保密检查1通过。其余UI/AST/Compose门禁通过。隔离旧tree的0087离线head不是生产0090，不作为生产迁移事实。
- 主目录保密扫描曾遍历历史验证工件，CPU热循环无输出，堆栈已证明；两次中断均保留，不算通过。未修改或削弱扫描器；对本次冻结源码执行同一安全断言6.4秒通过。
- 服务端Linux已安装187通过，真实loopback TCP超时和同UUID ASGI完成、鉴权202/401；旧镜像扩展422后baseline202。只读旧生产采集8183行/62旧诊断，不含新请求字段；无新字段不是无网络错误。局部历史gateway日志不能还原旧73次错误。
- API e3043e9a…1ec8f基于1aa6PHONE/S3，仅三个文件、1071原文件保持、0090无迁移；freeze/finalize区间29容器未变，需发布前重读。复用模型/迁移未变的同日PG16.9隔离恢复证明；无新备份或迁移。未含未发布startup route。
- Debug冻结1939c62b750b8befc08b7009fa49ef7369a588a2、1779文件，manifest2d7f1742…584b；构建21:05:43→21:09:23，所有重建/固定签名/资产及smali语义/锁屏边界门禁通过。最终APK135278760字节，SHA3cb9be750f7018f178927aaf7aa2dd6422766359da6f19b397d8a61678113135，证书75b31c…1fff。
- ADB流式安装固定在40.09733%未提交；仅终止本次匹配客户端，系统已撤销会话，后续abandon返回无访问权且active中已无该会话。改非流式21:22:03→10，成功2186→2187，UID10090/firstInstall2026-09-26 04:06:20保持，MainActivity启动、pid存在。正式分发未改，Windows未做iOS原生编译/实机验证。
- 已guarded回填D：mobile补丁apply-check成功；receiver与freshlive基线吻合；tracing保留原本地startup审计标签屏蔽，并屏蔽该匿名入口的新增请求关联ID，专属integration真实red1→green1。该本地匿名差异未进入production候选。并行financial/business及notifications修改保留；主契约按主代码正常生成。

证据入口：docs/verification/artifacts/2026-09-27/network-failure-diagnostics；API报告server-candidate/candidate-report.md，Debug安装android-debug/installed.json，主集成main-integration-tests.log，source/backfill-review JSON。APK及解包E mirror位于E:/StarChatVerification/docs/verification/artifacts/2026-09-27/network-failure-diagnostics/android-debug/run-20260927-210700。所有起止是各工具实际记录，并行时间不求和；未精确计时的主动工时未知。

## 获批生产发布闭环

用户明确批准API e3043e9a…1ec8f。2026-09-27 21:44:21.145→21:44:36.807+08仅切API，容器5e43f3e6…，schema0090未变，28其他容器/worker/运行配置/mounts保持。服务端严格TLS live/ready200、诊断及账号未授权401，实际源码与候选一致，新错误0/restart0，watch timer active。首轮verify因Env列表顺序exit1，完整唯一键和值multiset相同已证明，改按键值及multiset验收后通过，没有改变生产配置。

工作站经自有临时jumper SOCKS严格TLS健康200，随机请求ID07f4f85b…唯一关联到生产1ms complete记录；隧道已关闭。Debug2187于服务发布后force-stop/relaunch，pid23146，数据保留。闭合采集69条server/0条client失败记录，0非法记录/无截断，但日志保留未核实；server-only不是失败或用户数。历史2184的58/15仍无确切根因。具体生产鉴权202复用候选隔离验证，无生产账号伪造/验证码或金融写入。

证据：server-publish/release.json、protocol-closure.json、final-live.json及live-new-report.json。该API不包含既有未发布启动诊断路由；iOS未原生打包或分发。
