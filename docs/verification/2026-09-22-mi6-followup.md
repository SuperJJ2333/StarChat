# Mi 6 四项反馈：修复与实际可用性

## 结论

本地客户端修复和旧充值取消后端已实现；Debug2158已完成构建/固定签名/重解包核验，并覆盖安装Mi6且启动成功，未清除数据。尚不能称为四项线上问题全部解决：当前线上镜像缺少手机换绑、参考汇率和取消充值接口。

| 用户反馈 | 修复 | 限制 |
| --- | --- | --- |
| 旧版转入群主显示获取失败 | 无业务意图时将路由不支持识别为旧服务兼容态，不制造待处理意图；已知业务意图仍严格等待完成 | 只反映Matrix实际权限，不冒充业务群主权威登记已同步 |
| 换绑请求业务失败 | 保留非JSON错误HTTP状态，区分未开放、关闭、配置缺失；未知channel不猜测验证方式 | 线上old-request实测404，须部署配套接口 |
| 钱包缺参考到账 | 充值/提现均获取FX，以精确整数分别计算预计点钻/参考USDT；过期或不可用明确展示，估值不进入记账 | 线上FX接口404，不硬编码或编造汇率；实际到账仍由客服批准 |
| 充值无取消按钮 | 新旧充值模式均有对应取消操作；旧模式新增幂等API和0082迁移；未知响应保留请求键并暂停付款二维码 | 后端未部署；取消后真实收款仍保留资金义务并人工核对，不自动退款或抹账 |

## 验证

- Flutter全量：3751 passed，exit0；analyze无问题，exit0。
- 钱包专项121 passed；后端取消相关123 passed；群转让29 passed；手机换绑8 passed。源日志分别位于本日 artifacts 下，客户端全量包含本轮新增测试。
- 完整verify已PASS（exit0）：后端2463 passed/58 skipped，OpenAPI及Compose通过。日志：[verify-full.log](artifacts/2026-09-22/mi6-followup/verify-full.log)。这不是后续整合候选的门禁结果。
- 隔离PostgreSQL16.9验证PASS：0081旧意图逐字段快照在0082后保留；五项历史保护触发器阻止违规修改。实际锁等待下，取消先完成则到账进入REVIEW并保留10 USDT义务，到账先完成则取消409；同键并发仅一份命令/审计/Outbox。[完整证据](artifacts/2026-09-22/mi6-followup/cancel-pg-verification.md)。无真实短信/真实资金/生产写操作。

## 安装包身份

- [最终APK](artifacts/2026-09-22/mi6-followup/final.apk)：0.3.103+2158，Debug，arm64，com.liuhetong.mobile，145363243字节。
- SHA256：`72ce34d6cc354f02d371c2249171c402aef360a7391e41fa8641cb6cd1b82de0`。
- 固定签名SHA256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。
- 源构建→Apktool2.12.1完整重建→zipalign→固定签名→重解包比较均exit0；27317类归一化代码一致、339原生库/资产字节一致、清单语义一致。证据[rebuild-verification.log](artifacts/2026-09-22/mi6-followup/rebuild-verification.log)。
- Mi6重连后已核对现装签名及版本，2158覆盖安装Success并启动；未卸载或清数据。证据[installed-verification.json](artifacts/2026-09-22/mi6-followup/installed-verification.json)。用户业务场景验收待反馈，不用启动成功替代。

## 后端阻断与下一步

只读核验线上business-api:refresh-040-20260922缺少新路由。审计发现本地缺少线上刷新恢复协议，0080_refresh_recovery与本地迁移分叉，不能整体发布当前主工作区。详见[发布就绪审计](2026-09-22-phone-wallet-release-readiness.md)。

已提供[具体后端候选整合Prompt](../workflow/prompts/2026-09-22-phone-wallet-compatible-backend.md)。必须先完成候选整合和隔离验证，之后才具备具体发布审批条件。

