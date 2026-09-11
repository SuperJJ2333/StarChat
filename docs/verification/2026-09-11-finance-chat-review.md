# 红包、转账与点钻账单：实现与验收记录

2026-09-11；工作树 `.worktrees/performance-20260911`；基线 `a07c996a`，变更未提交。Astra（gpt-6-astra）规划、检查实际 diff、调用链及日志，显式 gpt-5.6-terra 实施和自测；最多同时两名执行者，同文件和 Flutter 运行槽串行。模型证据和历次退回原因见[任务记录](../workflow/tasks/2026-09-11-finance-chat.md)。

**本次功能已接入真实聊天入口，定向自动化通过；全仓门禁存在下述既有失败，不能称全量通过。** 未发布、安装或执行生产操作。真机、多端实网及微信视觉对照仍待用户验收。

## 复现、根因、修改与验收

| ID | 原问题与复现 | 根因与修改 | 本地验证结果 |
| --- | --- | --- | --- |
| FC01 | A 领红包后重进会话卡片仍未领；B 未领可能因终态被当已领 | RoomPage 硬编码 available；弹窗混淆本人领取与全局终态。业务详情新增 viewer_claim；本人记录优先，其他用户显示已领完/已过期 | 本人/非本人/终态矩阵通过；真实领取 POST 后原卡变已领取，再次点直达领取详情且不重复 POST |
| FC02 | 收款方收款后卡片仍待收或写对方已收款 | 原卡硬编码 pending，accepted 未分身份。读取业务状态，收款方显示转账已收款，发送方显示对方已收款 | 角色测试、真实 accept POST→返回原卡、再次进入收款页通过；显示说明、金额、转账及收款时间 |
| FC03 | 未领完或普通红包详情也标最佳 | 原排序无群/模式/终态约束。仅群 RANDOM 且完成或可信服务端时间到期展示；整数分比较，平手稳定 | 普通/专属/私聊/进行中不展示；群随机终态、到期边界、大金额及平手通过 |
| FC04 | 群人数不足仍能发送更多份红包 | 创建无人数上限，专属候选又不含本人。独立 joined 总数、发送前刷新去重，必须含真实发送者；服务端单次权威快照最终校验 | 相等允许、超员阻止、成员增减、权威失败、双击/离页、专属/私聊回归通过；非成员/超员无财务写入；合法幂等重放保留 |
| FC05 | 已收款后缺收款详情与账单入口 | 原 popup 无完整投影。新增收款页、本人账单详情与真实账本事务 ID；退款后发送方仍关联原付款，收款方关联实际入账 | API 路由、ID 复制成功/失败、金额与手续费区分、无 bill_id 不伪造入口、他人 ID 404、非 CAIBI 拒绝通过 |
| FC06 | 缺全部点钻流水及筛选搜索 | 新增本人 CAIBI 分录汇总只读接口与列表；类型/时间/关键词组合，created_at/id 稳定游标；充值/提现/红包/转账/其他及退款映射 | 账号/资产隔离、特殊字符、中文关键词、时区分页、去重、结束日期二次确定不漂移、加载/空/错误/重试通过 |
| FC07 | 操作后整页刷新，异步结果可能跨账号回填 | FinanceCardStore 独立可见 lease、4 并发、同 key 合并、可见非终态 15 秒补读、200 个闲置条目 LRU；局部失效替代 timeline.refresh | 双击单路由、卡片复用、注销/同 epoch 失效、销毁迟到响应、旧读取不能覆盖新写入、分页旧结果隔离通过 |
| FC08 | Flutter 与 HTML 视觉记录不一致 | 同步状态卡、收款/账单示例、群人数提示、status-label、浅深色令牌与注册表 | 7 项 Node 定向、3 浏览器场景、26 组件/355 页面契约、3 项登记测试通过；320px/两倍字体页面测试通过 |

## 关键文件与调用链

