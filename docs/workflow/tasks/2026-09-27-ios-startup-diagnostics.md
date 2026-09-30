# iOS 启动失败埋点与 refresh-watch 告警排查

## 当前交接（2026-09-27 16:22+08阶段）

用户批准独立未登录代码方案；实现、先规格/领域后质量安全审查均PASS，API候选已准备，生产发布仍未批准。工作树C:/Users/Administrator/.codex/worktrees/friend-video-followup/StarChat，移动基线05a2d950047f96d128fc1115cb7db5bec39db017。root元数据/既有移动接线/文档，三个实现agent仅各自模块，准备/审查agent仅证据；保留并行backend/frontend和SG工作。具体文件、锁、工具/源码SHA、真实退出码和全部审查/日志见[验证](../../verification/2026-09-27-ios-startup-diagnostics.md)。

**下一条操作：**35项范围内文件回填及索引核对已完成；服务端单独发布问题已提交，等待用户批准d392 API；无批准不切生产。批准后重读运行镜像/环境/挂载/代理漂移，仅发布API并检查新旧鉴权/健康/其他容器。无新迁移，worker保持。签名iOS分发/真实设备验收独立待办，原0.4.7不会自动获得新埋点。

| 验收ID | 实现与证据 | 发布/设备缺口 |
| --- | --- | --- |
| IOS-D01 | 首次await前记录、不依赖钥匙串/登录；27 recorder及174启动专项 | API候选未上线；新iOS包未分发 |
| IOS-D02 | 包装/直接fatal固定分类、预检cause、限定OSStatus/L04/L07；原异常类型/恢复/身份不变，red/green/独立审查 | 尚无受影响真机报告 |
| IOS-D03 | 闭合字段、20事件/32KiB/24h、冻结上传、4KiB入口、原子限流/去重；255API/121collector/14Linuxchecks PASS | 匿名数据不驱动邮件、认证或财务，best effort |
| IOS-D04 | 非阻塞/取消/有界补发，Flutter4775PASS/9skip、analyze0 | 原生iOS构建/覆盖更新/离线/保护状态真机未验收 |
| WATCH-D01 | timer/state六次只读SSH退出0；当前timer正常/协议401 | 未重启或改watch |
| WATCH-D02 | API切换时序吻合但非唯一根因；UUID/失败HTTP状态未留存 | SMTP不证明收件箱送达；恢复不证明此前邮件成功 |

## 最终身份与门禁

- 移动1764文件/19变化/native0变化，锁52207159…保持；已有全链路性能与网络诊断输入保留。本轮未构建/安装移动包，Debug2184仍为上轮版本。
- API候选sha256:d3922296962c41ec2c5b7a921a3ed53fac1138a4fb166e9877afa4ae23cd263b，基于actual e880ec8e…；worker15659d6c…/schema0090保持。4实际运行路径变化，1067项及478旧installed路径保持。0700服务器目录 `/opt/starchat/releases/ios-startup-diagnostics-20260927-prepare` 保留备份/恢复数据。临时候选容器清理，隔离PG停止；生产和25其它容器未变。见server-prepare/PREPARED.md。
- 原完整verify退出1（3041PASS/89skip/1CAPTCHA夹具失败），模块内Redis factory测试隔离修正269PASS；不改运行代码。原退出码/既有Starlette弃用警告保留，未抑制警告。余下门禁退出0：mobile108/1skip、UI33/476、import、AST273、单0090head/离线SQL/OpenAPI/Compose。最终Lua/collector专项补充已开始的全量，不重复36分钟门禁。
- 用户设备事实仅iOS0.4.7/覆盖更新后/解锁重试重开无效，系统/build未知；unknown提示不证明手机锁定或L04/L07唯一根因。

| 阶段 | 起止（+08） | 结果/计时依据 |
| --- | --- | --- |
| 只读watch | 14:53:13起，各capture JSON | 六次退出0，当前健康 |
| 设计/并行实现 | 至15:23阶段，精确总起点未知 | 用户批准，专项真实red/green |
| 最终Flutter | 15:33:05–15:36:37 | 4775/9skip/exit0；analyze同期0 |
| 原完整verify | 15:24:26–16:01:37 | exit1保留；夹具修正及269专项闭环 |
| 候选/恢复/回退 | 15:26:46–16:06:14 | 14checks/PG16恢复138表/只读0090回退，通过，含返工 |
| 余下verify | 16:12阶段，stage JSON | exit0 |
| 审查/回填 | closure/backfill工件时间 | 先规格后安全PASS；漂移保护 |

精确主动/工具/外部等待分解未完整采集，不能编造总工时或相加并行区间。原较早Flutter取消不算通过。所有声明关联最终相关输入，未重复等价门禁。

