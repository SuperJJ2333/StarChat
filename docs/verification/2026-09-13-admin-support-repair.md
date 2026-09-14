# 客服管理与充值补入账审查记录

状态：本地实现、规格与质量审查完成；全量仍有既有失败，未生产发布。

## 基线与模型

- 当前工作区main，HEAD `e28705548845d2296cdf34dcabd482926820adcf`。用户已有变更保留；起始差异在 `artifacts/2026-09-13/admin-support-repair/baseline.patch`。
- 主线程本地config模型 `gpt-6-astra`，执行工具允许显式 `gpt-5.6-terra`；两个spawn调用均显式传入模型并成功返回代理路径 `/root/deposit_diagnosis`、`/root/support_backend`。子代理自身无独立运行时模型探针，不将其自述视为额外模型遥测。
- Python 3.12.10、pytest 8.4.2、SQLAlchemy 2.0.52；Flutter 3.44.9 / Dart 3.12.2，SDK `C:/src/flutter`；Docker Linux引擎未运行，`.env`存在（未输出其内容）。

## D01 根因与审查

主线程读取 `admin-wallet-repair-dialog.js`、`admin-chain-panel.js`、`admin_wallet_repairs.py` 和 `wallet/repairs.py` 后确认：

1. 预检只固化快照和审计；仅执行接口会更新收据CREDITED、转移待处理义务并产生平衡账本、命令及Outbox。这是ADR0066既有安全流程，不能把预检改为自动写账。
2. 原弹窗execute/lookup成功后只改变弹窗，未通知父链上列表刷新，因此旧“待处理”仍可能停留。修复范围是成功反馈和刷新，不改变资金事实。
3. 历史F03审计针对旧托管webhook，不是此次人工补录路径。2026-09-10历史指定交易先付款后建单约30.68秒，不能当作用户本次交易的当前事实。已异步请求本次txid和预检提示，未收到前不认定实际生产阻断项，更不执行真实补款。
4. 第一轮diff审查发现新增成功回调若同步抛错或清理localStorage失败，会被外层catch误报为资金结果未确认；已要求Terra隔离成功后的副作用并补回归。

## 自动验证证据

| 检查 | 当前结果 | 证据与限制 |
| --- | --- | --- |
| 钱包原后端定向 | Terra执行28通过，5.16秒 | 主线程已检查相关测试与调用链；本批无后端变动 |
| 钱包界面最终定向 | Astra执行17/17通过，退出0，129.35ms | `node --test tests/admin-chain-panel.test.mjs tests/admin-chain-api.test.mjs tests/admin-completion.test.mjs`，frontend目录；`wallet-astra-green.log` |
| 前端初始全量 | 170项，165通过、5失败，退出1，16.12秒 | `artifacts/2026-09-13/admin-support-repair/frontend-baseline.log`；执行时Terra已开始修复chain测试桩，故不是完整未改基线。5项为manual-wallet 3、moments 1、image-editor源码色彩1 |
| Docker版本探针 | 失败：daemon未运行 | 不能声称已执行容器集成或真实PG门禁 |

本地另有PostgreSQL监听5432，但当前没有REPORTING_PG_URL，无密码本地连接不可用；不猜测凭据或将生产数据库用作测试库。B4成功副作用隔离已复审通过：localStorage清理异常保留原查询记录，刷新返回false/失败显示已入账且列表刷新失败。同步callback异常隔离为代码审查结论，不声称已有独立测试覆盖所有抛错组合。

B3已显式创建 `/root/support_mobile`（model=gpt-5.6-terra），与B1后端文件分离；B4代理已冻结停止。

## B1 主线程退回记录（02:55+08:00）

Terra首轮报告18通过，但Astra实际检查两份新增测试后发现：缺少报告所述的旧幂等payload兼容、batch lookup、别名派发、撤销后派单及保留SUPER_ADMIN的真实断言。现有同名撤销测试只断言USER；不能将文字报告当作验收证据。已要求补齐既定用例和实际OpenAPI导出，未放行B2。

Astra亲跑 `.venv/Scripts/python.exe -m pytest tests/business_api/support/test_support_service.py -q --tb=short`（PYTHONPATH=services/business-api），退出1：1通过、1失败/0.50秒。新增角色过滤后旧fixture没有角色种子，使原最少活跃分配测试失败；需修正fixture到真实角色并保留原分配/转接/关闭断言，另测角色撤销。日志 `artifacts/2026-09-13/admin-support-repair/backend-astra-review.log`。

浏览器检查旧HTML演示页发现候选模拟API缺失（getDepositRepairCandidates），已分配B2补齐；此FAIL属于演示数据而非真实接口，当前尚未把浏览器验收记PASS。

## B1 第二轮复审通过（03:00+08:00）

Astra已重新读取新增断言并实际运行admin相关、support全目录、人工充值预检/执行/API集成定向，52 passed / 53.01s，退出0，原始输出 `backend-astra-final.log`。不再复用首轮不足的覆盖声明。角色完整撤销、原队列分配/转接/关闭、别名金额字符串与单次账本记录、旧命令payload重放、新badge冲突、批量认证/边界/隐私均有实际断言。

全局ruff可用；Astra将8个变动文件当前源码与HEAD逐项比较：原API/admin-service共29项，当前28项，新增支持服务/迁移/测试无lint问题；support.py重复Complaint诊断文本仅来源行号变化。保留 `ruff-baseline-comparison.json`，其added字段这一项是行号变化而非新增缺陷。不声称全文件lint清零。