- 聊天：`apps/mobile_flutter/lib/features/matrix/room_page.dart` → `features/finance/finance_message_entry.dart` → `finance_message_card.dart` / `finance_card_store.dart`。先取业务状态再导航，写成功及返回只失效当前 key。
- 红包：`features/redpacket/red_packet_controller.dart`、`red_packet_claim_dialog.dart`、`red_packet_claim_detail_page.dart`；发送：`features/matrix/chat_red_packet_controller.dart`、`chat_red_packet_sheet.dart`。
- 转账：`features/transfer/chat_transfer_detail_controller.dart`、`chat_transfer_detail_sheet.dart`。写成功后补读失败仍保留成功状态，提供详情重试，不能恢复待收款按钮。
- 账单：`features/ledger/ledger_{gateway,business_gateway,controller,pages}.dart`、`core/business_api_client.dart`。搜索防抖 300ms，结束日转下一日本地零点再转 UTC，详情/列表检查账号生命周期。
- 服务端：`services/business-api/app/modules/redpacket/{membership,service}.py`、`modules/ledger/statements.py`、`modules/transfer/{service,projections}.py`、`app/api/{redpacket,ledger,transfer}.py`；OpenAPI 同步 `packages/api-contracts/openapi/liuhetong-v1.yaml`。
- HTML：`frontend/src/{screens,components}/finance.js`、相关 catalog/styles/tests；`packages/ui-contracts/changliao-component-registry.json`。

## 验证命令与证据

日志根目录：[finance-chat artifacts](artifacts/2026-09-11/finance-chat/)。分批用例有重叠，不相加成唯一用例数。当前工作树，PowerShell 7/UTF-8，Python 3.12，Flutter 3.44.9 / Dart 3.12.2。

| 门禁 | 实际结果 | 日志（相对根目录） |
| --- | --- | --- |
| 最终入口/详情/账单/群人数组合 flutter test --no-pub | 94 passed，退出 0；6 文件 analyze 无问题 | `b3b3-entry/b3b3-combined-final-gate.log`、`b3b3-combined-final-analyze.log` |
| 红包目录 / 转账组合 / 群人数 / 账单补验 | 分别 30 / 21 / 22 / 12 passed，各 scoped analyze 无问题 | `b3b2/terra-redpacket-final.log`；`b3b2-transfer/b3b2-receipt-final-gate.log`、`b3b2-ledger-followup-final-gate.log`；`fc04/terra-fc04-dispose-green.log` |
| Astra 完整 flutter test --no-pub --reporter expanded | 2310 passed / 29 failed，退出 1 | `gates/flutter-full-final.log` |
| Astra 完整 flutter analyze --no-pub | No issues，退出 0 | `gates/flutter-analyze-final.log` |
| 业务 API/worker 全量 pytest | 1829 passed / 11 failed / 52 skipped / 2 warnings，退出 1 | `gates/backend-full.log` |
| PIN 群成员夹具修正后完整测试文件 | 8 passed，未弱化生产 PIN | `b1/payment-pin-fixture.log` |
| B1/B2 定向及隔离 PostgreSQL | B1 45 passed / 初始 7 skipped，随后实际 PG 7 passed；B2 27 项及后续修正定向通过 | `b2/` 及任务分批记录 |
| py -3.12 scripts/export_openapi.py --check | 退出 0 | `gates/openapi-check.log` |
| Node 定向 / 浏览器 | 7 passed / 3 PASS | `b4b-final/terra-b4b-finance-node-final.log`、`terra-b4b-browser-green.log` |
| npm test | 143 passed / 11 failed | `b4b-final/terra-b4b-npm-full.log` |
| verify_ui_contract.py / registry pytest | PASS 26/355 / 3 passed | `b4b-final/terra-b4b-ui-contract-final.log`、`terra-b4b-ui-registry-pytest-final.log` |
| Astra py -3.12 -m pytest tests/mobile -q | 69 passed / 1 failed，退出 1 | `gates/mobile-policy-final.log` |
| Repository / Deployment policy PowerShell | 两项退出 0 | `gates/repository-policy-final.log`、`gates/deployment-policy-final.log` |

B1 红基线为后置基线重放；部分入口首轮失败含缺文件/夹具错误，不冒充全部修改均有严格行为红绿顺序。独立行为回归和最终组合证据如上。

## 全仓失败与环境限制