## 交接边界

未重启watch、发通知、清本地/钥匙串或重建Matrix身份；未提交Git/推送/部署或分发iOS。上轮e880授权不覆盖新候选，app-release-deployment第6条要求服务发布单独授权。旧e880配置可回退，无schema降级/worker替换。上报改善可观测性，不能保证未知故障不再发生；新签名iOS和首条真机报告仍需后续交付。无持续测试/候选容器运行。

## 初始记录（历史，以下状态已由上方交接覆盖）

## 恢复入口

- 目标/授权：用户 2026-09-27 要求增加 iOS 本地会话启动失败服务器埋点，查看 timer/state，并提供 alert UUID cecd31ea-4450-454d-8b47-6b8d8bc57aed / PROTOCOL_PROBE_FAILED。用户随后确认“按此方案实现（推荐）”，允许独立未登录接收端及客户端代码；生产服务发布仍未授权。
- 设计：[启动诊断设计](../../superpowers/specs/2026-09-27-ios-startup-diagnostics-design.md)、[ADR](../../adr/2026-09-27-preauth-startup-diagnostics.md)、[执行计划](../../superpowers/plans/2026-09-27-ios-startup-diagnostics.md)。
- 状态：代码实现及专项验证；没有新的包或生产变更。
- 工作树：C:/Users/Administrator/.codex/worktrees/friend-video-followup/StarChat；移动基线 05a2d950047f96d128fc1115cb7db5bec39db017。保留既有 backend/frontend 脏工作项。
- 所有权：root 负责元数据/现有移动接线/任务文档；startup_mobile_recorder 仅三个新客户端模块与tests；startup_backend_receiver 仅新API/admission/tests及main/OpenAPI与startup专用traceguard；startup_diagnostics_collector 仅collector/tests/runbook。已完成调查agents仅证据，不改生产。
- 更新时间：2026-09-27 14:57+08。
- 下一步：核对最小公开接收方案、完成两项调查证据与设计确认，随后按计划测试先行。

## 验收台账

| ID | 场景与预期 | 当前证据/缺口 |
| --- | --- | --- |
| IOS-D01 | 未登录/钥匙串失败时报告可独立上传 | 现有链路存在缺口；新方案待确认 |
| IOS-D02 | 启动包装异常保留安全类别/预检 cause/限定 OSStatus | classifier 和预检包装需增量；不改变身份/恢复判定 |
| IOS-D03 | 限定字段、队列、幂等与防滥用，无用户数据或凭证 | 设计已列明，尚无代码候选 |
| IOS-D04 | 异步报告不阻塞启动，离线可有限补发 | 需实现与真实 iOS 验收 |
| WATCH-D01 | 检查 timer/state 与当前协议 | agent 只读调查中，当前 timer 正常且协议401符合契约 |
| WATCH-D02 | 告警历史与邮件状态可准确解释 | API 切换时间吻合；watch 未存失败状态/异常，SMTP接受不能证明收件箱送达 |

## 版本与证据

- 新证据目录：docs/verification/artifacts/2026-09-27/ios-startup-alerts/。
- 上轮已发布 API e880ec8e…/worker15659d6c…/0090；新任务不复用其发布授权。
- 用户 iOS 版本事实：0.4.7、覆盖更新后、解锁重试/重开无效；系统版本与 build 未确认。此任务尚无该真机新日志。

## 阶段计时

| 阶段 | 时间 | 结果/下一步 |
| --- | --- | --- |
| 跨会话恢复/源码检查 | 本轮开始时段未完整记录，至14:57+08 | 现有 receiver/auth/salt 缺口已确认 |
| 服务器只读调查（并行） | agent 实际命令时间保存在证据 | 当前健康；继续确认事件UUID/探测观测 |
| 方案整理 | 14:57+08 | 待用户确认最小未登录上报方案 |

## 交接与回退

- 未重启 timer/service、未改 watcher、未发送通知、未清除本地数据/钥匙串、未重新生成 Matrix 身份。
- 客户端诊断只能提高可观测性，不能保证防止未知根因再次发生；0.4.7 原包尚无此次埋点。
- 现有工作树和上轮证据保持，后续只按声明文件 ownership 编辑，部署必须先验证候选/实际生产漂移。

最终检查：35项范围内文件SHA一致，1764移动/11后端冻结输入不变，文档21链接无缺失；主目录仅换行差异保留。回填脚本前两次保护拒绝未写入；第三次索引写入错误后35文件已成功，索引用最小additive patch恢复，所有原SG/其他索引条目保持。真实异常及恢复记录在工件，不重复运行一次性backfill脚本。单独API发布问题已提交，尚无批准。
