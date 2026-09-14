# 钱包回归与充值诊断证据

状态：本轮修复与自动化验收完成；未部署、打包、真机验证或实际加款。

## 最终验收（覆盖下方中间失败状态）

- Astra亲跑`flutter test --no-pub --reporter expanded`：2508通过/0失败/退出0；2026-09-13T04:37:23.6266597+08:00至04:40:17.1126368+08:00。日志`artifacts/2026-09-13/wallet-regression-repair/flutter-main-full-final.log`。
- `flutter analyze --no-pub`：No issues found，19.5秒，退出0；日志`flutter-main-analyze-final.log`。
- `npm test`：184通过/0失败，退出0；日志`frontend-main-full-green.log`。
- 最终`py -3.12 -m pytest tests/mobile -q`：70通过/143.59秒/退出0；日志`mobile-boundary-final.log`。UI契约29组件363页面、仓库/部署策略通过。
- 原29项钱包失败与5项前端失败已消除；本轮新增5项测试，未skip或删测试。钱包全目录单独64/64通过；两文件最终断言15/15通过。
- 最终全量已覆盖外部更新后的头像接口和账单布局，上轮15项失败不再复现。760个Dart输入在最终运行中保存hash并于结束核对；工具版本/依赖锁见toolchain.log，最终输入见input-sha256.json。

Astra按规格先审入口、门禁、中文提示与错误恢复，再审实际diff、API调用顺序、Base58Check、原幂等保留、计时器清理和原有客服token保留。两执行代理均以显式gpt-5.6-terra创建并复用；业务源码只由Terra修改，主线程独立验证。外部并发文件保留，未纳入本任务实现归属。纯测试修订的多次返工与首次并发失败日志保留，主动工作精确耗时未知，已知长命令区间如上。

## 已复核的前端回归

Terra红测：`node --test tests/manual-wallet-panel.test.mjs tests/moment-reactions.test.mjs tests/source-contract.test.mjs`，43通过/5失败。三项事故弹窗fixture缺document.body及dialog方法；一项own评论仍断言已替换的点击事件；一项图片编辑硬编码颜色违反token契约。修复fixture、保留生产长按/右键菜单，图片调色移入token并以不透明像素块实现马赛克；source-contract继续暴露的金额字号!important用更具体选择器替代。业务事故流程、资金启停和moments.js未修改。

主线程实际diff及调用链审查后独立执行`npm test`：184通过/0失败，1482.8464ms，退出0，日志`artifacts/2026-09-13/wallet-regression-repair/frontend-main-full-green.log`。Terra相同全量也通过。浏览器本地页面`http://127.0.0.1:4187/?screen=chat-image-editor-ready`可正常渲染原山景配色、白色画笔；马赛克控件选中状态与提示正确。未进行拖动绘制的像素级比较，不作为真机测试。

主线程`py -3.12 -m pytest tests/mobile -q`：70通过/88.63秒/退出0；`py -3.12 scripts/verify_ui_contract.py`：29组件363页面通过；RepositoryPolicy与DeploymentPolicy均通过。Flutter实际生产修复后的全量与analyze待完成。

## 移动端审查决定

29项失败首先由旧分段页面、旧官方地址按钮和不完整CAIBI/余额fixture触发。主审拒绝了未证明的“绑定刷新吞错”修复，要求迁移真实入口并保留金额、授权、原幂等和失效门禁断言。进一步暴露两类生产缺陷：确定性失效提现保留草稿；官方充值intent未验证TRON Base58Check且失败刷新可能保留旧地址。Terra获准仅在manual_wallet_page.dart/manual_wallet_api.dart修复客户端清理和官方地址解析，不改服务端资金策略。

主线程亲读服务端manual_payouts.request：成功recover在PIN校验之前返回；未提供payment_authorization的新请求先返回PAYMENT_PIN_REQUIRED，授权后的EXPIRED/CHANGED校验在账本写入之前。故初轮EXPIRED/CHANGED处理属于兼容防御，同时必须覆盖当前流程中PIN_REQUIRED后读取已过期quote的本地清理，不能把模拟错误码当作当前服务端必然路径。网络未知结果不得清理原key，成功重放不消耗新PIN。

