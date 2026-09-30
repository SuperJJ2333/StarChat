# 朋友圈与房间媒体修复 / iOS 2189 候选

用户已批准推荐方案。候选版本 `0.4.20+2189`，工作树 `ios-media-room-followup`；企业重签后由用户回传，再进入分发阶段。本记录不授权 API 发布。

## 已实现

- 朋友圈按账号持久化发布队列，离开编辑页继续准备/上传；操作系统暂停或终止后下次启动恢复。复用会话图片与视频处理及最终20MiB限制，队列有界。每次 HTTP 使用捕获会话，正文/素材/草稿清理代际在入队IO前冻结。
- 进入房间主动清对应通知与角标，保留其他房间/来电；账号切换阻止旧任务派发下一阶段原生清理。
- 本地全消息投影复用，日期只有可点击的有消息与不可点击的无消息；查询未完成/失败整体处理。搜索自动续页，无正常“查看更多”；撤回/隐藏/解密修订立即清旧结果并重查。
- 管理员在缺旧公告密钥时可删除引用或重新加密发布，权限不放宽；关闭按账号、房间与公告版本持久保存。
- 转发冻结元数据最多4096项、执行窗口128项、保留128MiB素材准备预算和稳定交易ID；部分失败只重试未成功目标。多选气泡持续背景高亮。
- 新视频使用独立有界小封面。旧视频仅从已有本地缓存抽帧，不为封面静默下载完整远端视频。新服务上线前保持旧视频兼容。
- 保留现有全链路诊断，签名候选显式开启性能指标；不上传消息正文、附件内容或凭证。

## 构建前证据

证据根目录：`artifacts/2026-09-28/ios-media-room-followup/`。

|门禁|实际结果|
|---|---|
|最终 Flutter analyzer|无问题、exit0|
|最终全量 Flutter|4926通过/9跳过/1旧UI调用数断言失败、exit1；只将最终短页不再多请求空页的期望3改2，实现未变；对应两文件18通过/exit0闭合。按变更影响复用其余不变输入，不冒称原全量exit0。|
|房间质量修复专项|三真实red；八文件77通过/exit0|
|朋友圈质量修复专项|三真实red；含既有草稿、视频、封面与手机号客户端的七文件64通过/exit0|
|HTML/移动契约|HTML300通过；mobile123通过/1跳过；UI32组件410页面通过|
|仓库verify.ps1|仓库/部署/模板/infra/getui/bot通过；business/worker2845通过79跳过1全量OpenAPI失败。该漂移在隔离f433基线真实复现，非朋友圈生成路径/schema与本次完全相同；不改认证行为或弱化断言。|
|新API契约|只合并5朋友圈路径/5schema，所有非朋友圈基线契约保留；范围生成比对与独立复核通过。|
|最后本地CAS|显式预检导入本工作树后6通过/exit0；此前遗漏PYTHONPATH的额外运行错误导入main返回旧404，5失败保留，不能混入候选结果。|
|规格→质量|房间、公告、朋友圈客户端/服务端、iOS静态准备与Linux workflow独立审查通过；实际Mac/Linux CI仍独立。|

## 服务候选

API候选 `261f0425ba69581357038e86e3804be6a596fed8c81af386ab58daa82dc1c07a`，仅六文件覆盖实际live API；0091为可保留列的扩展迁移。既有PG16备份/隔离恢复/0090→0091与兼容回退证据保留。服务器测试期一度内存/SSH响应异常，停止追加负载；最终Linux/CAS6/PG5转独立Ubuntu CI。生产API仍e304、worker仍a508，未部署。本轮发布需新候选单独授权。

## 待完成

同源Mac原生、iOS18/26兼容、完整编译、签名及包内容门禁已完成，IPA已提供待企业重签；企业签名身份、Keychain关系及实际设备验收待重签回传。API261f/0091仍待独立发布批准。

## CI 与主目录回填（2026-09-28 05:12 +08 左右）