既存18份差异保持原样（`existing-diff-preservation.txt`）；后续还需在最终验证后再核对。后端冻结供B2和B3契约接线。

## 交付边界

当前未构建APK、未安装设备、未部署生产、未执行实际充值。Figma已退役，本次UI交付使用HTML demo与Flutter/HTML契约；最终页面与验证状态待批次完成后填写。

## 后续主审发现

- B2a首轮仅有表格行选择，不符合用户明确下拉选择要求；已要求增加搜索联动select，管理编辑回填已读源码确认。新增派发每次提交生成新幂等键会使未知结果重试失去幂等保护，已交Terra做同草稿稳定键及实际失败重试测试。未按其16项旧/新合计测试宣告通过。
- B3两个真实联系人页面测试已检查源码：无identityCache时30秒刷新移除徽章，以及替换API后迟到旧响应不显示徽章。RoomPage仍有late final旧gateway生命周期问题、ContactsPage旧联系人Future回调需保护，已交Terra修正。
- scripts/verify.ps1环境预检已完成并启动；实际输出日志verify-full.log。测试并不连接生产进行人工充值。

- B2第二次重写曾丢分页与移除异常捕获，Astra实际diff发现后要求恢复；当前分页/失败列表保留已恢复，仍复核资金同草稿稳定键。该批未被误记完成。
- B3真实MatrixHome入口测试揭露之前接线引用不存在的_RoomSnapshot.directPeerId，已要求保留真实peer快照字段；随后MockClient中文response默认latin1导致ArgumentError，测试需UTF8。日志文件名含green不代表通过，以正文退出码为准；RoomPage真实标题仍在修复测试夹具/生命周期。

## 最终验收（Astra亲审）

| 门禁 | 实际结果 | 证据 |
| --- | --- | --- |
| 客服/人工资金定向 | 后端52通过；后台36通过 | backend-astra-final.log、frontend-focused-astra.log |
| 全业务API/worker | 1862通过、52跳过、2个旧迁移head断言失败；962.95秒 | verify-full.log；不把该次失败记为全绿 |
| 修正后的迁移/发布/registry门禁 | 49通过，15.48秒，1条既有Alembic配置弃用警告 | gate-corrections-astra.log；保留历史merge和钱包检查，仅同步0065及29组件 |
| Flutter全量 | 2474通过、29失败，约101秒 | flutter-full-astra.log、flutter-failures.txt；29项均在既有钱包测试文件，客服新用例通过 |
| Flutter分析 | 无问题，25.3秒 | flutter-analyze-astra.log |
| HTML全量 | 184项：179通过、5已有失败，1.26秒 | frontend-final-astra.log；失败名称与本次前端初始运行一致 |
| Python移动边界 | 69通过、1个旧28组件计数失败；该计数已修正并在49项门禁中通过 | mobile-boundaries-astra.log、gate-corrections-astra.log |
| 仓库/部署/模板/infra/个推/MatrixBot | PASS；infra141、个推28、MatrixBot9通过 | verify-full.log；本次无个推业务修改 |
| 契约/导入/AST/Compose | OpenAPI通过；UI29组件363页面；API import通过；214个Python文件AST通过；Compose config退出0 | 主线程工具输出；离线迁移SQL见migrations-offline.sql |
| 工作区保护 | 18份既存diff逐段不变；git diff --check退出0 | existing-diff-preservation-final.json、diff-check.txt；source-sha256.json标识最终输入 |

全verify脚本在业务测试失败处退出，因此其后门禁单独执行。仅测试预期及release-head常量随后修正，复跑所有受影响门禁；按工作流证据复用规则保留不变源码的1862项结果，不重复整段16分钟测试，也不宣称执行过一次全绿verify。

### 浏览器与页面证据

- `frontend/tests/admin-support-preview.html`：实际默认SUPPORT_AGENT、SUPPORT_CAIBI_GRANT；编辑并保存“专属客服”后列表同步；客服select回填并合成派发12.34成功。原生confirm使CUA超时，删除成功的浏览器步骤未完成；取消/失败分支和真实服务删除由自动化覆盖。
- `frontend/tests/admin-completion-preview.html?verify=1`：浏览器自检PASS（筛选、弹窗焦点、预检不执行、二次确认、查询恢复无重放）。手动选充值候选、填写依据、预检、勾选确认、执行后关闭弹窗，父表显示“已入账”。所有数据仅内存模拟。
- `frontend/tests/support-identity-preview.html`：导入真实officialName helper；DOM computed style证实两条合法badge为rgb(246,195,67)、12px，昵称伪造文字没有badge节点；截图人工核对通过。
- Flutter覆盖联系人、资料页、私聊列表、私聊标题、群聊无标记；ContactsPage30秒撤销和ContactProfilePage旧API迟到返回有真实widget测试。RoomPage API更换的失效逻辑已读diff，但独立迟到回包页面测试未新增。

### 交付与下一步

客服角色/后缀只来自业务域；不更改Matrix昵称、E2EE、个推或金融计算。CAIBI Decimal两位、USDT六位及原资格、幂等、审计、Outbox和人工资金双阶段机制保留。新增0065仅扩展support_profiles，部署时需先应用迁移并交付配套API/后台，APP后缀需新客户端。

本次没有生产发布、APK/IPA打包、真机安装或真实资金写入。充值修复明确区分“预检不入账”与“确认补入账”，并修复成功后外层列表不刷新。由于未提供本次txid/预检错误码，不能认定实际生产交易阻断已解除；若预检仍有阻断，应依据原始链上证据及订单处理，不能跳过金额、地址、时间、归属、重复入账和资金限制检查。
