# iOS 启动诊断实现及告警调查

## 交付与授权

用户已确认独立未登录诊断方案，代码和审查已完成；API 候选 **d3922296962c41ec2c5b7a921a3ed53fac1138a4fb166e9877afa4ae23cd263b** 已准备，**生产发布尚未批准或执行**。worker15659d6c和schema0090保持，无新迁移。新 iOS 签名包、原生编译与受影响设备上报验收尚未执行；原0.4.7不会自动获得新埋点。本轮未构建或覆盖安装Android包，既有Debug2184保留。

实现覆盖首次await前的初始化、安装核对、诊断salt、Matrix预检/数据库打开/迁移、会话bootstrap和本地恢复。L04/L07包装保留固定分类、预检cause和限定OSStatus；直接fatal分支也报告。观察回调与上报故障不改变已有异常类型、恢复/清理条件或Matrix身份。

报告仅含版本/build、数值系统版本或unknown、随机UUID、分钟时间、固定阶段/边界/分类/预检原因/限定状态和计数。不含用户信息、凭证、原始异常、路径、堆栈、消息或密钥。20事件/32KiB/24h有限离线缓存，首次尝试冻结，HTTP5秒绝对超时与有界退避；诊断不依赖钥匙串或已登录会话。匿名API严格4KiB、额外字段拒绝、先全局120/min后受信代理链解析来源10/min、固定10000 UUID/24h去重。日志与Redis不保证跨系统恰好一次；只读汇总按UUID去重。

## 告警调查

2026-09-27 14:53+08检查 `starchat-refresh-watch.timer` 为enabled/active waiting，service退出0；state中active/announced为空、pending=null、delivery_error=false、failures=0。14:56严格TLS合成无效refresh探针返回预期401/REFRESH_TOKEN_INVALID。

14:08:18记录PROTOCOL_PROBE_FAILED，14:09:20恢复；API容器14:08:16.602启动，探测14:08:16.685开始。时间支持服务切换启动窗口的推断，但watch没有保留失败HTTP状态/异常类别，不能证明唯一根因。提供的事件UUID已不在所检留存记录，无法独立核对UUID。SMTP接受时间不等于收件箱送达，恢复通知不能证明此前告警邮件成功送达。该协议探针没有执行iOS本地会话启动，不能据此认定iOS根因。未重启timer或改监控/发邮件。见[只读调查](artifacts/2026-09-27/ios-startup-alerts/watch-readonly/report.md)。

## 门禁和真实结果

证据统一位于 [任务工件](artifacts/2026-09-27/ios-startup-alerts/)。Windows10/PowerShell7/Python3.12.10，Flutter3.44.9/Dart3.12.2；依赖锁保持。命令、起止与退出码见各stage JSON及专项README。

| 门禁 | 结果与范围 |
| --- | --- |
| 客户端专项 | recorder/spool/transport27PASS；最终启动/预检/login/bootstrap/factory174PASS，真实red/green留存 |
| 最终Flutter全量 | `flutter test --no-pub`：4775PASS、9skip、退出0；15:33:05–15:36:37+08 |
| 最终Flutter分析 | `flutter analyze --no-pub`：No issues、退出0 |
| API/Redis专项 | 最终255PASS、退出0，真实Redis验证过期目标在128批量清理之外及索引缺失仍重新接受 |
| Collector最终增量 | 121PASS、退出0，包含native/category91组合契约一致性 |
| 完整verify原始执行 | 15:24:26–16:01:37+08，退出1；API/worker3041PASS、89skip、1失败；前置policy/template/infra/getui/bot通过 |
| verify失败闭环 | staff CAPTCHA测试全局替换shared Redis.from_url导致新admission拿到不完整模拟对象；仅改成模块内factory替换。staff+startup/旧诊断/OpenAPI269PASS，保留旧失败和Starlette依赖弃用警告，不改运行代码 |
| verify后续阶段 | 退出0：mobile108PASS/1skip、UI33components/476screens一致、import、AST273文件、0090单head/离线SQL、OpenAPI、Compose渲染 |
| 独立审查 | 先[规格/领域PASS](artifacts/2026-09-27/ios-startup-alerts/final-spec-review/closure.md)，后[质量/安全PASS](artifacts/2026-09-27/ios-startup-alerts/final-security-review/closure.md)；各具体发现均有修复证据 |
| Linux候选 | 14项HTTP/双worker/真实Redis通过；真实代理等价链伪造/重复XFF请求10次202、第11次429，只有一个来源计数键 |
| 隔离恢复/回退 | PG16恢复138表数量及身份/旧号归属校验一致；候选与e880只读upgrade head均退出0，schema0090；旧入口鉴权保留 |

