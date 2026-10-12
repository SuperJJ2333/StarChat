# Android2215 发布准备：独立质量/安全审查

结论：**PASS_PREPARATION_ONLY；无阻断发现**。本阶段在规格/领域审查之后进行，并附加一次独立静态复核。精确候选 `c1b1ccd777d7ef11a1a1af956547b43bbf89d573`，不批准未知真实APK或实际发布包。

## 实际运行与来源闭包

从候选Git对象逐个导出61个原始blob（不用作者checkout换行转换），核对60个准备manifest哈希。独立运行五个明确列出的unittest模块：**32PASS/0FAIL/0SKIP，exit0，6.793秒**；进程UTC12:24:44.2169611–12:24:51.3442759Z。测试使用临时合成APK、合成review和transport doubles；其中stream receiver/tar解包执行实际Python代码但仅操作本地合成sandbox。没有执行payload PostgreSQL测试、SSH/AWS、ADB、构建、签名或生产操作。

另实际运行 `verify_preparation.py`：60输入、14份原始静态捕获、16份Python AST和事务函数SHA校验全部通过。全部61份导出输入在测试后哈希不变。导出内容不重复提交；精确候选Git对象与本审查的export-identities.json可恢复输入。

独立重新计算的历史证据闭包，而非仅相信作者布尔字段：

- reference `538f90f6a4efcf5f30a17e1dec462ac01e43c94e` 的 `transact` UTF-8源码逐字等同，SHA `2a58136b46b4330f4695dd1f65506d8e4216b0fc06d3a3a0b0dacaa29e400742`。
- settings完整模块仅NOTES、Android前后version/build和基线错误文字变化；iOS值不改。PG测试仅2214→2215的模块/版本/trace标签变化。
- SettingService、AppSetting、AuditEvent、database四个Git源码及API镜像a935b414…ccab3、schema0095与历史证据一致。历史postgres.log原始字节与复用日志相等，SHA `e28db34430af9fb20a2f25136490b59254c9ba69612cfce5d033322fa084c966`。
- `apply_static`、`rollback_static`、`publish`三函数源码逐字不变。package工具仅版本/日期适配；executor除适配外只新增permanent_guards比较和正确的Android2214前态标签。delivery模块仅2214→2215标签差异。

## 防漂移、事务与回退核查

- `package_release.py:89–142` 拒绝旧/不完整成品、固定签名或ABI偏离、失败/缺项/重复builder步骤、源/锁/gate内容漂移与不安全相对路径。每个gate的语义真实度仍由最终人工独审读取实际证据；哈希本身不能证明手写报告内容。
- `execute_release.py:31–79` 绑定全包、实际orchestrator、runtime archive成员和两份最终审查文件；`229–254` 默认PLAN_ONLY、显式execute、前阶段receipt与新鲜基线/CDN检查。单阶段exclusive inflight和已尝试receipt限制重放。
- HK preflight `104–118` 增加永久guard/probe哈希；`release_2215.py:66–73` 在公共写前再次校验并对读取失败直接拒绝，同时检查容器与其他ABI。新增32例中的两项覆盖hash漂移、缺字段和读取失败。
- `release_2215.py:200–227` 写前验证staged和before字节、逐文件CAS、私有backup；中途失败只恢复仍等于本次after的已写文件，使用已校验的原始内存buffer，损坏备份不会被发布，外来新内容不会被覆盖。`230–238` 显式回退要求完整after状态、备份before SHA及逐项CAS。
- `settings_2215.py:28–59` 保留PostgreSQL advisory lock、行锁、十设置CAS、独一trace、SettingService事务、三条审计及readback；此前并发管理员/失败回滚六例按精确闭包复用。
- `release_2215.py:368–378` 只有数据库调用前的公共检查失败才自动回退静态；数据库调用/提交/读回结果不确定时保留已验证页面并写outcome-unknown，要求检查settings/audit，不猜提交结果。executor也记录UNKNOWN并阻止后续mutation；不会自动清标记重放。被终止进程留下inflight时须独立只读调查与人工恢复，不把工具自动恢复当已验证能力。
- `cloudfront_target:134–151` 保留16条及顺序，仅追加精确2215 HK路由；`delivery_2215.py:107–150` 固定AWS身份/分配/桶、整份策略保持和ETag If-Match；`execute_release.py:152–158` 在别名切换/发布前要求新的Deployed、HEAD200、预期字节数与CORS结果。没有新增全包公网回拉。

## 证据索引与剩余门禁

[独立32例原始日志](independent-32.log)、[命令和时间](independent-32-receipt.json)、[准备输入审计](preparation-audit.log)、[审计receipt](preparation-audit-receipt.json)、[61份导出身份](export-identities.json)、[独立PG/回退来源闭包](independent-source-closure.json)、[orchestrator差异](orchestrator-delta.json)、[审查环境](review-environment.json)。

不要把这些32个离线边界或复用的六个PG测试计为当前生产事务、真实APK/native/device发送测试。本轮没有真实2215 artifact、正式package或执行review，未构造替代数据。root下一步提供真实签名重建APK及原始receipts/门禁，再冻结并独审实际payload、source回填和唯一operation_id；执行前重复真实baseline检查。原有iOS、16KiB、OEM和SLO缺口保留。
