# 2026-09-11 钱包绑定与点钻提现

## 需求与根因

用户确认提现规则：1 点钻 = 1 USDT、零手续费、最低 10 USDT。

- 原 WalletPage 为旧资产仪表板，ManualWalletPage 另起“TRON 钱包”，入口和标题不一致。
- 原充提是分段控件，切换未检查绑定；仅后续按钮局部门禁，未形成入口禁用状态。
- 原提现输入/冻结 USDT，无点钻余额填充，也无用户支付密码授权。现有 MFA 是另一验证机制，不能替代支付密码。

## 实施范围

Flutter 钱包入口与独立充值/提现/绑定页、同一支付密码组件；服务端不可变来源报价、PIN 用途授权、兑换与冻结同事务、取消关联逆向分录；HTML 演示与接口契约同步。具体差异以本次提交及 task 记录为准。

## 复现及真机回归台账（真机交互未执行）

用户此前要求只推送 debug 到 Mi 6，无需自行测试；本次不做真机交互测试。因新增跨资产金融事务且线上资金能力已开放，已向用户说明并完成必要隔离财务验证，不操作真实资金。本表仅记录待用户确认的真机场景，不把源码审阅、编译、安装冒充交互或真实资金验收。

| 场景 | 原表现/验证动作 | 预期 | 实测 |
|---|---|---|---|
| 未绑定 | 打开钱包，点充值/提现 | 标题钱包；两按钮灰色；不跳转不请求 | 待用户 |
| 绑定中 | 绑定pending，重进钱包 | 充提仍禁用 | 待用户 |
| 绑定激活 | 完成绑定后返回钱包 | 卡内更改图标；充提进入独立页面 | 待用户 |
| 实时余额 | 提现页刷新/后台返回 | 当前点钻余额：服务端数值 | 待用户 |
| 全部提现 | 点击全部提现 | 完整点钻可用余额填入，精度两位 | 待用户 |
| 最低金额 | 9.99/10点钻 | 前者拒绝，后者可报价，1:1零费 | 待用户 |
| 密码取消 | PIN页取消或后台关闭 | 不生成兑换/冻结 | 待用户 |
| 错误密码 | 输入错误六位PIN | 与红包转账相同提示/锁定规则 | 待用户 |
| 重试/弱网 | 提交结果未知再重试、重进 | 原幂等订单，无重复扣款 | 待用户 |
| 多端/切账号 | PIN期间重新登录或切账号 | 拒绝旧会话迟到提交 | 待用户 |
| 取消订单 | 取消尚未提交的点钻提现 | 原点钻退回，复式分录追加不删改 | 待用户 |
| 已付款未知 | UNKNOWN/已付款点取消 | 不释放占用或错误重付 | 待用户 |
| 既有红包/转账 | 原入口发红包和转账 | 业务规则保持 | 待用户 |

## 构建与安装

- Flutter 3.44.9 / Dart 3.12.2 / JDK 17.0.20，standard debug ARM64，三项 HTTPS define 指向 liuhetong888.com；build exit 0，Gradle 21.6 秒。
- 版本 `0.3.83-debug/2087`，包名 `com.liuhetong.mobile.debug`；Apktool 2.12.1 解包/重建，build-tools 36 对齐及既有 debug 签名。
- SHA256 `9446b3131d01066a8e379508e4532aae9b75699f2b3de144f100367e441061de`；143442219 字节；27,242 类及 339 原生库/资产条目语义/字节一致，清单语义一致；新增钱包 helper 和全额提现代码存在于 kernel，非旧 APK 换版本号。
- 证书 SHA256 `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`，同独立 debug 渠道，没有使用正式证书或卸载命令。
- `adb -s cbd0156b install -r ...` exit 0 / Success；Mi 6 实际版本 2087、lastUpdateTime 2026-09-11 00:32:13+08；设备 base.apk SHA 与交付一致。firstInstallTime 实测为本日00:30:14，与前任务历史值不同，不推断原因、不声称证明数据保留；本次未清数据或卸载。
- APK：[下载本地构建](artifacts/2026-09-11/wallet-binding-payment/ChatFlow-0.3.83-debug-2087-mi6.apk)。

## 隔离财务与静态验证

