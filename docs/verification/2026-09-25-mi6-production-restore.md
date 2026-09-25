# 2026-09-25 生产认证与配置恢复验证

## 结论与范围

用户明确要求恢复之前的生产部署。2026-09-25 09:45 HKT 已将 09-24 `wallet-360` 部署遗漏的既有配置恢复到 Business API 和 worker；沿用当时正在运行的 `wallet-360` 镜像、PostgreSQL `0088_profile_grapheme_limits`、其他 25 个容器及网关。09:57 HKT 的持续检查显示两服务健康、零重启、运行配置准确匹配候选，其他容器的身份、镜像、健康、重启次数和启动时间均未变。

本次恢复使服务端重新装配已核准的手机号认证和 Aliyun 短信适配器。**没有发送真实验证码，也没有使用账号登录 MI 6**；短信送达、登录完整链路及先前超过两分钟转圈的问题仍须设备实测，不能仅凭健康探测宣称已解决。

上句描述恢复操作本身。恢复后用户在 MI 6 自行尝试手机号登录，先看到“聊天设备会话确认未完成”，点击原 Debug2174 的“重试”又看到“验证码无效或已过期”。01:58–02:04 UTC 的只读服务端聚合显示验证码请求 3 次返回 202、手机号登录 3 次返回 200、随后同路由 5 次返回 400；三条登录 OTP 挑战各消费一次。没有账号级关联，不能把窗口中每条请求都归给 MI 6，但这与客户端重复提交一次性旧码的路径一致。服务端单次消费是预期保护；首次聊天设备会话确认失败的本地原因仍待更高 Debug 版分类诊断。

## 根因与配置边界

09-24 19:29 HKT 的 API/worker Compose 替换漏掉 09-24 上午已验证 v4 的 16 项环境变量，使 `BUSINESS_PHONE_AUTH_ENABLED` 回落为 `false`、`BUSINESS_SMS_PROVIDER` 回落为 `disabled`。验证码申请因此在调用供应商前返回 503 `PHONE_AUTH_DISABLED`。另外两个原有钱包开关出现与已核准配置相反的值；`wallet-360` 源码只改资金新鲜度监控，没有批准变更转换策略。恢复候选从**当前**两个运行配置派生，仅补入以下 16 个缺项，并恢复两个原有开关：

| 类别 | 恢复的配置名或安全状态 |
| --- | --- |
| 手机与短信 | `BUSINESS_PHONE_AUTH_ENABLED=true`、`BUSINESS_SMS_PROVIDER=aliyun_dypns`，以及 OTP 密钥、Aliyun 接入/模板/地区/时长对应的既有 7 项变量；凭据值从未进入仓库或报告 |
| 已核准业务配置 | `BUSINESS_GROUP_TRANSFER_COORDINATION_ENABLED=true`、`BUSINESS_RED_PACKET_OWNER_COMMISSION_ENABLED=false`、`BUSINESS_WALLET_AUTO_DEPOSIT_ENABLED=false`，以及 CAIBI 定价、FX 标识/密钥/缓存的既有变量 |
| 原有键纠偏 | `BUSINESS_WALLET_DEPOSIT_AUTO_CONVERSION_ENABLED=false`、`BUSINESS_WALLET_USER_CONVERSIONS_CLOSED=true` |

完整变量**名称**与配置 SHA 记录于服务器私有 `candidate-manifest.json`。未改动其他环境值、镜像或网关；本次部署未执行数据库迁移或人工资金写入。只读聚合未见下文所列红包、兑换、充值范围的新记录。群转让开关取 09-24 上午经核准的 v4 状态；更早的 09-23 快照不是本次配置基线。

## 执行与可复核证据

