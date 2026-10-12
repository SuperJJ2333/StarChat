# Android2215 发布准备实施计划

> 执行方式：backend_review 在自有工作树内按既有授权直接实施，冻结后由root安排非作者SPEC/domain→QUALITY/security；本轮禁止执行发布。

**目标：** 为正式Android0.4.46+2215准备可审查、默认无副作用的发布工具，等待root提供实际最终APK及门禁身份。

**架构：** 从root冻结538f90f6a4efcf5f30a17e1dec462ac01e43c94e中的已发布2214框架逐项适配版本。保持两份Android静态文件、三条Android设置、追加一个精确CF路由的原有发布边界；UNKNOWN不重放、CAS、事务审计与受控回退均保留。仅本目录归本代理所有，root/mobile/version/生产不写。

**依据：** root本会话明确2215准备任务；移动交付、admin-production、release-metadata及Android固定签名重建runbook。产品修复和实际构建由root负责。

## 约束和待实包输入

- Android当前预期0.4.45+2214，iOS0.4.44+2213，minimum均3，CF16；先只读获取HK/SG当下事实，任何漂移先报告。
- 目标`ChatFlow-0.4.46-build2215-arm64.apk`，固定包名com.liuhetong.mobile与既有75b31签名；SHA、字节数、源码/manifest/lock与三项真实门禁必须作为必填输入，不生成虚构release.json或批准标记。
- package只验证最终artifact和原重建证据，不构建或签名，不引用/修改root当前工具路径。不得上传、建远程目录、改云资源、改设置/服务、起临时容器或重放业务。
- 保护iOS五设置、minimum、安装URL、五个其他静态文件、其他ABI别名、旧包、35运行容器身份、schema0095、永久guard/probe、桶策略和CF其余属性。
- 捕获静态文件按原始字节保存，两份副本opaque Git attributes；普通脚本用LF，证据哈希明确Git blob域，防止上一轮CRLF身份缺口重现。

## 步骤

- [x] 只读获取新HK/SG基线、目标未占用、当前旧APK完整身份；本地保存脱敏投影，保留只读超时与秘密不输出边界。
- [x] 原27+3边界用例适配新目标，先记录旧逻辑拒绝新目标的RED；再最小改版本字段/文件名/说明和前态2214，保持iOS2213与云账户等数字不变。
- [x] 保持SettingService事务体逐字节一致；用AST/source闭包对比证明继承六例真实PG证据适用，不启动PG/容器。若事务变化则不得宣称复用。
- [x] 离线边界GREEN、CLI/AST、原始Git blob导出回跑、捕获字节及源码证据哈希核验；额外覆盖永久guard漂移拒绝。
- [x] 冻结本目录提交并交独审（审查由root随后安排），给root操作说明、PG复用证据和待真实APK/实包审查门禁清单。实际执行继续等待root。

## 审查重点

实际2215包/receipt而非2214输入；iOS与账户/ARN数字保持；guard/schema/服务漂移不能被重新冻结吞掉；不确定提交禁止重放；静态回退仅恢复本操作校验过的before字节且拒绝外来after漂移；实包门禁未提供时不得产生可发布冻结包。
