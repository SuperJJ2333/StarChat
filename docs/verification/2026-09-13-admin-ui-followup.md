# 客服布局与补入账入口复核

状态：本地修复与HTML demo验收完成，待用户检查；这轮UI改动未发布到生产，未操作真实资金。生产仍为上一轮119e6971/schema0066。

## 根因与变更

客服管理/点钻派发直接把h2、label、input放入三列admin-command-form，标签与输入被分派到不同格。Astra在真实CSS栈下浏览器复现：h2/目标label/input同一行位于x25/492/958，后缀label与input跨行。旧demo只加载admin-modern，缺少gallery和admin-modern祖先，未暴露该问题。

修复为字段容器、独立标题/动作/反馈区，桌面成组排列，窄屏单列。样式仅作用于客服及指定补录表单，保留原全局布局与其他任务修改。Demo加载生产CSS栈，独立页不预留不存在的侧栏。

充值原成功分支已有execute；但预检前与阻断时不展示确认按钮，选单或阻断后人工补录入口消失，长证据又把操作区推至下方。现展示核对→预检→确认补入账步骤，预检前/阻断时按钮可见且禁用，并解释原因；人工补录入口保留。成功勾选后才能点击蓝色确认按钮调用原execute。人工case的审批/预检行动区提前，用户编号/畅聊号/金额/单号/审批依据常显，长证据可展开，最终账本编号保持可见。

未知执行结果时人工补录入口同步禁用且handler拒绝调用，只允许查询原操作；不通过新流程重放资金请求。后端审批、金额、归属、幂等、审计及开关没有修改。

## 主线程审查与实跑

Astra亲读四个runtime文件实际diff及调用链。显式gpt-5.6-terra执行support_layout、repair_entry，两人按文件独占，CSS修改由support_layout统一完成。

审查退回：恢复初稿折叠时误删的创建与审批依据；确认区保留稳定用户编号与金额；修复预检按钮被grid拉高；入账按钮主次与间距；阻止未知结果切人工流程。全部完成后复核。

| 检查 | 结果 |
| --- | --- |
| 新布局红测试（Terra） | 结构断言按预期失败，实施后定向7通过 |
| 新入口/相邻链上/manual案例（Terra最终） | 31通过，包含未知结果禁止切换 |
| Astra `npm test`（frontend最终） | 203通过/0失败/0跳过，1372.6072ms，退出0；astra-frontend-final-203.log |
| Astra UI契约 | PASS，29组件/363页面；registry/tokens未变 |
| Astra限定diff whitespace | 通过；仅Git行尾提示 |
| 浏览器客服390px | 三字段单列；scrollWidth=innerWidth=390，无页面横向溢出 |
| 浏览器派发390px | 四字段单列；合成选择客服并派发12.34，显示成功 |
| 浏览器普通补入账 | 预检后未勾选按钮disabled；勾选/显式确认→EXECUTED/ledger-demo-7，父列表反馈已入账 |
| 浏览器阻断场景 | AMOUNT_MISMATCH说明常显、确认禁用、人工入口可见 |
| 浏览器窗口外补录 | 创建→批准→预检→勾选→确认；创建/批准依据、执行人/时间可见，EXECUTED/ledger-window |
| 浏览器充值390px | pageScroll=390，dialogClient=dialogScroll=351，确认按钮top526.8/bottom570.8（844高视口内） |

截图由浏览器工具内联实际查看，未声称保存本地截图文件。所有演示交易为合成数据。先前202项通过日志保留，最终以203项为准。

本次只改后台JS/CSS/演示与测试；未修改Flutter、后端、迁移或生产配置。按变更影响与证据复用规则未重跑后端综合verify.ps1或Flutter全量；原[本地综合验证](2026-09-13-manual-deposit-cases.md)及[生产候选Linux80项](2026-09-13-manual-deposit-production.md)仅在其原覆盖范围成立，不宣称当前整个脏工作区全量通过。

## Demo与后续

- 整合检查页：http://127.0.0.1:4187/tests/admin-ui-review.html?tab=manage （客服管理、客服点钻派发、充值三页可切换）。
- 专项客服页：http://127.0.0.1:4187/tests/admin-support-preview.html 。
- 路径：frontend/tests/admin-ui-review.html、frontend/tests/admin-support-preview.html。真实后台组件复用，合成API，不连接生产。
- 已调用open_in_codex请求在右侧打开整合页，工具返回queued；仍可直接点击链接。
- 本机既有4187服务仍运行，执行者另起4173服务PID34868保留用于演示；不宣称已清理。
- Figma已退役：本次只更新HTML demo；后台专用布局不新增Flutter组件注册项。
- 最早精确开始时间未记录；13:00契约初检，13:08–13:10浏览器与末端保护复核，13:11最终测试/记录；等待用户视觉检查后再处理这轮UI发布。

[任务](../workflow/tasks/2026-09-13-admin-ui-followup.md) · [计划](../superpowers/plans/2026-09-13-admin-ui-followup.md)。输入hash与净diff在artifacts/2026-09-13/admin-ui-followup/。
