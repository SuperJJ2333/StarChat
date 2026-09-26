> 最新状态：用户已确认真实短信验收完成，下文 RAM 403 是历史阻断，不再要求重复授权或发送。真实供应商校验不等于 Flutter 登录/换绑端到端验收；五次尝试持久计数另有本轮离线集成证据。

# 验证记录：第三轮复审后批次（阿里云真实通道接入 + 后台工作台补全）

任务：[2026-09-22-zcode-after-third-review](../workflow/prompts/2026-09-22-zcode-after-third-review.md)。
前置：第三轮复审回填后主工作区。授权边界：本地实现 + 隔离测试；未部署、未开启生产开关、未处理真实资金。

## 一、阿里云真实通道（用户本轮提供凭据与测试号 13727744565）

| 步骤 | 结果 | 证据 |
| --- | --- | --- |
| SDK 安装（钉版 2.0.0）+ pip check | 通过 | 本会话执行记录 |
| .env 凭据接入（`BUSINESS_SMS_ALIYUN_*` 映射自 `ACCESS_KEY`/`ACCESS_KEY_SECRET`，签名 恒创联众、模板 100001、region ap-southeast-1、5 分钟） | 已写入本地 .env（不入库） | .env 行 77-78 为源凭据 |
| 连通性 | 区域 endpoint（ap-southeast-1/cn-hangzhou）TLS 被工作站网络重置；**中央 endpoint `dypnsapi.aliyuncs.com` 可达**（适配器复审版即用中央 endpoint） | 本会话探测输出 |
| 真实 SendSmsVerifyCode（RAM 授权后重试） | **成功**——真实短信下发到测试号 13727744565（challenge 3d45c443…、93608b7e…；用户已确认可收到） | 本会话执行输出 |
| 真实 CheckSmsVerifyCode 错码 | **权威判定工作正常**：返回 `isv.ValidateFail(400,验证失败)` → 适配器判 False 并计入尝试 | 本会话执行输出 |
| 契约缺陷修复 | 阿里云错码不返回 200+FAIL 而是 isv.ValidateFail 异常——原适配器误判为不可用不计尝试，会绕过五次上限；已修正为权威不匹配（False）。新增回归 2 项，适配器套件 **16 passed** | test_aliyun_sms_adapter.py |
| 适配器错误分类修正 | 供应商业务拒绝（Forbidden/NoPermission/403 文本）归类 `SMS_SEND_REJECTED`，与网络 `SMS_PROVIDER_TIMEOUT` 区分——运维信号可区分；消息不含凭据/完整号码 | 回归 2 项新增，`test_aliyun_sms_adapter.py` **14 passed**（后增至 16） |
| 正确码校验（用户读短信回传） | **未完成——被 403 阻断**；授权后重跑同一脚本即可 | — |

**待用户操作**：阿里云控制台 → RAM → 为子账号 `203052490004430027` 授权 `dypns:SendSmsVerifyCode` 与 `dypns:CheckSmsVerifyCode`（或 AliyunDypnsFullAccess）。授权后通知本会话即重发验证。

## 二、后台工作台补全

- 新端点接入真实 AdminApi：`listTransferIntents`/`reviewTransferIntent`（真实路由，非假客户端方法）。
- 面板新增：**案件审计时间线**（按案件 ID 查询，服务端 403/404 如实展示）；**群主转让意图**（按房间查询，NEEDS_REVIEW/MATRIX_PENDING 显示「确认已应用/确证未应用」按钮，复核回执展示 stage/last_error_code，被拒不误报成功）。
- `frontend` 全量与 `admin-recharge-panel` 套件：见文末追记。

## 三、门禁

| 检查 | 结果 |
| --- | --- |
| `pytest tests/business_api/identity/test_aliyun_sms_adapter.py` | 14 passed |
| 受影响专项（identity+recharge+groups） | 438 passed / 10 skipped |
| frontend `npm test` | **235 passed / 0 failed** |
| 后端全量 + `scripts/verify.ps1` | **verify 退出码 0（`Verification: PASS`）**，后端段实测见文末追记（`verify-final.log`/`verify-final-exit.txt`） |

## 四、未完成 / 未验证（不可省略）

- **真实短信下发的正向验收未完成**（RAM 403 阻断）；错码校验、正确码校验、OutId 回传均待授权后重测。
- 转让协调端点与 worker 仍默认关闭（`group_transfer_coordination_enabled=false`）；关闭期所有转让复核写入均返回 503，包括已有意图；查询仍可用。
- Flutter 批次 3：**未动工**（契约入口见 2026-09-22 证据第五节）。
- 生产备份副本演练 0079–0081、500 人压测、双端真机：未执行。


## 五、最终门禁追记（2026-09-23）