- 移动/服务源码冻结 `e9b5349cc81fff29f90cf50d4596c35128030a7f`。后续 `5c922a80`、`de912b77`、`bc222e36` 只修正 CI 或更新任务文档，移动/服务执行源码未变。
- 最终 Linux [36350245275](https://github.com/SuperJJ2333/StarChat/actions/runs/36350245275)，创建21:02:51Z、完成更新21:06:49Z，实际154通过、PG5通过、迁移2通过、六命名CAS子集无跳过。产物与镜像输入最终核验独立记于候选报告；未部署。前两运行的POSIX路径失败与workflow验证失败保留，不算通过。
- 首签名 [36349326466](https://github.com/SuperJJ2333/StarChat/actions/runs/36349326466) 中 SQLCipher4、Keychain1、通知原生1通过；随后新增 UIKit 门禁构建因已删除的 Flutter 临时listener入口失败，exit65，导航断言未执行，IPA job未执行。通过SDK调用链确认并用config-only恢复两个generated配置，未跳过测试。独立审查与YAML/全部6嵌入Python AST通过；根首次AST计数预期5误写导致exit1，计数修正后exit0，工作流源码未受该本地检查影响。
- 修正签名 [36350639685](https://github.com/SuperJJ2333/StarChat/actions/runs/36350639685) 于21:09:05Z创建，精确CI提交 `bc222e36e228092390b75fe9412cae287637b94d`；实际Mac结果及成品仍待核验。完整生产编译已在兼容 [36349326541](https://github.com/SuperJJ2333/StarChat/actions/runs/36349326541) 通过，两OS原生/新进程保留历史仍运行中。
- 主目录已按原文件rawSHA、冻结候选或独立审查合并SHA逐项守卫：84项回填、10项保留不写；其他任务不覆盖，Git index未操作。main-backfill-applied.json保留精确清单及旧文件。主目录现有476态加7态=483、33组件；IPA分支demo为410/32，各自范围清楚。主目录前端374通过、迁移/动态UI三文件18通过/exit0。默认python3.11预检发现后改明确py -3.12；实际导入主目录app路径通过，未用错误解释器运行门禁。

## 原生门禁入口修正（2026-09-28 05:23 +08 左右）

独立检查发现 `lib/main.dart→AppHome→scan_qr_page.dart` 依赖扫码包，原模拟器harness为MLKit arm64限制移除了该包。因此直接恢复libmain会与harness依赖不一致；这是静态确定的配置风险，不虚构成已运行失败。`bc222` 运行主动取消且不算通过。修正为job持久临时目录内最小Flutter widgets host，确保XCTest宿主保持入口可用；两generated目标断言保留。原三Flutter native集成、真实Runner/Swift/UIKit测试保留，完整生产编译与签名job继续完整依赖/libmain。SDK kernel使用项目package_config和明确absolute target，独立评估/YAML/全部7Python AST通过。

新提交 `083041d86bf2db8541a601689e1ef69e57748aa6`，workflow rawSHA `c5425ce55119d859fc558a34e2f7de68e5c19551e6b119498319527152a5c2d7`；[签名36351498193](https://github.com/SuperJJ2333/StarChat/actions/runs/36351498193)，创建21:22:36Z。应用与compatibility workflow相对e9b内容不变，复用全部已验证compat证据。主目录该workflow单独从已回填bc222 SHA守卫更新，原首次84/10清单不改写。

兼容运行36349326541全部三job成功：真实iOS18.6/Xcode16.4及iOS26.2/Xcode26.3各seed22/verify3，H264/HEVC封面/编码/播放和新进程加密历史保留通过；生产完整原生编译成功。三小artifact SHA与源身份均验证，见ios-compat-ci/report.md。不将模拟器结果当企业签名安装或真实APNs时序验收。

## 原生预检通过、签名构建与发布确认（2026-09-28 05:55 +08 左右）

- 签名运行36351498193/source083041d8，simulator-preflight job108711034572已成功。SQLCipher4/Keychain1/原生通知1实际通过，真实UIKit xcodebuild于21:51:35Z报告TEST SUCCEEDED；具体两测试执行结果独立核验中。build job108715881218已启动，尚无IPA，TestFlight入口关闭。
- API261f/0091候选与本地发布脚本完成规格→质量安全复核，0P1/0待处理P2；Linux154/PG5/迁移2及实际生产备份隔离恢复证据已齐。已发送独立服务发布确认，尚未收到答复。脚本仅本地准备，未上传或执行生产变更；最后只读现场仍e304/a508、schema0090。
- 下一步：取得同源签名job实际成功及IPA_SHA256，下载并核验artifact摘要/IPA内容与资产后提供待企业重签包。服务发布仅在本轮明确批准后执行已冻结脚本；用户重签回传后另行核验与分发。

## IPA 已交付待企业重签（2026-09-28 06:05 +08 左右）

- 同源签名运行[36351498193](https://github.com/SuperJJ2333/StarChat/actions/runs/36351498193)，精确源083041d86bf2db8541a601689e1ef69e57748aa6，21:22:36Z创建、22:02:22Z完成更新，结论success；build job108715881218成功。应用源码仍e9b5349，后续只CI/文档改变，兼容证据按已核输入复用。
- 原生预检两条UIKit导航测试真实执行通过；SQLCipher4/Keychain1/通知1通过。签名job实际Swift31测试零失败（通知2/安全会话20/通话9），push门禁通过。CI实际codesign --deep --strict、生产APNs/application-identifier、无get-task-allow、SQLCipher加载顺序/完整插件/资源SHA/版本/iPad/后台模式验证通过。TestFlight步骤明确skipped，临时签名凭据清理success。
- 下载artifact10943003558，ZIP60,866,129字节，SHA256 0f27f236a90aeb2f941ef03b2bca29d697201ebec8f1a5ed8698c05d7b98a8b8与GitHub digest完全一致；未下载证书、密钥或描述文件工件。安全复制IPA后核验内容，只有通过后才原子产生交付文件。
- IPA0.4.20+2189，Bundle ID com.liuhetong.liuhetongMobile，最低iOS16.0，大小61,246,031字节，SHA256 59fa118c8ec1890dd4f6fff15c97c9b6de7693d5bb4245619de874258ea0073e，与Mac实际输出完全一致。statistics资源SHA89eab23270dc87ce6fd07715d9abb2606455d94ce1fc16cd56d2deeaeeafb9d5与冻结源相同。Windows本地只验证摘要与内容，不冒称本地codesign。
- 已将校验后的IPA复制到主目录[待企业重签IPA](artifacts/2026-09-28/ios-media-room-followup/ios-ipa/畅聊_iOS_0.4.20_2189_待企业重签.ipa)，副本SHA完全一致；构建期签名不是用户最终企业签名。用户重签回传后再确认最终包身份/大小并准备分发。真机APNs角标、实际锁屏和OS终止后恢复仍需设备反馈。
- API261f/0091独立发布确认仍待答复，尚未上传/执行发布脚本。本次未部署新API、改Android/公开iOS分发或发送更新弹窗；新封面服务需批准后上线。旧服务兼容客户端，未宣称跨设备新封面已经在生产生效。
- 已停止本任务4192 HTML临时预览进程（95100，Ctrl-C退出），不清理其他任务资源或工作树。待执行：交付IPA给用户企业重签；收到独立服务批准后使用冻结脚本/fresh guards部署API261f/0091；收到重签包后进入轻量分发流程。
