# 个人信息与账号设置反馈实施

## 恢复入口

- 用户授权：2026-09-26“按此方案正式实现”，已批准6–20位字母开头、大小写不敏感、首次可改/成功后365天、新号业务登录搜索、稳定Matrix身份、五分钟账号内存缓存及七项资料行；前轮Debug模拟器安装授权延续。2026-09-27明确“批准发布服务端候选”，授权API9083f027/worker15659d6c及0088→0089扩展迁移。
- [设计](../../superpowers/specs/2026-09-26-account-profile-followup-design.md)、[计划](../../superpowers/plans/2026-09-26-account-profile-followup.md)、[ADR](../../adr/2026-09-26-mutable-changliao-username.md)、[验证报告](../../verification/2026-09-27-account-profile-followup.md)。
- 状态：服务端已发布且必要验收通过；Debug0.4.15/2182已保留数据安装emulator-5556并启动。原D源码已完成回填并保留并行regional网络摘要增量，该未发布增量不在本次冻结服务或2182中。
- 工作树：`C:/Users/Administrator/.codex/worktrees/account-profile-followup/StarChat`，branch `codex/account-profile-followup`，baseline `b9eca8a419614112b085439445b7fd031027a740`。78项主目录输入快照、生产r4源及最新已安装6f11c603移动源已按范围融合；无Git提交/推送。
- 文件所有权：后端、页面、缓存owner均已交付；root整合，独立代理只拥有报告/overlay工作件，不并发写源。原目录七个新drift已按SHA审查并融合，341项回填/保留完成；D全analyze和151项API交叉回归闭环，独立规格及安全复审通过。
- 最后更新：2026-09-27 01:50+08。下一步：真实已绑定手机号/邮箱OTP、iOS及真机体验待用户复验。

## 验收台账

| ID | 预期 | 实现与证据 | 发布/设备边界 |
| --- | --- | --- | --- |
| C1 | 账号安全/聊天5分钟热缓存、后台刷新、会话隔离 | fresh零GET/无spinner、过期先显示、singleflight、登出/换号失效、可信refresh保留；pending/迟到绑定与序列群偏好锁；手机OTP固定身份red4→core61PASS，独立复审PASS | 2182已安装；真实账号重进体验待复验 |
| C2 | 账号安全服务接口开放 | API/worker候选发布、双侧TLS健康200，新security/username GET/PATCH未授权401，25其他容器不变 | 指定候选healthy/restart0；未主动发送OTP |
| P1 | 七行顺序/右对齐/箭头/独立编辑、手机邮箱直达 | mobile页/控制器、HTML/catalog/token一致；UI33/462及frontend318PASS；保存失败改回原值返回页P2真实red→green；无可见字数计数，保留grapheme12/20规范 | 2182；HTML浏览器目测通过 |
| U1 | 格式/索引去重/365天/稳定身份 | claims归属表、共同namespace锁序、事务幂等/审计Outbox；真实PG注册改号死锁red→green；领域/安全复审通过 | 新号业务登录搜索，UUID/Matrix/E2EE稳定；首改可用，成功后UTC365天 |
| U2 | online/offline迁移与恢复 | PostgreSQL16生产备份隔离恢复，在线/离线0088→0089/冲突前置/索引约束通过；生产迁移exit0，137表/263072行及UUID/Matrix摘要不变、46claims | 0089已上线；禁止破坏性downgrade |

## 版本与证据

- API：`sha256:9083f0279fbc46811e49fd546322ac66c29b572d4b8cc5460478a1915a0701a8`；worker：`sha256:15659d6c20a464d75fa2a5c81d2c3d91648c8e2e04d0b47fd3871046e85ef638`；head `0089_username_claims`。
- Debug：`com.liuhetong.mobile.debug`，0.4.15/2182，ARM64；最终SHA `44bce182f4321b7051206807a7c59e794d1b22b33da68b8895580cf0456bf1a3`；固定签名 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。主目录包：`docs/verification/artifacts/2026-09-26/account-profile-followup/android-2182/changliao-0.4.15-2182-debug.apk`。
- 已重建25DEX及资源，27317类/339原生资产、manifest语义一致；设备APK读回SHA相同、首次安装时间2026-09-26 04:06:20保留、前台/进程正常、此次启动无crash。实际前包0.4.13/2181，未降级/卸载/清数据。
- 完整verify原结果2811PASS/92条件跳过/2FAIL(exit1，旧迁移head断言)原样保留；专项15PASS关闭，续跑mobile108PASS/1skip、UI/API/AST/迁移/OpenAPI/Compose exit0。最终Flutter合并6f全量4657PASS/9skip/10FAIL(exit1)的全部失败以必要专项46/7/20及root53PASS闭合；analyze无问题。不是原完整脚本exit0，详见验证报告复用输入边界。
- 本轮证据目录 `docs/verification/artifacts/2026-09-26/account-profile-followup/`；生产发布 `docs/verification/artifacts/2026-09-27/account-profile-followup/server-release/`。Windows/Python3.12/Flutter3.44.9-Dart3.12.2/Node22.22.2，真实恢复PG16与本地并发PG18分别记录。

## 阶段计时

| 阶段 | 实际起止（+08） | 类型/并行 | 结果/来源 |
| --- | --- | --- | --- |
| 设计/实现/红绿 | 更早起点未知，owner各receipt | 主动/工具并行 | 不从mtime估总工时 |
| 完整verify | 09-26 23:36:09→09-27 00:06:39 | 工具，与UI/候选并行 | 原exit1，必要delta/continuation完成 |
| Android源码构建 | 09-27 00:31:54.209→00:34:55.874 | 工具，与发布并行 | 176.2s Flutter reporter，命令181.665s，exit0 |
| 服务端release | 00:32:34.550起；维护00:34:22.245→00:34:28.715 | 工具，迁移/切换顺序 | 维护6.470s，迁移2.440s；双侧TLS/最终schema+provider通过 |
| 固定签名重建 | 结束00:38:16.254 | 工具 | 各阶段rebuild-steps.json，未估整体起点 |
| 模拟器安装 | 结束00:48:19.951 | 工具 | install-r7.354s；其余检查各step记录 |

## 交接与回退

- 生产fresh备份27,121,763bytes，SHA5cc916af603498e351485ca2dbdfd9520adc0e817754ff83bf3613723e72a533，仅0700服务器release目录；不复制用户行/凭据。实际provider构造探针未invoke任何send，不能据此宣称运行中的worker从未发送。
- 保留兼容API `1045b2b6c4e50144ed1d5233808990cd854b4a89c42d4fc5e5be554eb2fa3ad2` +同新worker。保留claims-aware开户/锁序/新号归属与0089，仅移除新改号入口。不得直接回退不识别claims的旧r4开户，不删除表/列。
- 新候选无新增异常/Traceback；29条原ledger/wallet无消费者死信告警已追溯发布前backlog及相同模板，未扩大本任务处理财务消费者，不写总ERROR0。
- 自己的隔离PG16已停止但保留data；自己PG18/56389已停止；发布loopback SOCKS已关闭。候选HTML preview4188保留供审阅；没有官网APK分发/iOS/Git远端发布。
- 未发布regional网络摘要源码及合同保留在D，与本轮已发布/安装来源严格区分；后续需独立兼容接收端发布授权后才入客户端批次。真实OTP验收不由合成测试或健康探针替代。
