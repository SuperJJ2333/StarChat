# 聊天可靠性与自动诊断修复

用户已授权修复上轮三项问题并自动上报异常日志，要求不增加负担、不恶化体验。实施见[计划](../../superpowers/plans/2026-09-21-chat-reliability-diagnostics.md)。

基线3d968997，工作树`.worktrees/chat-reliability-diagnostics`，独立分支codex/chat-reliability-diagnostics-20260921。主树其他财务/身份改动不纳入。原调查证据在主树docs/verification/2026-09-21-chat-history-network-audit.md及同名工件。

状态：源码修复、规格/质量审查、最终门禁和服务器诊断接收端上线已完成；新移动安装包及真机验收未进行。T1代理A逻辑/滚动，T2代理B发送/日期，T3代理C诊断通道，root搜索/UI/接线/集成。初始精确开始时间未记录，后续按工具时间填写，不虚构工时。

约束：日志白名单与预算见计划，禁止聊天内容和任意异常字符串；异常上报不阻塞发送，失败静默退避。生产既有变更需实时核定并保留。设备原始发送事故仍未复现，修复已证缺陷并增加定位证据，不伪称所有事故根因唯一。

## 2026-09-21 22:17+08 阶段记录

- T1/T2/T3及root搜索/页面接线已实现；专项红绿证据分别保存timeline/send-date/diagnostics/search。A规格复审发现两项补强：后台sender诊断与预算外全量搜索源，正在补齐，不把审查缺口标成通过。
- T1来源1003次查询底层snapshot由2008降至2；逐帧锚点误差0（合成widget），append气泡实例回归已修。T2定向142项通过；T3后端26、Flutter22及真实Dart→FastAPI loopback通过。
- 全Flutter/analyze开始于22:12:13+08（输入hash见flutter-gate）。全analyze退出0；全测仍在执行。发现本任务timeline组件替换需适配旧ListView测试finder；另长Windows路径导致旧媒体fixture失败待短路径复验，不声明全部通过。
- verify.ps1已启动，使用本工作树从.env.example复制的隔离render配置，未读取生产秘密。infra143、getui28、matrix-bot9已过；API/Worker仍执行。全局Python依赖预检可导入pytest/argon2/fastapi/alembic。
- 生产只读基线及候选准备由诊断代理记录于diagnostics/production-readiness.md；API现行镜像main-clean-20260920，日志20m×10。候选只增client_diagnostics.py和main两处注册，无迁移；需精确信任重核网关IP，避免IP限流全体共享。此时未切换。
- iOS2145权限/重启任务仍在另一工作树，待用户出口合规确认。本分支基于main2152，不冒称包含未合并2145或本次已产生新安装包；后续移动交付需先整合既有权限/重启修复及核定build。
- 下一步：收口两项规格缺口→质量安全复审→最终门禁证据→仅诊断端增量上线和读回→移动源码交接/新包独立记录。真机弱网/大历史profiling仍需新客户端，不能用本地测试代替。

## 审查返工结论

规格审查两项（后台诊断、预算外全量搜索源）已修复。质量审查P1发送timeout提前释放真实请求所有权已修复，原始future直到settle保留claim，lateACK在dispose后仍持久化；82项定向通过。P2 retained搜索快照撤回后首次曝光已通过当前索引重校验修复，独立实际viewport/controller/engine回归证明旧投影泄漏、新投影过滤。移除扫描全量model缓存，媒体读取同样检查当前撤回/隐藏。两轮审查均最终通过；先前中止的全测不计为通过，最终短路径全量另记。

## 服务端已上线与验证结果

`verify.ps1`退出0，API/Worker2231通过、58按环境条件跳过（1397.32秒）；infra143、getui28、MatrixBot9、mobile84；UI契约32组件/375页面、唯一迁移head/offline SQL、OpenAPI、Compose全部PASS。Starlette TestClient与Getui Pydantic旧写法弃用告警已记录，不是新增代码告警；未执行生产迁移。

22:33公网健康200/ready、未认证诊断POST401；22:34独立核验镜像`sha256:1e3f3cd887cd15db708160caa0eb79f201db061fc51d1627f2b21048fb965f42`、两源hash、精确proxy trust、原63env+3mount、日志20m×10、其他容器未变。启动后有界日志快照无error匹配。证据`diagnostics/deploy-result.log`、`public-verification.json`、`production-final-acceptance.json`。

回退保留在服务器`/opt/starchat/releases/chat-diagnostics-20260921-1415`，按`diagnostics/candidate/REVIEW.md`的审核manifest命令执行；不得回退覆盖后续其他发布。未构造生产会话、未写测试生产诊断；真实新版上传仍待新包。

## 最终客户端门禁与下一步

最终Flutter3740通过、0失败，exit0；全analyze无问题，exit0。完整进程22:30:00–22:35:48+08，输出测试5分35秒；1146输入已冻结并读回，仅sendDispatchTimeout过时注释同步，执行代码无差异。先前长路径失败与中止轮次均留存，不伪装通过。临时T:映射与SOCKS18946已关闭。

| 阶段 | 开始/结束（+08） | 结果/计时边界 |
| --- | --- | --- |
| 实现、红绿、复审 | 首段精确起点未知；各子目录保留工具计时 | 不虚构总开发耗时 |
| verify全仓 | 22:07:18–22:31:24 | API/Worker自身1397.32秒；总脚本exit0 |
| 两文件生产切换 | 22:32:14启动新容器；22:33公网、22:34独立验收 | 镜像及回退审查通过，无迁移 |
| 最终Flutter | 22:30:00–22:35:48 | 3740/0；与生产验收并行不重复累加 |

后续移动交付：先把本分支和`codex/ios-testflight-permissions-20260920`已批准修复整合到干净候选，保留main2152的生命周期修复；核定新build，再按既有内部TestFlight及Android固定签名流程构建。2145待用户出口合规确认，不重复上传，不把旧包当本次修复。新版本真机验收：异地一端断网另一端发送、大历史快速/缓慢上滑和再进入、稀有关键字/日期取消/重试、服务器收到闭合诊断元数据。客户端真实上报和系统级卡死覆盖尚未验证。
