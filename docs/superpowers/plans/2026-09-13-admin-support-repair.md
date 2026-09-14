# 客服管理、点钻派发与充值补入账实施计划

> 执行：显式 gpt-5.6-terra 子代理；主线程 Astra 逐批亲审实际 diff、调用链与证据。用户本轮已授权连续执行本需求，使用当前工作区，不另建工作树，不覆盖既存改动。

## 目标与架构

客服身份及后缀由业务 API 权威提供；沿用现有客服角色授权/撤销、账本 application service、资金预检/执行机制。后台改名并提供搜索选择，Flutter 通过共享组件在昵称或备注后显示黄色 @后缀。后缀按每位客服配置，2～6 个汉字，默认官方客服；不把后缀写入 Matrix 昵称。

关联历史审计 F03（旧托管充值补记账，非本次人工补录路径）、历史交付 F1（人工充值补入账）、ADR-0008 和 ADR-0066。当前新增验收编号 S01–S04、G01–G02、D01–D02，不冒用历史审计已完成结论。保持个推、E2EE、CAIBI 两位/USDT 六位、幂等/审计/Outbox、现行权限与钱包授权。

## 批次与文件所有权

- [x] B1 / S01–S03、G01：Terra 后端。允许 services/business-api/app/api/admin.py、support.py、modules/admin/、modules/support/、新增扩展迁移、相关 admin/support 测试及 OpenAPI 契约。精确解析内部 ID/畅聊号/邮箱，拒绝歧义；客服角色限现有三种；搜索列表有权限与分页，邮箱脱敏；逐用户后缀持久化校验；移除客服身份复用公开服务且保留其他角色。派发仍调用原账本逻辑且仅允许原可派发资格，不扩大金融权限。验收：别名与旧 ID兼容、默认值、2/6边界及1/7/非汉字拒绝、角色撤销、非客服拒绝、权限/幂等/审计/Outbox。先 pytest 失败再实现及定向回归，迁移单 head、导入与契约检查。
- [x] B2 / S01–S03、G01–G02：Terra 后台（依赖B1）。允许 frontend/src/admin-home.js、admin-api.js、新客服表单模块、相关样式/测试。标题客服管理/客服点钻派发；输入畅聊号或邮箱并兼容ID；角色下拉默认SUPPORT_AGENT；客服搜索下拉；原因下拉默认SUPPORT_CAIBI_GRANT；移除操作明确确认、成功刷新，失败保留输入。验收 node 定向真实交互测试（默认、搜索竞态、错误、撤销、命令参数、金额字符串）。
- [x] B3 / S04：Terra APP（依赖B1，不与B2共享文件并发）。允许 apps/mobile_flutter 的身份读取/联系人/会话展示/共享组件与相关测试、frontend/src/catalog/与demo组件、tokens、packages/ui-contracts/changliao-component-registry.json。先登记和HTML demo，后实现。覆盖联系人、私聊标题及会话列表中已识别用户的昵称/备注后缀，来源仅业务API；撤销/失败不伪造官方状态、不跨账号缓存。验收 Flutter 定向/分析、UI契约及HTML测试；真机用户负责。
- [x] B4 / D01–D02本地界面部分：Terra实施、Astra实际diff/调用链与17项定向复核通过。预检明确不入账，成功EXECUTED通知父列表刷新，保留筛选分页；恢复查询不重放，刷新/本地存储失败不误报资金失败。后端原金融机制未修改。实际生产交易阻断仍待用户txid/预检提示，不据历史快照强行认定。证据：docs/verification/artifacts/2026-09-13/admin-support-repair/wallet-astra-green.log。
- [x] B5：Astra 规格审查→质量安全审查→跨模块验收；发现问题交Terra修正。检查实际diff与既存改动保留；定向、全量适用门禁（verify先环境检查）、契约/迁移；如实分类已有失败、环境阻塞、未上线/未真机。

## 执行约束与验证

最多两个执行子代理，共享文件串行。所有实现回报必须带文件、实现说明、真实测试命令/退出码与日志、未解决项。主线程维护本计划和任务记录；代理仅写自己的证据文件。日志/快照仅 docs/verification/artifacts/2026-09-13/admin-support-repair/。无自动提交、push、生产部署或真实资金写入；若本地修复完成，报告实际发布边界。

## 批次审查进度（03:00+08:00）

- B1：二次复审通过，Astra亲跑52项服务端相关/钱包回归全通过；已核对旧幂等payload、三客服撤销保留USER/SUPER_ADMIN、别名派发及批量lookup真实断言。单头0065，OpenAPI已更新。全局ruff较基线29项降为28项，没有新的实质lint问题（Complaint提示仅行号变化）。
- B2a：真实后台客服管理/派发及专用合成预览，Terra执行中。B2b随后修复原wallet演示候选模拟与旧自检按钮。
- B3a：身份分批及联系人页生命周期16项通过，Astra复核发现fallback联系人列表周期刷新和contactChanged即时刷新仍需补齐；已交同Terra随B3b修正。
- B3b：会话列表/私聊标题真实接线及API换对象迟到回复widget断言执行中。
- B3c：B3b通过后做HTML/catalog、token/registry与UI契约，最后共享Flutter全量/分析。
- B4：本地界面定向通过；浏览器旧demo缺候选模拟，纳入B2b，尚未将浏览器结果记为通过。

## 最终规格与质量审查

- B2：Astra实际源码、36项定向与浏览器合成保存/派发复核通过；原生select、分页、默认角色/原因、别名接口、2–6汉字与失败草稿稳定幂等键已实现。删除接口与失败分支有自动化证据；浏览器原生confirm阻塞CUA，未声称浏览器删除成功。
- B3：联系人、资料页、私聊列表和标题业务身份接线完成，真实页面测试通过；共享HTML组件、29组件registry与363页面契约已核对。API更换失效已亲读代码，RoomPage迟到响应专门页面测试未新增，不将该覆盖扩大表述。
- B4：浏览器合成预检不入账、明确确认后EXECUTED、父列表CREDITED已验证；生产具体交易仍需txid/预检阻断信息，未部署或真实加款。
- B5：Flutter2474通过/29既有钱包失败、分析通过；HTML179通过/5既有失败。全仓后端1862通过/52跳过/2迁移head预期失败，已同步0065及release preflight，仅复跑受影响门禁，按不变输入证据复用规则不重复16分钟全仓。
- 追加允许文件：scripts/wallet_release_preflight.py仅EXPECTED_HEAD；tests/business_api/test_migrations.py、test_wallet_release_baseline.py和tests/mobile/test_ui_component_registry.py同步新迁移/组件数量，保留安全与历史祖先断言。

最终受影响门禁Astra复跑49/49通过；本任务本地审查完成，外部及既有失败边界见主审记录。