- Flutter 29 个失败集中在既有 manual wallet/recovery/capabilities/compact/official deposit。逐项基线核对见 `gates/flutter-baseline-comparison.md`；仍未通过，不以定向结果替代。
- 后端 11 个失败中的新增 2 个是 PIN 测试缺群成员夹具，已修正且完整文件通过；其余 9 个与前任务钱包后台/恢复/撤销会话基线名称及断言相同。未改对应生产钱包安全路径，未重复无变化的 770 秒全量门禁。
- npm 11 个既有失败：admin-chain 6、manual-wallet 3、朋友圈评论 1、图片编辑颜色契约 1。本次令牌白名单新增失败已修，保留原断言。
- Python mobile 1 个搜索入口正则失败：嵌套 ContactActions 右括号提前结束匹配。相关源码/测试未由本任务修改，基线复核单独记录。
- verify.ps1 预检缺 `.env`、`data/synapse/homeserver.yaml`，未运行生成配置及整套包装门禁，未读取生产秘密补环境；适用独立门禁如上。
- 浏览器场景通过，但 Chrome 有 Windows 长路径 profile 缓存警告，日志保留。iOS 编译、真机、实际多账号同时操作/杀进程/弱网未执行。

## 业务边界与微信差异

金额取业务 API，点钻两位精度，USDT 六位精度且与点钻账单隔离；Matrix 只承载业务引用。保留 E2EE、个推、支付密码、幂等、账本平衡、审计/Outbox、原分配及手续费逻辑；无 schema 迁移或财务公式变更。

复用现有微信风格组件，资产名、手续费和安全规则仍按畅聊业务。HTML 为可操作夹具，不连接真实资金。缺当前微信版本/截图，不承诺像素、动效、手势完全一致。多端状态靠业务读取和可见非终态轮询收敛，未新增金融推送事件，实网延迟待设备验收。

新只读 API 与客户端需在用户授权的后续发布中一起部署才能在服务器环境使用，本次未部署。保留原有 video_playback_arbiter.dart 格式及 Getui 生成文件，不算本次功能修改。

## Android 源码编译与证据身份

Astra 在最终 Flutter 全量测试与 analyze 后执行 `flutter pub get --offline`（退出0，锁文件仍仅 fake_async 从传递依赖改为直接 dev 依赖），随后执行：

```text
flutter build apk --debug --flavor standard --target-platform android-arm64 --no-pub
  --dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com
  --dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com
  --dart-define=LIUHETONG_GETUI_URL=https://liuhetong888.com
```

源码编译退出0（Gradle 73.5s），见 `gates/android-source-compile.log`。存在插件 Kotlin Gradle Plugin 未来兼容性警告，未升级依赖。三个地址为编译配置，未作生产连通性测试。

产物 `apps/mobile_flutter/build/app/outputs/flutter-apk/app-standard-debug.apk` 仅为本地编译中间件，版本未递增（0.3.81+2085），**未做最终 Apktool/固定签名重建流程，不能用于交付或覆盖安装**。未生成本任务交付包或安装 Mi6。前任务2086/2087不含本次功能。源码/测试/契约SHA清单及中间APK身份见 `gates/final-input-manifest.json`。

## 最后审查补项

Astra从截图发现HTML账单复制控件缺icon，退回Terra；两个详情入口统一复用已登记copy图标，真实DOM缺图标红测后Node4/4、浏览器3/3通过，源码与反馈逻辑亲审。证据 `b4b-final/icon-followup/terra-b4b-icon-{red,node,browser-green}.log`；全npm143/11为此次小改前的全量结果，按影响范围仅补跑金融定向，未冒称重跑全量。

Astra已阅读29项Flutter基线比对及git show原始搜索正则重现脚本/结果：新增Flutter失败0；Python mobile单失败为基线解析限制。本任务本地HTML服务器已停止，隔离PostgreSQL先前已按任务data目录停止；均未触碰生产服务。

最终复制图标触控补验：实际DOM验证高度≥44px；复用已登记spacing/color/pressed令牌，无默认灰条，焦点/按压反馈明确。Astra亲看最终截图并检查CSS；`b4b-final/icon-followup/terra-b4b-touch-browser-green.log`三个场景PASS。Astra随后亲跑最终金融/令牌/组件Node组合7通过（退出0，`gates/frontend-focused-final.log`），UI契约26/355通过（退出0，`gates/ui-contract-final.log`）。所有源代码已冻结。
