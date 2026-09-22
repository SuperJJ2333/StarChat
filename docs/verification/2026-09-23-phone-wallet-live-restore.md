# 手机、汇率、充值线上恢复

结论（2026-09-23 01:02 +08）：配套API/worker与客服后台已上线，主工作区已回填兼容修复；Mi6仍使用0.3.103+2158，无需重新安装。没有发送新的真实短信或执行真实充值/提现，用户端真实操作验收仍待反馈。

## 已上线范围

| 验收ID | 结果与证据 |
| --- | --- |
| R1 手机换绑 | phone_auth_enabled=true、Aliyun SDK2.0.0及原已验证供应商配置已装配；公开HTTPS请求从404变为受保护401，未绕过认证 |
| R2 参考汇率 | apihz配置上线；首次请求成功，60分钟持久快照，同窗重复读取复用。1USDT按1USD估算，仅供参考，客服最终结算权威不变 |
| R3 取消充值 | 新充值请求与旧deposit-intent取消路由均上线；取消不修改余额，迟到收款保留待核对义务 |
| R4 原有兼容性 | 恢复已丢失的refresh operation恢复协议，保留最新monitor-margin代码；0083合并两条迁移历史，未重编号或stamp |
| R5 客服处理 | 用户明确授权沿用现有平台地址、所有客服处理；通过既有服务登记5个ACTIVE客服，幂等授予FINANCE_SUPPORT。未授予SYSTEM_ADMIN，实际入账执行保留既有财务权限和流程。后台3个JS文件发布且公网SHA一致 |
| R6 旧群兼容 | 未登记业务群的转让时间线返回404 GROUP_NOT_REGISTERED，保留认证和已登记群的群主/管理员权限；不从Matrix推断财务群主，不自动创建业务登记 |

## 实际发布身份

- 隔离分支：`codex/phone-wallet-live-compat`；最终提交`60238a4b61afff3d15169129575e6c507f947ad6`，完整门禁基线`ddf81fb18dacab0edaf098e8f99b4931ab5b13a3`。
- API：`starchat-business-api:phone-wallet-20260923-r2`，image ID `sha256:6c79db972b32540a885d7f0b5be9bed0af187d0bc5f222ab5ae4f7cab68c9fe9`。
- worker：`starchat-business-worker:phone-wallet-20260923-r2`，image ID `sha256:09dbe2e56f9e079216ff722b059e639f02a88be3d106b61bde40b560790dcec7`。
- 实际迁移head：`0083_phone_wallet_refresh_merge`。
- 宿主机发布/备份目录：`/opt/starchat/releases/phone-wallet-live-compat-20260923`，0700；私密配置和数据库备份不下载到仓库。
- 最终Compose：该目录`candidate-api-r2-private.json`、`candidate-worker-r2-private.json`。镜像固定为实际image ID。
- 客服后台沿用现有样式组件；仅`admin-home.js`、`admin-api.js`、`admin-recharge-panel.js`发生发布变化。

## 验证与实际限制

- 整合候选完整verify：exit0，后端2544 passed/59 skipped，OpenAPI/Compose/Alembic门禁通过。59项skip保留为当次未执行；另在隔离PG补验11项认证用例全部通过。
- 生产备份隔离恢复：原0080刷新分支升级0083；122张既有表、206610行的原字段摘要完全一致。恢复副本不接生产网络，验证后容器和卷已清理。
- 取消与到账真实PG并发、同键幂等及历史保护见前轮取消证据；本轮恢复演练保留其迁移，未改变取消实现。
- 提现重领指令缺陷已修正：调整汇率后同键重领返回权威金额/摘要，保留鉴权、审计和原始命令；专项71通过。
- 前端237通过；认证合并共存、刷新兼容及PG专项通过；主目录回填专项68通过。
- r2仅修改已认证的“业务群不存在”读取分支；先红403→期望404，全部群模块67通过，OpenAPI无漂移。复用其余不变输入的完整门禁，不重复跑全仓。
- 服务器和工作站均通过真实TLS公网健康JSON200及受保护接口401；3个后台文件公网SHA符合清单。401证明路由/鉴权存在，不能冒充用户业务成功。
- 首次切换后API/worker零重启、无Traceback/maintenance失败，worker心跳正常；15个其他生产容器未重启。
- 主目录API/迁移/worker333个文件与最终候选逐文件一致；保留原有其他未提交修改，未将整份脏目录发布。
- 群主转让协调和群主抽成开关仍关闭，未纳入本次线上恢复范围；用户兑换和自动充值保持关闭。实际客服资金记账仍需要原有授权流程。

## 回退与后续

首选兼容回退为同目录`candidate-api-private.json`、`candidate-worker-private.json`（第一版已验证phone-wallet镜像，支持0083和新计价，仅缺r2旧群404修复）。按生产工作流只切换API/worker；保留新增表、审计和在途订单。旧`rollback-*-private.json`是发布前现场快照，其margin镜像本身缺刷新恢复，不能把它当无条件安全回退。禁止还原整库覆盖发布后的真实交易或做破坏性downgrade。

下一步：用户在Mi6重新进入相关页面，确认实际收码、参考到账展示与取消结果；客服刷新后台确认案件处理入口。未代用户制造充值、提现或短信验收数据。

证据目录：[phone-wallet-live-compat](artifacts/2026-09-22/phone-wallet-live-compat/)。关键工件：`verify-full.log`、`verify-exit.txt`、`restore-after.log`、`config-proof.log`、`public-proof-final.log`、`groups-r2-deploy.log`、`main-candidate-parity.json`。工件目录沿用本任务跨日开始日期。

计时：完整候选后端测试24分33秒；群r2专项89.94秒。首次切换00:33 +08，最终报告01:02 +08；总体起始未统一记录，不估算完整墙钟。返工包括隔离PG首次启动窗口重试、安装包源与site-packages导入路径对齐、旧群403兼容边界；均在相应步骤验证后继续。
