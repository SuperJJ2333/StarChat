# 客服订单后台实施验证（2026-09-23）

范围：frontend/src/admin-recharge-panel.js、admin-api.js、admin-home.js、admin-dashboard.js、admin-wallet-access.js、admin-order-notifications.js、admin-support-order-access.js、styles/admin-modern.css 与相应测试。主目录 main 上实施，无分支、提交、生产动作和真实资金动作。

## 交付

公共充值队列 / 我的处理中 / 待核对绑定 / 历史与审计入口；认领前和其他客服处理中只读；服务端到账核验前不出现结算入口；实际到账与最终点钻均取服务端。结算仅绑定既有财务调整，审批未执行明确保持未入账。可见时60秒续租，任何续租或写入失败清除本地写入能力；旧队列响应与卸载后的认领均被阻断。

侧栏补回之前遗漏的 recharge 模块。充值工作台可跳至现有提现页面，保持其钱包验证与出款流程。客服充值使用独立 support-orders 60分钟验证范围；复用现有验证组件，登录近期性不足调用已有身份验证对话框。TOTP策略未配置时引导同账号官方APP开通，不降级为密码。

全后台可见时每10秒读取服务端事件游标，增量通知徽标与站内提示；重复事件去重，网络失败保留游标，401/403停止轮询。未申请浏览器权限，未发送外部通知。

## 测试和证据

- Red：新增 admin-support-orders.test.mjs 首跑 ERR_MODULE_NOT_FOUND，缺少订单通知模块（exit1）。旧无认领用例改造前4项操作测试失败，更新为先认领、服务端已核验的合法前置条件。
- Green：node --test frontend/tests/admin-support-orders.test.mjs frontend/tests/admin-recharge-panel.test.mjs frontend/tests/admin-dashboard.test.mjs：25/25，之后新增 support security API契约用例。
- npm test --prefix frontend：250/250，0失败（约1.8秒）。包括真实路由编码、幂等头、claim token、所有权只读、未核验阻断、403续租、隐藏暂停、陈旧列表、卸载阻断、通知断线补齐/去重。
- Chrome真实DOM隔离 fixture：frontend/tests/support-orders-browser.html，认领→核验实际49.500000USDT→绑定审批调整→待审批未入账，PASS。所有fetch为隔离响应，没有向业务服务器发送请求。
- 截图与DOM：docs/verification/artifacts/2026-09-23/support-order-workflow/admin/workstation.png、browser.html。已目视复查，修正长txid跨列溢出；使用原后台按钮/输入/表格与颜色token。
- Demo生产页面：frontend/admin.html，充值模块；独立验收展示：frontend/tests/support-orders-browser.html。
- Figma 已退役：本次变更仅更新 HTML demo（frontend/tests/support-orders-browser.html）。无Flutter后台对应组件；共享registry由移动实现者统一维护。

## 尚待主任务汇总

后端新接口、独占认领及资金核验集成、最终review契约、UI-contract全门禁和根verify由主任务冻结后执行。上述浏览器验证不等于真实后端或生产验收。未部署、未安装APK。准备/实现/专项测试发生于本轮分工期间，最后一次本地验证记录2026-09-23 11:47 +08:00；并行墙钟不另行累加主任务。

补充（11:51 +08:00）：review接口契约已接入。超时/NEEDS_REVIEW认领明确发送review:true与至少3字符原因；管理订单的绑定重试/释放携带claim_token，缺有效认领只读。前端权限字段admin.finance.review由根任务映射。追加专项通过后，全前端251/251，0失败（16.3秒）；Chrome再次PASS。钱包验证专项14/14通过。

## 追加：可靠通知与客服提现（本轮继续）

新增 app/modules/recharge/notifications.py、notification_models.py 和0086_support_order_notifications（down0085）。每客服订阅行数据库锁下分配本地连续序号并保存安全通知投影。每次轮询反查尚未入箱的Outbox ID，没有按生产时间戳跳过历史区间；老时间事件迟提交仍会获新序号。cursor为绑定客服的持久UUID，客户端消息ID仍为原Outbox ID，响应丢失可用原cursor重试。筛选实际wallet主题manual_payout操作，排除quote、其他钱包操作和客服目录变更。

Red：test_order_notifications.py首次缺模块，exit1。Green：8 passed（SQLite并发/分页/断线/重启/跨actor游标/安全投影）。真实PG：test_order_notifications_postgres.py 1 passed，使用单独support_notifications_20260923数据库；旧事务已flush INSERT但未提交，新事务先提交并被轮询，然后旧事务提交，四并发轮询均补到旧事件且序号唯一连续。没有修改共用support_review测试数据库。

已补admin.finance.review前端权限映射。Root集成通知service调用、模型加载与最终0086单head迁移门禁。

新版有expires_at的充值：仅填写客服确认汇率，prepare-settlement创建绑定待审批调整，独立管理员批准后execute-settlement；不再手工填写任意调整ID。历史订单保留旧入口。Chrome隔离页面改为prepare契约且再次PASS。

新增admin-support-payout-panel.js及真实AdminApi scoped路由：在客服资金订单同一support-orders验证范围内打开公共提现/我的处理中/待核对/历史。认领→可选确认汇率并开始财务处理→明确开始出款后获得服务器指引→提交txid→查询核验；未核验不显示完成。所有写带claim_token/幂等头，visible60秒续租，失效即停写。原owner钱包入口仍独立。

提现测试red缺模块，green2/2。最新完整frontend：258/258，0失败（约1.94秒）。最后一次Chrome隔离prepare闭环PASS。无生产发布、真实资金或外部通知。

最新契约核对：支持提现超时后的原持有人证据提交/链上核对（即便5分钟租约已过），不开放再次出款/调汇率/重新认领。新增专项3/3。通知过滤补入support_claim/started/expired三种真实事件，明确排除heartbeat；通知专项11/11，PG实际乱序提交证据沿用上述1/1。

## 最终补齐与独立复审

历史充值恢复原 bind/complete-binding 路由且无需认领；新版仍保护 token。独立 SYSTEM_ADMIN 审批入口在归属判断之外，明确拒绝提交者自批；调用真实 ledger finance-review/admin-review。公共充值队列支持服务端 opaque cursor 下一页。客服提现 UNKNOWN 支持保留历史的 correct-candidate；过期未开始付款支持显式 review-claim（稳定 reason code + 幂等），已开始订单不显示接管入口。

新增 review-claim 红灯：前端实际显示普通认领导致断言失败；通知漏掉 wallet.manual_payout_support_review_claim 导致一条失败。实现后最终 frontend 265/265（2.14秒），通知 + 身份激活 + scoped payout 专项 45/45（54.66秒）。专项首跑两例因未设置 business-worker/app PYTHONPATH 无法导入 tasks；按 verify.ps1 同样设置后全部通过。UI verify-payment 每次点击已使用 crypto.randomUUID 新key，允许 proof过期后再次核验。git diff --check通过，仅existing LF/CRLF提示。

先规格后安全的独立审查覆盖激活已有账号/绑定联系方式/角色快照失效、OTP消费原子性、管理会话与 APP 区分、support-orders grant、提现不可接管、冻结资金与链上结算权威性。新增一项确认问题：review_authorized_at存在但租约过期时projection仍显示REVIEWING，导致无法再次显式复核。交提现owner修复，现未开始付款的过期reviewlease恢复NEEDS_REVIEW；owner专项12/12通过。其余本次只读范围未发现新的确定阻断。最终全量门禁由root执行；未发布或执行真实资金操作。
