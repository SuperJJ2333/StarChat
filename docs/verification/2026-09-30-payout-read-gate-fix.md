# 提现列表读取修复

用户反馈“提现列表加载失败：钱包验证状态已变化，请重新验证并查询当前状态”。根因已用失败测试重现：`getSupportPayouts`（列表）、`getSupportPayout`（详情）、`getFxRate`（参考汇率）三个 GET 未进入钱包只读方法清单，被前端错分为写操作。未验证时，请求未发出就被本地 guard 拒绝。

修复：三GET走既有read guard；仍检查当前管理会话、钱包可读状态与服务端权限。显式写缺grant时打开既有验证UI并拒绝当前命令。验证完成不重放，需手工再次提交。管理员提现限制、60分钟验证、金融授权及账本保持。

新增两项先红后绿；补实际提现面板+钱包包装器组合测试。专项40项通过（钱包访问、提现面板、会话单例）。领域先行及独立安全审查通过；后续仅cache bust与保留已发布iOS文案，未变业务逻辑。verify执行后因缺.env停止，未导入生产秘密，不声称全仓通过。

2026-09-30 21:56:40 北京时间，仅静态3文件发布：admin-wallet-access.js、admin-home.js、admin.html；完整模块URL版本更新为20260930-payout-read-fix。fresh检查发现主页iOS已由另一发布更新0.4.25（2194），在写入前拒绝陈旧基线，再合并当前源保留该更新。API仍001ddf33、worker仍3efd5924，所有容器ID保持不变。双端严格TLS、3文件SHA256、JSONready、匿名提现401通过；无实际资金操作。

证据：[payout-read-gate](artifacts/2026-09-30/payout-read-gate/)；计划：[修复计划](../superpowers/plans/2026-09-30-payout-read-gate-fix.md)。私有前镜像和3静态备份留服务器`/opt/starchat/releases/payout-read-gate-20260930/private/before/`，回退应先验证当前最终SHA再恢复，不能覆盖后续发布。当前没有用户管理员会话，不伪造生产登录；具体用户刷新后的交互结果待实际使用反馈。

时间：测试生成时间、构建/前置拒绝/切换见工具记录及artifacts；生产开始精确时间来自deployed.json。没有重复运行未变化的API镜像和数据库验证。