原较早Flutter全量因审查修正取消，不作为通过证据。Lua及collector最终增量在完整verify开始后发生，使用255/121最终源码专项补充；未重复36分钟全量。最终Flutter输入未发生后续变化。条件skip与既有StarletteDeprecationWarning如实保留，未抑制或升级依赖。原脚本exit1不改写为exit0。

## 候选与来源

移动基线commit **05a2d950047f96d128fc1115cb7db5bec39db017**，最终[1764文件清单](artifacts/2026-09-27/ios-startup-alerts/frozen-mobile-input.json) SHA256 **ddceb6f40148b10fa4cfd2de494562154e427af24b5c6eb62609f45b4342a7e0**；19项新增/修改，native changes=[]，pubspec.lock **5220715970aa207f7201fbe12b428c30e3e1ef76a0cca7f4bbee3e94f588d68b**。已有全链路性能与网络诊断输入保留，本次启动入口补充其登录前缺口。

候选从当前实际e880镜像构建，仅覆盖4个实际 `/opt/business-api` 文件；1067项及全部478旧installed路径原样保留。实际导入路径已确认，worker、鉴权receiver6033、账户/搜索/性能/钱包路径保留。最终overlay manifest **bcfb253c21ad7ccf57ab7a88f1ec21103c4e4473de2fa47ba93f9301c69b7492**。当前API只绑定回环，明确受信nginx追加实际连接方地址，Uvicorn0.52.4从右侧选首个非受信地址。受信内部代理为特权边界；代理配置变化必须重验，不把ASGI来源称作原始socket peer。

16:06:11+08最新准备核验：APIe880、worker15659、PG/Redis及另外25容器身份/配置保持；严格公网TLS健康200/未授权搜索401。最终候选容器已清理，任务隔离PG停止，备份与恢复数据保留在服务器0700任务目录。继承的UID0及非root迁移访问限制如实记录。详见[候选交接](artifacts/2026-09-27/ios-startup-alerts/server-prepare/PREPARED.md)。

## 发布及后续验收

代码按文件归属与漂移保护回填主目录，见backfill-manifest.json。尚未提交Git或推送远端。生产部署须按app-release-deployment第6条单独批准新API候选；批准后先重读实时镜像/配置漂移，再仅切API，检查健康/旧鉴权/新契约/其他容器。保留e880回退；无schema降级或worker替换。

服务端上线后，新iOS包仍须经同源原生构建、签名交接和分发，在覆盖更新/离线补发/钥匙串受保护等场景验收。需要首条真实受影响设备的闭合元数据，才能进一步定位原0.4.7错误；不承诺未知故障不再发生，也不把匿名上报当自动告警邮件。

精确主动工作/等待分解未完整采集，不能编造总工时；服务器准备观察区间15:26:46–16:06:14+08含并行验证及返工，实际命令计时保存在工件。35项范围内文件及恢复索引已回填核对；服务端单独发布问题已提交，当前等待用户批准。

最终回填21条文档链接无缺失，范围内35文件SHA一致；主目录未领取文件的667项换行差异保持。三项含重复CR的旧文件经仅换行归一化比较无语义变化。索引写入失败未覆盖原文件，采用最小追加patch恢复，最新SG/其他条目保持。一次性回填脚本失败及恢复如实记录，勿再次执行其旧前态。
