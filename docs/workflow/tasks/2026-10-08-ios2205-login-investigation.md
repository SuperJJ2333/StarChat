# iOS0.4.36+2205 登录持续等待/重启后只能看列表

## 恢复与用户事实

用户2026-10-08报告严重登录故障；19:38+08开始只读调查，用户确认“现在、输入账号密码后卡住，退出App再进入有正常登录后的消息列表，但无法发送或其他操作/无法接收”，覆盖安装旧版，iOS16.7.16。用户前次签名AppID异常已知，但不能直接当本次根因。

[调查计划](../../superpowers/plans/2026-10-08-ios2205-login-investigation.md)。exact已构建源码c628fe2e，managed history-icons-performance-2204；最终SHA a122af8389bcae5e25506b71e93181d6164e9007e8a859ed5f83a129c769a653。源码与生产配置未改。

## 当前证据

- 19:39:03+08近20min有business login2次200、matrix-login-token2次200、logout3次204、refresh11次200/19次401；网关sync320次200/11次499，未匹配Matrix login请求。为全服务聚合，不将其他用户事件/401或499认定本次错误。
- 瞬时business CPU3.11%、Synapse4.45%；不是全时段性能结论。19:40:03+08近40min iOS启动闭合诊断0条；挂起不产生异常报告，缺诊断不能当无故障。
- exact源码：LoginPage loading等待onLogin及session.bootstrap；DualDomainLoginService账号认证后取grant，再等待本地selector.selectAccount、账号SDK resume、Matrix token login/confirmation/sync。控制器等await不结算时loading不退出。重启展示保留缓存不证明Matrix线上就绪；安全能力仍被撤销时操作不可用。
- 重点尚待实证的边界为本地账户选择/旧SDK停止/SQLCipher打开与迁移/客户端初始化，含未设总体deadline的等待；不能仅给所有Future加超时或放行尚未授权聊天来制造修复。
- 新iOS原生18PASS是在iOS26.2，未覆盖iOS16.7.16真实企业覆盖升级；旧Keychain/安装数据/新签名身份变化亦未取得真机逐项基线。
- 已签profile及Runner AppID与BundleID不匹配，标准检查exit1；48CMS数学签名PASS不代表Apple信任/数据库Keychain兼容。回签额外添加ybvdb.dylib；Dart/engine/Runner非签名比较均因工具的__LINKEDIT segment range检查不可用，不能标为代码不变或故障已归因注入。

## 验收台账

| ID | 要求 | 状态 |
| --- | --- | --- |
| LOGIN | 输入账号密码后有限时间内成功或明确安全错误 | 用户故障确认；根因仍调查，无修复声明 |
| CHAT | 成功后能收发及操作，保留旧记录 | 当前未就绪；旧数据不清理 |
| ROOT | 单次stage/原生等待边界与可复现RED | 聚合及源码路径已缩窄，未取得实际设备等待栈 |
| IOS16 | 真机iOS16.7.16覆盖升级登录与历史 | 未验证；不由iOS26结果替代 |

证据docs/verification/artifacts/2026-10-08/ios2205-login-investigation：server-http-aggregate、startup-aggregate、non-signing-code-comparison及聚合脚本。没有真实密码/令牌/消息/原始敏感日志落盘。无生产写入、未清库/卸载、未重建或重发。

下一可执行步骤：取得卡住时设备的登录阶段/原生等待诊断，围绕实际账户选择/SDK生命周期/加密数据库恢复复现失败测试。用户此前无法USB为历史约束，不能假称已读取其设备日志或进行真机测试。签名兼容因素与客户端等待缺陷保持独立。
