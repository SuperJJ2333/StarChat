# 网络诊断兼容接收端发布验证

2026-09-27用户明确授权“先发布兼容接收端，再纳入客户端更新”。香港兼容接收端已上线；最新客户端网络增量已在源码中核验，未在本任务构建或分发APK/IPA。AWS资源未购买，DNS、主区、S3未变更。执行依据[发布计划](../superpowers/plans/2026-09-27-network-receiver-release.md)、[生产工作流](../runbooks/admin-production-workflow.md)；恢复入口为[任务记录](../workflow/tasks/2026-09-27-network-receiver-release.md)。

## 发布对象与现场身份

实时基线是account-profile-followup发布：API镜像`sha256:9083f0279fbc46811e49fd546322ac66c29b572d4b8cc5460478a1915a0701a8`，schema`0089_username_claims`，341项源码/迁移/依赖输入。此次以该不可变镜像为基础，仅替换`app/api/client_diagnostics.py`；原有PerformanceOperation/Observation、events+operations共享20条预算、accepted计数、认证、限流、16KB流式上限原样保留。

候选/已发布镜像：`sha256:bb108b47ce66788c1c65550eb221e017f8d6535e2539239bd40f32852e1249ed`。接收文件SHA256：`6033c300ca6dfd59335e185aea476134e80f1b60845d0d2044ae8476711d6e29`。构建禁网、上下文只有Dockerfile与该文件；341项集合不变，其余340项逐项一致。未从共享脏树构建整套服务，未升级生产依赖。

主目录已同步实际发布文件，并只更新OpenAPI的`/api/v1/client-diagnostics`路径；其余路径、组件与元信息完全相同。新契约SHA256为`b7655d62108b12bcb2bad968c6c443979fd4d12c4e145e5b97c9d0c8abd710ef`。[回填身份](artifacts/2026-09-27/network-receiver-release/main-sync-receipt.json)。

## 门禁与生产验收

| 场景 | 实际结果 | 证据 |
| --- | --- | --- |
| 合并保留现有性能协议 | 红9测3错误，绿9PASS；原诊断/网络115PASS；独立规格后质量安全复审通过 | [合并身份](artifacts/2026-09-27/network-receiver-release/merge-evidence.json)、[根审查](artifacts/2026-09-27/network-receiver-release/root-merge-review.log) |
| 真正Linux候选 | 契约9PASS、HTTP7PASS，使用冻结生产依赖；模拟认证只在隔离测试环境 | [Linux契约](artifacts/2026-09-27/network-receiver-release/remote-linux-contract.log)、[HTTP](artifacts/2026-09-27/network-receiver-release/remote-linux-http.log) |
| Compose/运行环境 | 完整往返与停止容器探针核对环境、CMD/ENTRYPOINT、挂载、端口、网络、健康、日志、用户等；仅镜像变更 | [最终输入](artifacts/2026-09-27/network-receiver-release/final-input-identity.json)、[准备](artifacts/2026-09-27/network-receiver-release/prepare-retry.log) |
| 私有备份与隔离恢复 | 27,217,936字节dump只留远端；137表/263987行，head0089；迁移前后原表结构及行哈希一致 | [恢复摘要](artifacts/2026-09-27/network-receiver-release/remote-restore-after.log) |
| 原启动命令 | 隔离恢复库、测试环境、无公开端口，实际原CMD启动并ready；运行OpenAPI同时有operations/networks | [运行证明](artifacts/2026-09-27/network-receiver-release/remote-runtime-startup.log) |
| 生产切换 | 02:05:28–02:05:43 +08，只重建business-api，退出0 | [切换](artifacts/2026-09-27/network-receiver-release/deploy-result.json) |
| 生产最终复核 | 02:45:49 +08：healthy、0重启、head0089、无新增Traceback/maintenance_failed，26其它容器ID/启动时间不变 | [复核](artifacts/2026-09-27/network-receiver-release/final-live-verify.log) |
| 公网TLS | 香港源机与Windows jumper native curl：ready200、admin401、diagnostics401、staff-login空体422；保持证书校验 | [香港](artifacts/2026-09-27/network-receiver-release/public-host.json)、[jumper](artifacts/2026-09-27/network-receiver-release/public-jumper.json) |
| 主目录接收端+OpenAPI | 120PASS，1条既有Starlette/httpx弃用警告；未掩盖警告或升级依赖 | [主目录专项](artifacts/2026-09-27/network-receiver-release/main-focused.log) |

恢复一致性是在alembic upgrade head前后验证；不据此声称整个API后台任务启动后所有业务数据恒定。生产未伪造有效用户会话，新旧正常请求的积极接受证据来自真实候选Linux隔离测试。日志轮转实际读回为json-file20m×10，保持原设置；它不保证留存72小时。