主线程独立`flutter test --no-pub --reporter expanded test/features/wallet`：64/64通过，退出0，`flutter-main-wallet.log`。这覆盖全部钱包目录，原29失败均已消除。首次全量`flutter test --no-pub --reporter expanded`：2435通过/15失败，退出1，2026-09-13T04:33:01.7619535+08:00至04:35:16.6948071+08:00，`flutter-main-full.log`。14项测试加载/编译失败涉及并发改动的头像接口，1项ledger大金额320宽/双倍字体布局失败；不是原钱包失败。首次analyze有本批测试8项花括号lint，已交Terra整改，不能以格式化成功替代analyze。

## 工作区并发漂移与验收限制

本轮baseline.patch有54个差异段，51个逐段未变。除本任务tokens.css外，room_page.dart、GETUI SDK的fileHashes.lock发生额外变化；账单页、转账页、红包成员页及后端ledger接口/报表也出现本任务未修改的diff。首次全量开始时ChatRoomMember尚无businessAvatarUrl参数，测试期间该参数被补入源码；明确存在本任务外继续写入，未回退或覆盖。`change-scope.json`保留这些unexpected项，不能将其隐藏为本任务改动。已询问用户是否存在其他执行者。

当前backend输入也发生外部变化，因此不能把前轮verify.ps1的后端证据宣称为当前整个工作区全绿。本批没有重跑约16分钟的后端全量，也没有本任务服务端源码变更；只报告本次亲跑的前端/钱包/边界/契约门禁。并发任务冻结后需重新核对全量结果。Docker Linux daemon和独立认证PostgreSQL测试环境的既有缺失仍未解除；不导入生产秘密补测试环境。

## 两笔充值的当前生产事实

读取时间见production-binding-policy.jsonl。API镜像ca7178fa31c1，schema0064；SQL连接执行SET TRANSACTION READ ONLY。未读取/输出钱包完整地址、密钥、令牌或消息内容。

| txid / log | 金额 | 付款时间（北京时间） | 相对候选订单 | 当前状态 |
| --- | --- | --- | --- | --- |
| ab0ddd6a2723884b6ffe323ad4260aa1e25d61ecd398d5b20d35aee225a74c09 / 0 | 10.000000 USDT | 2026-09-10 16:46:51 | 早30.682362秒 | REVIEW / NO_UNIQUE_INTENT，待处理义务保留，无账本引用 |
| 16f1f166b7b0e776f6c5529777e2eff11c9b9223b0b4ae906758f578118acbe3 / 0 | 10.000000 USDT | 2026-09-10 16:36:54 | 早627.682362秒 | REVIEW / NO_UNIQUE_INTENT，待处理义务保留，无账本引用 |

同一候选订单534275b8-1c4b-4323-a3a5-b8cb38cc8ac7，金额10.000000，2026-09-10 16:47:21.682362创建，17:07:21.682362过期。另一个旧订单已因改绑关闭，付款时旧绑定也已失效。两笔付款均处于版本2绑定有效区块范围，不是当前绑定没生效。

第一笔最近预检：2026-09-13 02:30:47+08，reason=EXPIRED_INTENT_REVIEW、payment_attestation=false，唯一记录阻断TEMPORAL_EVIDENCE_REQUIRED；历史两次即使勾证明仍选过期订单原因，故未放行。符合证明时需选择PAYMENT_BEFORE_ORDER并勾选证明，重新预检后明确执行；实时证据/资金门禁仍需重新验证，不能承诺当前必定无其他阻断。数据库无execute命令记录。

第二笔没有预检/execute记录，超过已上线5分钟窗口。不能扩大窗口或把同一10USDT订单用于两次入账。需独立的人工归属与补录审批方案，保留原始订单/交易时间、财务幂等和审计；当前任务不直接修改生产资金状态。

生产repairs.py SHA256 c5d5f23fc4644713c87c75025b32f93c60f9cf8d87cc32bc9689025aed65deb7，实际读取确认5分钟限制和reason+attestation双条件，非只引用本地代码或历史报告。证据：artifacts/2026-09-13/wallet-regression-repair/production-receipts.jsonl、production-binding-policy.jsonl。