`scripts/verify.ps1` **退出码 0**（`verify-final-exit.txt`=`exit=0`，完整日志 `verify-final.log`）：仓库/部署策略、模板、Infra、Getui、Matrix Bot、business_api+worker 全量、mobile、Business API import、AST、Alembic 离线迁移（含 0081）、OpenAPI、Compose 全部 PASS。本轮新增/修改（适配器 403 分类、时间线/转让意图 UI、panel node 测试）已包含在该全量内。58 个 skip 项与 Flutter/真机/真实短信正向验收仍未验证，不因门禁数量视为通过。


## 六、真实通道验收追记（2026-09-23，RAM 授权后）

用户完成 RAM 授权后实测：
1. **SendSmsVerifyCode 发送成功**——验证码真实下发到测试号（用户侧可见短信）。
2. **CheckSmsVerifyCode 错码校验**——返回 isv.ValidateFail(400)，适配器判 False 并计入尝试。
3. **真实契约缺陷修复**：错码不是 200+FAIL 而是异常抛出——原分类会绕过五次尝试上限（认证安全隐患）；已改为权威不匹配判定，回归 2 项新增（适配器 16 passed）。
4. **正确码正向校验通过（用户回传真实收到的码）**：
   - [第二条验证码已脱敏] vs 最新 challenge → **True**（VerifyResult=PASS 且 OutId 与 challenge 对应）；
   - [第一条验证码已脱敏] vs 最新 challenge → False（码与 challenge 不对应——**challenge 隔离生效**）；
   - [第一条验证码已脱敏] vs 第一条 challenge → False（超 5 分钟有效期——**过期判定生效**）。
5. **阿里云验证码短信真实通道验收：完成**。发送、错码拒绝、正确码通过及 challenge/有效期相关检查有供应商调用记录；五次尝试本地持久计数与第六次阻断以离线 PhoneOtpService + 真实适配器集成为证，不将其称作真实通道全流程验收。
6. 登录/换绑全链路的端到端真机验收依赖 Flutter 批次 3（未动工，待用户审批）。


## 七、正向校验追记（2026-09-23）

用户回传两条真实短信码（[第一条验证码已脱敏]=第一条、[第二条验证码已脱敏]=第二条）。实测：正确码+对应 challenge → PASS；错配 challenge → False；过期 challenge → False。三例全部符合预期，真实通道验收矩阵闭合。本会话未再改动业务代码，未部署，未开启生产开关。


## 八、HTML 设计演示（UI 批次：7 页面 17 屏，2026-09-23）

新增 `frontend/src/screens/phone-flows.js` 渲染器并登记 17 屏（registry expectedCount 375→398，`verify_ui_contract.py` PASS：32 components / 398 screens）：

| 页面 | 屏（module-page-state） | 服务端权威口径体现 |
| --- | --- | --- |
| 登录页手机登录入口 | phone-login-phone-{default, otp-sent, cooldown, error} | 冷却 54s 文案、剩余尝试次数、不显示未发送 |
| 注册页手机/邮箱选择 | phone-registration-phone-{default, otp, matrix-wait, error} | 二选一、等待 Matrix 开通、无 email 占位 |
| 两步换绑页 | phone-rebind-{old, new, success} | 先验当前凭证、再验新号、完成才显示生效 |
| 客服目录/充值申请 | recharge-directory-directory | 目录仅启用客服；提交=待处理订单不入账；凭证防重 |
| 充值历史/待核对 | recharge-history-history、recharge-pending-review-pending-review | SUBMITTED≠已到账；UNKNOWN 继续占用绑定 |
| 钱包汇率与应付展示 | fx-fx-{fresh, stale} | 过期参考标注、客服结算率快照、10 USDT 门槛按 USDT |
| 红包抽成展示 | commission-commission-{pending, settled, fee-exempt} | 0.5%/0.1%、免手续费无抽成、FORFEITED 口径 |
| 转让阶段显示 | transfer-transfer-{pending, review, completed, unavailable} | 非 COMPLETED 不显示换主；默认未启入口径 |

复用既有 `pageRoot/navigation/component/app-action-button` 组件与设计 token；未新增分割线实现（遵守 §19）。Flutter 页面接入（消费同契约）与真机验收为下一批；本批为 HTML 设计演示，未改任何业务代码与后端。


## 九、浏览器实测与访问方式（2026-09-23）

- 本地静态服务器：`cd frontend && python -m http.server 8080`（后台常驻）。**图库入口：http://127.0.0.1:8080/index.html**（注意：直接双击 file:// 打开会因 ES Module CORS 白屏——必须走 HTTP）。
- 真实浏览器（Playwright + Edge）逐屏实测：本轮新增 23 屏全部渲染 OK（无渲染失败卡片）；截图存 `artifacts/2026-09-22/phone-flows/`（login-phone-default、fx-fx-fresh、transfer-transfer-review 等）。
- 既有问题记录（非本批引入）：13 条 `app-action-button rejects attributes: hidden` 控制台报错来自既有 `finance.js:265` redpacket 屏（对组件设 .hidden 属性，契约白名单拒绝）；图库仍完整渲染全部卡片。可作后续小修。