此次单文件发布复用此前对未变网络模型的红绿与安全证据，并以当前生产341项身份、真实Linux、隔离恢复及主目录120专项验证增量。未重复运行跨所有服务的`verify.ps1`；此前2862PASS/87skip只属于其历史输入，不宣称覆盖目前全部并行源码。新客户端输入已变化，因此单独执行下面的新全量Flutter门禁。

## 最新客户端与采集工具

隔离树`C:/Users/Administrator/.codex/worktrees/network-client-inclusion/StarChat`，分支`codex/network-client-inclusion-20260927`，基础HEAD`b9eca8a419614112b085439445b7fd031027a740`，含362项现有公共变更，冻结1751项Flutter输入。Flutter3.44.9/Dart3.12.2；锁SHA`5220715970aa207f7201fbe12b428c30e3e1ef76a0cca7f4bbee3e94f588d68b`，离线依赖准备后恢复原锁字节。

专项374PASS、全analyze0问题、额外网络+性能同批探针1PASS；全量`flutter test --no-pub`在02:37:24–02:40:47 +08退出0，**4694PASS/9skip**。默认ANNOUNCEMENT_DIAGNOSTICS=false导致9项条件跳过；启用该开关另跑对应文件9PASS/1反向条件跳过，exit0。[输入与专项](artifacts/2026-09-27/network-client-inclusion/client-inclusion-verification.json)、[全量日志](artifacts/2026-09-27/network-receiver-release/latest-flutter-full-test.log)、[全量计时](artifacts/2026-09-27/network-receiver-release/latest-flutter-full-test-result.json)。

独立终审确认测试树1751项原始哈希保持冻结、主目录六个网络文件逐字节相同；主目录其余669项仅CRLF/LF差异，3项代码/注释空白含冗余CR，规范化后无逻辑漂移。主目录整个Flutter集合不冒称原始字节完全相同，门禁归属上述实际测试树；详见[终审与输入边界](artifacts/2026-09-27/network-client-inclusion/post-full-input-check.json)。

当前源码元数据0.4.15+2182；诊断按原发布版本分组，Android已知ABI安装码4182归入2182，未知偏移保持原值。探针验证networks与operations共存，未携带URI/path/body。此处不是安装包/签名/原生平台验收，也未承诺内层PerformanceClient保留IOStreamedResponse subtype/detachSocket；现有业务JSON完成路径与独立网络decorator属性已覆盖。

采集器新增兼容省略默认events与operations混合日志：只导出严格验证的networks；operations只检查对象列表和与events共享20条预算，内容整段丢弃，不复验性能语义。未知父字段、64KiB单行、16MiB/20000摘要出口上限保持，元信息明确边界。红8fail/62PASS→工具89PASS，root复跑89PASS。[红](artifacts/2026-09-27/network-receiver-release/collector-mixed-final-red.log)、[绿](artifacts/2026-09-27/network-receiver-release/root-tool-tests.log)。

发布后只读收集回溯一小时2703行，0有效network摘要，扫描未截断；结果`no_valid_network_summaries`，[覆盖元信息](artifacts/2026-09-27/network-receiver-release/post-release-network-summaries.meta.json)。日志是否完整留存未验证，0摘要不表示0失败。尚未记录新版真实摘要首达时间，7–14天观察窗口未开始；现有primary_api摘要仍不能归因用户地区/运营商或对照香港与新加坡同栈，不能据此选主区。

## 可重试与回退

远端目录`/opt/starchat/releases/network-receiver-20260927`为0700；私有环境、Compose、inspect与dump不下载。旧镜像和候选私有Compose均冻结。手动回退前先复核当前配置，发现同镜像下的后续配置漂移也停止覆盖；脚本自动事前保护仅拒绝未知后续镜像，恢复配置核对在回退之后。回退命令经jump wrapper运行`python3 /opt/starchat/releases/network-receiver-20260927/release.py rollback`，只恢复API镜像，不覆盖/降级数据库。隔离恢复/启动容器已停止，审阅资料保留。没有遗留本任务隧道或运行测试进程。

真实前置失败保留：生产Compose2.40.3不支持create的--no-deps，准备第一次退出1、未切换；改为明确单服务create，部署up仍--no-deps，重试通过。jumper是Windows，python3验证失败；原curl --proxy=也不支持，改用native curl --disable --noproxy *，四路TLS验收通过。一次本地flutter路径发现失败后使用已存在的绝对flutter.bat路径；首次发现错误不算测试通过。没有使用被自动审批拒绝的后台SSH隧道，最终使用上述安全可复核路径。

下一步按[移动交付流程](../runbooks/mobile-delivery-workflow.md)将已验证增量纳入正式下一版，另核对原生行为、签名和设备实际诊断版本；首次有效摘要到达再记观察起点。AWS后续准备见[资源交接清单](2026-09-27-aws-upgrade-resource-checklist.md)，资源准备不等于批准主区迁移或S3实施。
