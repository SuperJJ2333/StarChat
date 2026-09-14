# 客服管理与人工充值补入账

## 恢复入口

- 授权：本轮三项修复，Astra主审、显式gpt-5.6-terra执行，当前工作区连续推进；最多同时两个执行代理，真机由用户测试。
- 状态：本地实现、规格/质量审查及受影响门禁49项复核完成；全量既有失败如实保留。未部署、未迁移生产、未构建或安装APK、未实际加款。
- 计划：[批次与验收](../../superpowers/plans/2026-09-13-admin-support-repair.md)；[主审证据](../../verification/2026-09-13-admin-support-repair.md)。
- 工作区：D:/pythonProject/outsource/StarChat，main，起始HEAD e28705548845d2296cdf34dcabd482926820adcf。18份既存差异逐段保留。
- 模型：本地主模型gpt-6-astra；工具明确接受gpt-5.6-terra，deposit_diagnosis/support_backend/support_mobile均显式指定；无独立服务端模型遥测，不以名称代替证据。
- 更新时间：2026-09-13T03:26:49+08:00。
- 下一步：生产发布需执行0065支持后缀扩展迁移及配套API/后台/客户端交付；本次具体充值需提供txid和预检错误码后核对实际阻断，不能据演示认定真实已入账。

## 验收台账

| ID | 场景 | 本地结果 | 外部边界 |
| --- | --- | --- | --- |
| S01 | 客服管理、别名、角色默认 | 后端精确解析+前端SUPPORT_AGENT默认+浏览器通过 | 未发布 |
| S02 | 移除客服身份 | 三客服角色撤销，保留USER/SUPER_ADMIN；页面确认和错误保留 | 浏览器native confirm阻塞；服务/API测试通过 |
| S03 | 每客服2～6汉字后缀 | 默认官方客服，新增support_profiles，保存自定义通过 | 0065未在生产执行 |
| S04 | 昵称/备注后黄色@后缀 | 联系人/资料/私聊列表/标题真实入口测试及HTML视觉通过 | 用户真机未验收 |
| G01 | 客服点钻派发 | 别名、搜索select、分页、原资格及Decimal；失败同稿幂等 | 未实际发放 |
| G02 | 原因默认 | SUPPORT_CAIBI_GRANT下拉，浏览器通过 | 未发布 |
| D01 | 预检待处理原因 | 预检只核对；原成功后未刷新父列表 | 尚未获取本次txid |
| D02 | 合法执行和刷新 | 合成EXECUTED→父列表已入账，后端原金融回归通过 | 不代表生产资金已入账 |

## 计时、证据与限制

- 准备开始精确时刻未知；原记录02:36:38+08:00完成规则/审计/源码核对，不估算准备耗时。
- Astra后端定向52项53.01秒；全业务API/worker1862通过、52跳过、2个迁移预期失败，962.95秒，修正后仅复跑受影响门禁。
- Flutter全量2474通过/29既有钱包失败，约101秒；analyze25.3秒无问题。
- HTML最终184项179通过/5既有失败，1.26秒；新增token不一致已修复。
- 证据目录：docs/verification/artifacts/2026-09-13/admin-support-repair/；source-sha256.json标识文件输入，baseline.patch与existing-diff-preservation-final.json证明原差异保留。
- 无可用隔离PG认证/Docker daemon，52项跳过不计通过。无clone/pull/reset/自动提交或生产写入。
