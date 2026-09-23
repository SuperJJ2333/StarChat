# Debug 2164 四项反馈

基线 e8bf144046535d1c90e44dcd185c3fea0c0aeff4；隔离候选 `.worktrees/debug-feedback-2164`，保留2163已验证的outbox/media/diagnostics覆盖，不包含主工作区后续room/search未验修改。

计划：[实施计划](../../superpowers/plans/2026-09-23-debug-feedback.md)。用户明确要求修复服务器转让及Debug四项。短信后续澄清：没有自定义审核模板；APP提示仅加“畅聊 ChatFlow”，不解释供应商签名。短信正文仍是供应商模板，不声称已修改正文。

| ID | 预期 | 当前阶段 |
| --- | --- | --- |
| SMS | 普通验证码提示带品牌，无签名说明 | 3个Flutter页及HTML已改，auth86通过 |
| TRANSFER | 旧群查询不误报缺接口，开启持久协调 | 70后端/3真实Synapse/30Flutter/PG并发通过；独立spec后安全审查无新增阻断；生产候选备份恢复通过，尚未切换 |
| ANNOUNCEMENT | 正确区分解密待完成/格式错误，图片可恢复 | 38专项、analyze通过；3态HTML视觉通过；原群待真机复验 |
| WALLET | 缓存冷启动、隔离账户、复用全部账单样式 | 实现完成；独立审查返修生命周期/账户切换及订单状态映射，待最终全量 |

## 证据与时间

2026-09-23 +08。已读取移动端/生产/APK工作流、规格与UI技能；临时产物都在docs/verification/artifacts/2026-09-23/。初始主动执行起点未知，不编造工时。

- 20:20：转让专项冻结；详见 [转让报告](../../verification/2026-09-23-debug-feedback-transfer.md)。生产原镜像API ba801c6c2682、worker07019a1b76d1，0087唯一head，0历史转让意图。
- 生产备份只留0700远程目录 `/opt/starchat/releases/debug-feedback-transfer-20260923`；两文件overlay、API/worker唯一配置增量为开启协调；335项源码白名单校验及隔离PG还原/全表原列行摘要一致。准备脚本首次误用host python命令（不存在），改python3后成功；无生产切换发生。
- 手机目前2163，设备SHA与已签final一致，firstInstallTime保留2026-09-20 09:35:24；计划2164固定签名覆盖。
- 后端完整verify正在运行；具体退出码/日志未产生前不作PASS声明。
- 本地HTML候选8156，仅本任务服务；公告额外4187已停止。

下一步：钱包独立复审修复→最终Flutter全量/analyze/UI门禁→2164打包重建校验；后台完整门禁通过后生产切换+双点HTTPS；Mi6 install-r与版本/SHA/数据连续性核对。

20:49:53+08设备读回：0.4.5+2164 Debug已install-r、启动Status ok、进程存在；APK SHA cbd4e177dd1962efda3efbfd796a2b82dbb9bb0fc1fab7ec2600e615318f0c18，首次安装时间仍2026-09-20 09:35:24。source218.9秒，构建/独立验包exit0、339资产/27317类/清单语义全部一致。生产仍待完整verify后切换。

## 最终状态（20:56 +08）

全部授权实施与交付结束：Mi6 2164已装；生产两文件overlay与API/worker协调true已读回；335源身份/136表218320行隔离还原/22其他容器/双侧TLS健康鉴权通过。报告[最终证据](../../verification/2026-09-23-debug-feedback.md)。后端2706/68条件跳过，原verify在UI旧屏数断言失败exit1；修正后剩余全门禁exit0，不重跑不变后端；Flutter冻结3932+最终FX167、frontend298。用户原群与弱网效果待本人确认，不伪称真机全部业务通过。

临时SSH tunnel61344已关闭；预览HTTP8156进程52060保留。下一可执行步骤：针对用户2164具体反馈复现；没有待自动执行的生产资金操作/短信。任务主动耗时分解未知，后端1894.88秒、Flutter成功310秒、源码构建218.9秒，均为各命令自身时间，不累加为墙钟。
