# 钱包应用接入与 MI 6 验证

日期：2026-09-06。用户授权接入实际钱包代码并验证 MI 6，保留无需真实托管商的约束；随后明确暂不安装或同步 Figma。

## 当前结论

应用代码已接入安全规则，领域审阅及后续 Quality/Security 复核通过隔离 Sandbox 范围。真实资金功能仍关闭，没有部署生产服务、触碰真实余额或调用真实托管。用户开启 USB 安装后，MI 6 独立测试包安装成功；双向兑换、余额刷新、响应丢失重启重试、储备不足拒绝已通过真机交互及后台核对。

## 实现

- 双向兑换在单事务内关联两个独立资产的复式过账；金额字符串、精度校验、向下取整尾数、原始请求幂等绑定。
- 全量可兑付点钻负债、USDT 负债和人工审核应付款纳入储备；未决付款阻断发行；结算后刷新独立模拟资产证据。
- 提现申请冻结、不同人员双审批、不可变金额地址摘要、提交前取消、未知结果仅查询原订单、独立查询后结算/释放。
- 公共账本接口执行保守风险冻结，Worker 检测未知与外部孤儿订单并对账；审计和 Outbox 与资金操作同事务。
- Flutter 展示冻结/可用余额和双向兑换；按账户及服务地址持久保存请求。安全复核发现的提现重复意图已修复：受理后保存原订单 ID，查询失败及页面重启不会重新 POST；确认终态后需明确创建新申请。
- 新增 additive migration 0040，更新 API、OpenAPI、HTML 与 UI 注册表。Figma 远端未修改，明确记录用户例外。

## 验证证据

- 后端核心：50 项通过（含 13 项真实 PostgreSQL），另有 75 项钱包/账本/红包/转账回归通过；最终扩展安全套件 24 项通过。
- API 门禁测试：先红后绿，6 项通过。
- 本机 HTTPS 实际 API 调用验证通过：10.123456 USDT 兑换保留 0.003456 尾数、反向兑换、成交后响应丢失重试只过账一次、资产归零后拒绝新兑换。证据 `https-api-verification.json`；不是 Android UI 实测。
- Flutter 钱包：先红后绿，7 项通过；全量 Flutter 1,185 项通过；相关文件 analyze 无问题。
- UI 漂移检查：17 个组件、330 个页面通过。
- 两项旧回归测试按新规则修订后，迁移/Worker 定向 10 项通过。最终 `scripts/verify.ps1` PASS：合计 498 项通过、21 项跳过（含另行覆盖的 PostgreSQL 环境门禁）；OpenAPI、UI 契约、AST、迁移离线生成和 Compose 检查通过。日志见 `artifacts/2026-09-06/wallet-application-mi6/repository-verify.txt`。既有 Starlette/httpx 与 Pydantic 依赖弃用警告保留；Android 构建提示插件未来需迁移 Built-in Kotlin，当前构建通过。
- 0040 在隔离 PostgreSQL 上验证新增表及历史数据保留，破坏性 downgrade 拒绝。完整历史升级仍有既存 0025 重复 `moments_preferences.cover_url` 问题，不得据此宣称生产迁移演练通过。
- 领域审阅先通过，Quality/Security 随后复核通过；仅针对 Sandbox 与生产资金关闭的代码范围。

详细后端证据：[core/evidence.md](artifacts/2026-09-06/wallet-application-mi6/core/evidence.md)。

## APK

版本 `0.3.47+2049`，ARM64，非 split。三项正式 HTTPS 编译配置保留。两包均经 Apktool 2.12.1 解包重建、build-tools 36 的 16K 对齐、既有固定密钥签名、重解包语义验证。每包 24,573 类与源包一致，331 项原生库/资产哈希一致，清单语义一致。

| 包 | 用途 | SHA256 |
|---|---|---|
| [standard-final/final.apk](artifacts/2026-09-06/wallet-application-mi6/standard-final/final.apk) | 正式入口，未发布 | `f6bfb616cf590f77f97429e48a70e97796ccb104f78657b96f1233b62d14bf9d` |
| [mi6/final.apk](artifacts/2026-09-06/wallet-application-mi6/mi6/final.apk) | 独立 `.audit` 包，实际 WalletPage + 本机 HTTPS Sandbox | `93a24ba3bf5512c1a0bde7a60af7ecb8614ca66bd0f154852187a4b8154c0cc3` |

固定证书 SHA256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。私钥/密码不在仓库。

## MI 6 安装与实测

ADB 识别 MI 6 / sagit、Android 9、arm64-v8a。现有标准包 `0.3.45`、versionCode 2048，证书 `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1` 与固定证书不匹配，不能安全覆盖升级。没有卸载、清数据或绕过签名。

独立测试包安装两次返回 `INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`。已请求用户在手机允许 USB 安装；没有更改设备安全设置。安装日志为 [mi6-install.txt](artifacts/2026-09-06/wallet-application-mi6/mi6-install.txt)。

后续用户确认已开启 USB 安装，再次 adb install 返回 Success。安装版本为 0.3.47-audit / 2049。真机实测：10.123456 USDT → 10.12 点钻；5.00 点钻 → 5.000000 USDT；第三笔 1.00 点钻兑换注入成交后响应丢失，强制停止并重启 .audit 后恢复原订单，重试成功且兑换总数仍为 3。再将模拟外部资产归零，手机显示“兑付储备不足，兑换未执行”，订单数及余额不变。最终手机与后台均为 96.003456 USDT、4.12 点钻、冻结 0.000000。

本机 HTTPS fixture 使用真实 API/服务、合成账户与 100.123456 模拟资产。测试 CA 只注入独立测试入口，没有关闭 TLS 校验；会话只在内存。初始账本快照已保存，服务不对公网监听。

本轮结束前已停止 fixture 并移除 ADB 端口映射。后续允许安装后需重启 fixture 及恢复映射。版本一致性检查曾发现应用内常量未同步，已修复并重新构建正式包；独立钱包测试入口不引用该版本配置。构建期间磁盘空间耗尽导致一次签名及证据写入失败，清理本轮具体中间 APK 后重新签名、完整验证与 HTTPS 验证均通过。最终包以本报告中的 `standard-final` 路径及哈希为准；旧正式包和部分中间包已清理，日志保留。

## 明确未完成的上线门禁

完整日结/对账导出、风险来源批次追踪、案件调查与双人安全恢复、真实告警投递和值班演练、真实托管/MPC及独立固化证明、生产 RPO=0 和灾备演练、历史迁移修复、iOS 构建及真机测试。现有快照、Outbox、保守全局冻结及模拟器持久化不能替代这些功能。撤回只限提交前取消，已确认链上付款不可撤回。

运行边界详见 [钱包应用 Sandbox 手册](../runbooks/wallet-sandbox-application.md)。

### 本次真机证据

截图：mi6-forward.png、mi6-reverse.png、mi6-response-loss.png、mi6-retry.png、mi6-deficit.png、mi6-balances.png；账本快照：mi6-bidirectional-state.json、mi6-retry-state.json、mi6-deficit-state.json，均在本任务 artifacts 目录。部分 uiautomator 抓取曾返回 null root，未将旧 XML 当作新证据；改用当次截图或成功的新 XML 核对。原标准包未卸载或更改。

本次已重新启动本机 HTTPS fixture 与 ADB 映射，供已安装测试包查看；当前保持故障注入后的模拟储备不足状态。仅本机合成资产，无真实资金。