- 核心 SQLite 130 pass（13.68s）、API兼容24 pass、独立 PostgreSQL5 pass（40.83s）；共159项。PG为新建tmpfs实例，无生产库连接；随机schema已清理、临时容器与SSH隧道已关闭。
- 覆盖PIN强制/完整意图/错误授权/回滚、1:1零费最低额、CAIBI整分、未知结果恢复、同key并发仅一次扣款、并发取消仅一次退回、双资产复式平衡、原USDT兼容。具体5个PG案例以日志及测试源码为准，不扩大声称跨红包/提现并发已验证。
- 定向 Dart analyze 无问题；HTML 三个 JS node --check通过；OpenAPI export/check、Python AST、git diff --check均通过。
- 首次expiry测试暴露PIN过期优先于quote过期，修正验证顺序后通过；旧API测试缺新必需PIN，更新真实authorize fixture后20通过。首次本机venv缺coincurve，换已有Python3.12环境，无应用依赖变更。详见 [后端证据](artifacts/2026-09-11/wallet-binding-payment/backend-evidence.json)。
- 不运行真机交互和真实资金验收。全量verify.ps1预检发现本机Docker daemon未启动，未运行全仓长门禁；以相关隔离专项为本次证据，不能称全仓通过。
- 已有工具警告：本机Starlette/httpx弃用1条；Flutter插件KGP未来迁移提示；Docker legacy builder弃用。当前编译/专项通过，无关依赖未升级。

## 服务端发布

- 领域审查（media）及后续质量/安全审查（profile）通过；MFA恢复探测先消耗验证码问题修复并回归通过。
- 线上9个覆盖文件与694ce039基线逐个hash相同；仅覆盖9文件+新增conversions.py，不覆盖其他任务的源码。基于原镜像 `sha256:44057e8cd2c244ff4fae68bee2ced2de93f386337c09704f3775542000f77f15` 构建最小候选。
- 新镜像 `sha256:fbcc95afd79dfde355cbd463e01cb3dd1bac01fc435c91a289c0b0cc09319ee5`，2026-09-11 00:30+08 生效。10文件SHA均吻合；只有business-api容器更换，其他服务不变；没有修改资金开关和schema。
- 服务器备份 `/opt/starchat/releases/wallet-points-pin-20260911/business-before.dump`，0700目录/0600文件，仅留服务器；3473129字节，SHA `3f6deb83324c01eecff5f749089cf4240ce5ac82acda2d7a7a635d792a28a02c`。隔离恢复成功，alembic head仍0064_admin_deposit_repairs，恢复库已删除。
- 无网络候选imports通过；Compose healthy；服务端及工作站HTTPS `/api/v1/health/ready`200 JSON，未登录新报价读取401 AUTH_REQUIRED；启动错误0。首次健康检查误用不带/api/v1路径返回非JSON，纠正路径后通过。
- 回退：服务器执行 `python3 /opt/starchat/releases/wallet-points-pin-20260911/deploy_wallet.py rollback`，保留资金交易/订单和审计；配置备份含敏感值仅服务器0600保存，不提交。
- 兼容边界：旧客户端无PIN不得新建提现，已受理原key可恢复；新debug已同步密码交互。既有红包/转账与钱包User/reserve锁反序为基线风险，本次未扩大到修改这两个业务，未宣称该跨业务并发风险已修复。

## 改动文件

Flutter：wallet_page.dart、manual_wallet_page.dart、manual_wallet_api.dart、manual_operation_store.dart、新wallet_payment_flow.dart。
服务端：api/manual_wallet.py、api/payment_pin.py、api/wallet.py；identity/payment_pin.py；ledger/service.py；wallet/manual_payouts.py、runtime.py、safety.py、service.py、新conversions.py。
配套：OpenAPI、HTML wallet-binding.js/finance.js/catalog/screens.js/primitives.css、UI registry、相关PIN/提现回归用例、ADR0068及计划/任务记录。


## 最终历史报价兼容补丁

集成复查发现：历史USDT报价快照没有funding_amount，新响应模型会输出null，导致新客户端读取旧报价失败。API QuoteView仅在USDT缺字段/为null时按原amount投影，CAIBI缺来源金额明确拒绝；原快照、摘要、幂等记录不修改。4项red均因预期缺失行为失败，修复后原20+新4共24pass；相关金额/交易源码未改，无需重复已通过PG事务门禁。

最终镜像 `sha256:fea5b9417e5c2316ea711fccb09981fb058b3ea13546a6c54e8c9524ddef4152`，在fbcc95af上仅覆盖api/manual_wallet.py；独立记录目录为服务器同发布目录下quote-compat。最终合计159项隔离用例通过。APK源码没有变化，仍是已安装2087，不重新打包未变化客户端。首次发布备份及全回退配置保留，子目录rollback仅回退投影补丁。