| 阶段 | 结果 |
| --- | --- |
| 冻结 | 在服务器私有 `/opt/starchat/releases/mi6-auth-restore-20260925/` 保存切换前 API/worker 精确 Compose、27 容器身份与状态、数据库备份。目录 0700，文件 0600。备份 24,655,925 字节，SHA256 `57ab0da1520d0a3dc3701d8a5d5dc3bf0f871ccc484061a0875df715b4dd6b8e`，`pg_restore --list` 通过。未下载生产数据。 |
| 候选 | API Compose SHA256 `6f7ad36c39ad583a50a549b79b699e0a7aa3b5407a9386cedd93d88cf2c5eae4`；worker `04a47ae83cde39b0d4b1ef9a75e0dde904a3f3b096f52c0d3c1ccc5cbf766dcb`。仅 16 个补入键和两个经审查的现有键变化。API 镜像 `sha256:2e7ca2e5…`，worker `sha256:bef6c837…`，均与切换前相同。 |
| 兼容与评审 | 两镜像在禁网容器分别通过生产 `Settings()` 装配及 Aliyun SDK 客户端构造，未向供应商发请求；现有 release guard 各通过 9 项 refresh 协议检查。生产备份恢复到隔离 PostgreSQL，当前镜像的用户、红包和钱包模型只读兼容检查通过。ADR-0075 认证与 ADR-0078 财务意图、领域及质量安全复审完成。受控脚本 8 项模拟失败路径测试通过，退出码 0。 |
| 发布 | 2026-09-25 01:45:06–01:45:34 UTC，通过现有 `business_release_guard.py` 仅切换 API 和 worker。切换脚本退出码 0，API ID `7e1d894d18a448fba444c37649115a2f3893f52d76fd10053c2a385697f296b9`，worker ID `22074903ac5b8943c561f4679485766ea5ef89acdc07343952d88ae3471ac193`。脚本在切换前检查容器/配置/备份/schema 漂移，失败可调用同一 guard 用私有快照回退；未执行回退。 |
| 发布后即刻 | 两服务 healthy、零重启；25 个其他容器完全未变；数据库仍为 `0088_profile_grapheme_limits`。切换前后只读聚合：自 09-24 11:29:46 UTC 配置漂移起新红包、抽成账本、钱包转换、充值记录均为 0。 |
| 持续复核 | 01:57:32 UTC 再次核对：实际 API/worker 环境与候选完全一致，手机/短信/群转让/红包抽成/钱包开关为预期值；两服务 healthy、零重启、其余容器未变；同一时段的只读财务聚合继续为 0。`final_check.py` 退出码 0。 |

## 公网与日志验证

- 服务器经证书验证的 HTTPS：Business ready 200、Matrix versions 200；未认证资料请求 401；密码登录和短信申请使用空 JSON 对象 `{}` 均返回 422，证明两条路由已进入请求校验，不会发送验证码。API 环回 OpenAPI 目录有 311 条路径，密码、手机号验证码/登录、refresh、群转让路由存在。`postflight.py` 退出码 0。
- 工作站走既有跳板 SOCKS 并保留 TLS 证书校验：ready 200/0.211 s、Matrix versions 200/0.191 s、未认证资料 401/0.297 s。工作站直连曾 15 秒超时；跳板探测通过不等于 MI 6 网络已恢复。
- API 自切换以来没有新的 `ERROR` 或 `Traceback` 标记。worker 切换后有 20 条 Outbox “无注册消费者”死信告警，来源为钱包资金扫描审计和储备发布两类事件；没有额外异常标记或 Python Traceback。只读数据库聚合证明**该类告警**至少从 00:30 UTC 起持续产生，早于 01:45 UTC 切换。该消费者覆盖缺口须单独修复，不能当作短信配置恢复的成功或失败信号。

## 保留限制与下一步

1. 当前 API 镜像可在隔离恢复的 `0088` 数据库上运行并完成只读 ORM 检查，但镜像内缺 `0088` 迁移脚本，所以容器内 `alembic current` 仍会失败。此次未降级、stamp 或修改生产数据库；迁移脚本打包缺口需单独修复。
2. 恢复操作未取得测试账号，也未代用户发送验证码。用户随后自行尝试登录，但首次 Matrix 会话失败未被旧客户端分类记录；新 Debug 诊断和用户驱动的复现仍需完成。原密码登录超时的最终阶段也未定位；不应把服务器配置恢复等同于客户端卡顿修复。
3. 本次仅修改生产配置，无 Flutter/服务端源码变更，因此未重跑 Flutter 或后端完整测试。隔离装配、guard、HTTPS、健康、容器不变和只读财务聚合是本次发布门禁。

服务器私有目录保留原始备份、候选和精确回退 Compose，以及 guard 证明文件；报告只写安全开关状态、摘要和聚合数，不含手机号、验证码、Token、供应商密钥或生产数据。
