# 钱包绑定与支付密码

## 恢复入口
- 用户授权：本任务钱包重构；补充1:1、0手续费、最低10 USDT。debug推送Mi 6，真机交互留用户验收；新增金融事务执行隔离校验，不操作真实资金。
- 计划：[实施计划](../../superpowers/plans/2026-09-11-wallet-binding-payment.md)；[ADR0068](../../adr/0068-points-wallet-payout-pin.md)；[完整验证](../../verification/2026-09-11-wallet-binding-payment.md)。
- 工作树 `.worktrees/moments-im-mi6-20260910`，分支 `codex/wallet-binding-payment-20260911`，起点694ce039。主仓其他任务编辑未动。
- 状态：实现、隔离校验、配套API发布及debug安装完成；真机交互待用户验收。
- 最后更新：2026-09-11 00:40+08；下一步：用户在Mi 6验收交互，若报告问题先核对2087与服务端fea5b941镜像。

## 验收台账
| ID | 场景 | 实现/证据 | 未执行 |
|---|---|---|---|
| W1 | 标题钱包，卡内改绑，未绑定充提灰色无操作 | Flutter定向analyze通过，HTML同步 | 真机交互待用户 |
| W2 | 独立充提，实时点钻余额、全部提现 | 入页/恢复/全额/15秒可见轮询；BigInt精确金额 | 真机交互待用户 |
| W3 | 1:1、0费、最低10、幂等恢复 | 159项隔离财务/API/PG通过 | 真实资金未操作 |
| W4 | 复用PIN，取消不扣款/未付款订单退点钻 | 同PaymentPinPage；领域及安全审阅通过 | 跨红包并发继承锁序风险另记 |
| W5 | debug Mi 6 | 0.3.83-debug/2087，install-r Success，设备SHA匹配 | 未启动代测 |

## 版本与证据
- APK包名com.liuhetong.mobile.debug，SHA9446b313…41061de，稳定debug证书34999c8b…5bc1f1。
- 服务端本次基线44057e8c，最终候选fea5b941（首轮fbcc95af加历史报价投影补丁）；只重建business-api，开关/schema不变。
- 证据根：docs/verification/artifacts/2026-09-11/wallet-binding-payment。日志保留精确命令、exit、hash及工具版本，不把未运行项标通过。

## 阶段计时
| 阶段 | 时间（+08） | 结果/来源 |
|---|---|---|
| 调查/澄清 | 2026-09-11起始未单独采集 | 不估算精确墙钟；用户澄清财务规则后实施 |
| 并行实现/审阅 | 至00:28 | 领域→质量，MFA恢复probe与旧USDT恢复均修复 |
| Flutter build | 00:23附近，Gradle21.6s | build.log exit0 |
| 重建/签名校验 | 至00:26 | 27242类、339原生资产不变，exit0 |
| 财务隔离 | 至00:29:37 | 核心13.68s、PG40.83s、API日志；并行不加总 |
| 服务端备份/发布 | 00:29–00:31 | 备份隔离恢复、健康200，其他容器未变 |
| Mi 6安装 | lastUpdateTime00:32:13，核验00:33:27 | install-r/设备SHA |
| 兼容复查 | 00:35起 | 旧报价funding_amount:null投影补丁 |

## 交接与回退
- 真机步骤与预期见完整验证表；未执行全仓verify（本地Docker daemon缺失），不声明全仓通过。
- 生产备份/回退配置仅服务器0700目录 `/opt/starchat/releases/wallet-points-pin-20260911/`，不得下载或提交敏感数据。
- 临时PG容器及两个自建SSH隧道均已清理。