## 十、UI 批次设计修订（按用户 4 点反馈，2026-09-23 第二轮）

1. **登录页**：获取验证码按钮移至手机号输入框**右侧**（otp-row flex）；点击后 60 秒倒计时（按钮逐秒显示“N 秒后重发”，结束才可再取）；15 分钟内第 3 次请求后按钮禁用并提示“该 IP 已被禁止获取验证码”（演示口径，与服务端 10 分钟≤3 条限频一致）；提示文字改**小号字+灰底方框**（`c-phone-flows__hint`：surface 底+caption 字号+内边距）；左上角品牌标改用 **APP 图标**（/assets/branding/LOGO.png）。
2. **充值/汇率页**：卡片复用现行充值页钱包卡片式样（surfaceElevated 白卡+divider 边框，**无绿色背景**），目录/申请/历史/待核对/汇率/应付均用统一 `c-phone-flows__card`。
3. **红包抽成页**：复用现行红包卡片组件（`app-red-packet-card`，warning 橙色红包视觉）+ 钱包式信息卡展示 0.5%/0.1% 分行。
4. **转让页**：钱包卡片式（无绿色背景），四阶段进度 + 权威群主卡 + 状态说明卡。

浏览器实测（Playwright + Edge）：新增 23 屏全部渲染 OK；登录页倒计时/60s 文案/提示盒样式/LOGO 加载均断言通过。截图：`artifacts/2026-09-22/phone-flows/`。上述 UI 交互为设计演示；未改任何业务代码，未部署。


## 十一、生产连通性事件核查与判断更正（2026-09-23）

用户报告全体用户网络不可用，点击重试。核查过程与结论：

**实测事实**：
- 服务器与全部容器正常（business-api/worker healthy，8082 health 200；Caddy 公网 80/443 监听；ufw 规则完好）。
- 域名 A 记录（权威 NS ns59/ns60.domaincontrol.com 直查）= **28.0.0.44**，非源站 207.56.8.8。
- **28.0.0.44 是一个在线的透明转发前置**：对 443 做 TLS 终结/转发，证书为域名有效 LE 证书（2026-08-27 签发），响应头与源站 207.56.8.8 逐字节一致（nginx/1.27.5 + Via Caddy）——是同一站点的正常服务，不是劫持。
- 事件期间本工作区 vantage 对该域名 HTTPS 连接失败（000），但对源站 IP 直连一直通畅。

**判断更正（撤回此前口径）**：我此前据解析到非源站 IP + 本 vantage 连不上判定 DNS 被改/劫持——**该判断错误**，错在未直接对 28.0.0.44 做带 SNI 的实测就把保留段 IP 当作不可达。28.0.0.44 实为可用的前置转发入口。

**仍待用户确认/关注**：
1. 28.0.0.44 是否为你自建/租用的端口转发或隧道前置？事件时段（约 09-23 凌晨）该前置是否存在短暂中断？
2. business-api / worker 容器在事件前后各有一次重启记录（`Up About an hour`），若与事件时间吻合建议查 `docker logs` 与重启原因。
3. 服务器上遗留无端口发布的 postgres 容器 `phone-wallet-restore-20260923`（复审演练容器？），请确认是否清理。
4. 事件根因（前置中断 vs 源站重启窗口 vs 运营商路径）无日志可回溯，若再发生请第一时间保留客户端报错时间与服务器侧 `docker ps`/Caddy 日志。

## 十二、iOS 0.4.6（2165）候选 IPA 交付（待企业签名）

- 源头：CI ios-0353.yml run 35878445787 @ 12ded275（push 触发，2026-09-23T15:01Z，**success**）。该提交已包含手机号客户端契约层（business_phone_contracts.dart / phone_login_controller.dart 均在位，已核实）。
- 下载：GitHub Actions artifact `ChatFlow-iOS-signed`（60,326,094 字节），因直连 GitHub 仅 ~20KB/s，改走本地 socks5 代理 + 6 线程分段并行（661 秒完成）。zip SHA256 `f10e4b509065ee082f9cf128444ce5e157d796193ee87b4c2de2c4dbc7648ded`。
- **交付物（待企业重签）**：`docs/verification/artifacts/2026-09-22/phone-flows/ChatFlow-0.4.6-2165-unsigned.ipa`（60,703,795 字节，SHA256 `83cc254274521cf896ea06447a0ed3dc42c3378ede48d0c2f6723383ac7a9164`）。
- 核验：Bundle ID `com.liuhetong.liuhetongMobile`、**0.4.6 / 2165**、MinimumOSVersion 16.0、UIBackgroundModes 保留、17 个 Framework（WebRTC/SQLCipher/OpenSSL 等通话与加密组件齐全）、embedded.mobileprovision 在位（CI 签名候选，可重签）。
- **未验证**：真机安装与通话（待企业签名→回传→分发后进行）；本环境为 Windows，无法本地构建 iOS，构建由 macOS CI 完成。
