# 朋友圈媒体与房间体验修复、iOS 企业重签候选

## 恢复入口

- 用户本次九项要求：异步朋友圈上传/会话同限制、房间通知及角标即时清除、二态日历、无感续页与旧检索、密钥丢失公告管理、公告关闭持久化、多媒体批量转发/选中背景、视频封面、待企业签名 IPA。
- 授权边界：修复与 iOS 候选构建；用户重签回传后再分发。未授权本轮服务候选发布、Android 发布或 TestFlight 上传。
- 状态：待企业签名。实现冻结、主目录回填、Linux/PG/迁移及iOS兼容/原生/签名门禁完成，0.4.20+2189 IPA已核验。API261f/0091发布确认待答复，尚未部署或公开分发。
- 隔离工作树 C:/Users/Administrator/.codex/worktrees/ios-media-room-followup/StarChat，native 工具创建且注册成功；基线 f433381a14d4549b25001059870857d1bfe57a42。
- [设计](../../superpowers/specs/2026-09-28-ios-media-room-followup-design.md)。[执行计划](../../superpowers/plans/2026-09-28-ios-media-room-followup.md)已记录任务/归属，按红绿和双阶段审查执行。
- 主目录 1779 项冻结移动输入：1104 完全相同、672 仅 CRLF/LF、3 项只增加空行，缺失 0。具体见非Git baseline-source-comparison.json；不覆盖主目录其他任务修改。
- 负责人：root 负责通知、转发、共享 lease/API 接线、文档/集成/IPA；并行实施分别朋友圈、历史检索、公告；历史完成后转服务器poster/CAS。各代理只改归属文件，无共享index写。
- 下一步：交付已核验IPA待用户企业重签/回传；收到API261f/0091独立发布批准后执行冻结脚本与fresh guards，随后等最终签名包确认再分发。

## 验收台账

|ID|预期|已确认原因/方案|测试与交付|
|---|---|---|---|
|I01|朋友圈离开发表页后继续、失败可恢复|账号持久队列、最多4pending、1GiB素材、逐项处理|red/green与质量通过；真实OS暂停/恢复待设备验收|
|I02|会话一致的图片/视频限制|共用压缩/transcode，最终20MiB、有界小封面|客户端专项及iOS18.6/26.2真实H264/HEVC封面/编码通过|
|I03|打开房间清通知、即时刷新角标|公开read事件、账号代际/串行通知与badge、精确iOS matcher|实际RoomPage/alias/切号与竞态、原生通知桥通过；UIKit两例实际通过，真实APNs另验|
|I04|仅本机有消息日可点|所有可显示本地源日期与anchor，修订失效刷新|快照/SDK缺行/日期disabled/撤回刷新通过|
|I05|滚动无感续页、旧记录快|复用有界投影、自动续页/短屏/无进展保护|10k/100k实验通过；热查询0重复DB投影，仍O(N)内存匹配，非真机延迟结论|
|I06|缺旧密钥管理员可清除/更改|区分不可读引用、当前joined+state权限、加密重写|专项及独立规格/安全审查通过；未弱化E2EE|
|I07|已关闭公告重进仍隐藏|账号/room/publication共同持久scope|实际RoomPage重新进入与lease撤销断言通过|
|I08|批量媒体转发、持续选中背景|4096描述符/128执行窗口/128MiB准备、稳定txid|200扇出、重试/撤销/echo回收及选中背景通过|
|I09|跨设备朋友圈封面|独立静态小图DTO、可见范围，旧无封面兼容|最终Linux154/PG5/迁移2及既有备份恢复通过；0091发布待独立批准|
|I10|提供待企业签名IPA|0.4.20+2189、e9b5349应用/083041d8工作流、TestFlight关闭|compat/原生/签名全部通过；IPA61246031字节/SHA59fa118c…0073e，待企业重签|

## 阶段计时

|阶段|开始+08|结束|分类/结果|
|---|---|---|---|
|调查|精确首次工具时间未知|持续中|并行只读；第一个可核实clock00:49:59|
|隔离创建|精确开始未知|00:57前已完成|native create_worktree返回注册成功|
|源码基线比较|00:57:15前|00:57:15|1779路径无缺失；3差异复核仅空行|
|iOS预检|调查并行|持续中|远端workflow较本地新；纯Swift门禁含UIKit问题待修复|

首次精确起点未知；并行区间不简单相加。当前没有新 IPA、Debug 安装、生产服务或更新弹窗变更。用户各问题实际平台/build 尚未提供，不能假设全部来自公开2173或Android2188。

## 证据与交接

证据仅放 docs/verification/artifacts/2026-09-28/ios-media-room-followup。敏感会话、用户消息、密钥与原始媒体不入日志。保留此前全链路性能诊断；attempts 不等于用户数。iOS 预检不能代表 Xcode 或真机通过；拿到最终签名包前不切分发。

## 基线预检

Flutter3.44.9/Dart3.12.2可用，C盘约143GB可用；无.env。隔离工作树依赖首次pub get继承系统镜像域导致lock中三个包补丁版漂移（image_picker_ios、octo_image、permission_handler_apple），首次45项绿色只代表该漂移输入，不复用为固定候选证据。保留漂移lock及真实差异，恢复本任务原lock，显式PUB_HOSTED_URL=https://pub.dev并pub get --enforce-lockfile exit0，固定输入四文件基线45项通过、exit0（baseline-focused-locked.log/json），仅证明基线可运行，不能称新修复已通过。未升级/提交依赖，后续Flutter命令应保持该host及lock约束。iOS只读预检记录位于ios-preflight/report.md，未触发CI或取签名资料。

## 实施进展（2026-09-28 03:20 +08 左右）

- 已批准方案持续实施，尚无候选构建/发布。保留固定依赖锁，Flutter测试串行窗口。
- 历史检索专项55项通过、16文件analyze无问题；room_page补丁已用ignore-whitespace顺序应用。后来新增无进展游标测试待最终门禁。100k热查询无重复DB投影，但仍内存O(N)扫描约57–61ms；非手机实测。
- 朋友圈首轮新15项通过；analyze新增info待修正。新小poster取图有界，旧无poster不整视频下载。服务器新poster/CAS专项真实red 15失败/1通过，最小实现中。
- 通知真实首红证明进入房间未cancel；第一次green遇Dart接口promotion编译失败已修，新增竞态/换号测试待运行。原生精确room_id/event_id匹配不会清其他房间或call_id通知，待Mac原生门禁。UIKit导航tests已独立文件，纯Swift门禁仍保留导航测试于iOS target。
- 公告5项真正red已复现；真实RoomPage持久化/lease撤销用例fixture失败与中断均不计red。待有效red后接scope及生命周期guard。
- 只读生产设置：Android0.4.19+2188，iOS0.4.7+2173；实际API e3043e9a9e8f、worker a5087d4724a3、schema0090，不能再复用旧worker15659d6c假设。工作树兼容迁移0088–0090已复制/hash核对。
- 预留iOS0.4.20+2189：注册工作树最大2188、远端默认pubspec2179，本次生产最高2188；保留remote新版两个workflow原生门禁，添加自身branch与性能监控define，尚未push/触发。见build-reservation.json。
- 下一步：完成公告真实red/green、通知/转发/选中red/green、serverposter/CAS与契约迁移验证；两阶段独立审查、冻结共享门禁后iOS候选构建。新服务候选单独授权后才发布，不阻止独立IPA准备。

## 集成进展（2026-09-28 03:55 +08 左右）

- 公告80项默认专项通过，诊断开启9项通过；实际RoomPage scope重新进入与lease撤销已验证。独立公告规格审查待收尾。
- 独立房间规格审查发现并修补两项：200目标扇出曾整体触及128待执行上限，现冻结描述符有界4096、执行窗口仍128、原128MiB准备预算/稳定txid保持；打开calendar后撤回/解密失效监听此前缺失，已新增revision公开监听/150ms合并刷新。两项新增真实红已保留；首轮集成78项通过，2项旧calendar错误提示期望正更新为重算本地日期。
- 通知新增竞态/换号3项通过；旧widget teardown因root/fake异步队列死锁，已使用限定4轮交替drain的fixture，真实dispose代码未削弱。单文件14项通过，真实RoomPage/保留源alias路径验证进行中。
- 朋友圈后台退出测试重新通过，队列/小封面数据层16项通过；遗留Windows测试装置路径/cache失败仍在定位，不能称全绿。新服务专项45项、契约check通过。
- 服务端实际PG16备份3.03s、隔离恢复8.25s、0090→0091升级10.34s、四例PG并发PASS、旧业务兼容回退启动/ORM PASS；六文件live-base最小overlay已构建，不部署历史整树。回退需携带仅0091迁移文件以识别扩展head，保留字段不降库。API/worker生产identity保持。
- iOS0.4.20+2189两源bump与版本契约2项通过。Windows无Xcode，仍待最终freeze和macOS门禁/IPA；尚未push触发CI。
- verify.ps1已环境预检后启动；仅本任务.env.example样例副本用于RenderOnly，没有生产凭据。Python3.12与锁定依赖可用，全量业务门禁运行中。测试阶段结果分别记录，不将attempts或总用例数当用户数。
- HTML新增七态、300项前端测试及32组件/410页面契约通过；浏览器已检查日期disabled/点击、多选持久背景、重试及小封面预览。修正日历周偏移与失败队列仍显示已缓存timeline；最后源码前端复核待收尾。Figma同步已退休。
- 下一步：关闭源规格发现与最后测试失败，独立质量/安全审查，最终共享Flutter/analyze/平台门禁，冻结后推送本任务候选分支构建IPA。服务新候选单独请求发布授权，用户回传企业签名包后再分发。

## 最终复核（2026-09-28 04:40 +08 左右）

- 规格审查房间、公告、朋友圈与 iOS 静态源全部通过。独立质量复核两项房间竞态：撤回后旧搜索正文保留、旧账号异步取消继续派发新原生清理，已真实 red 后最小修复；相关八文件77项通过。短旧式列表已穷尽不额外查询，显式 batch continuation 保持；八项收据测试补真实账号绑定 fixture，实际 RoomPage 切号拒绝断言保持。
- 独立朋友圈质量发现迟到 GET 覆盖编辑/串账号、入队复制后才冻结 revision，三个真实失败已复现并修复；含旧本地草稿、封面、视频、手机号客户端的七文件64项通过。最终四条 braces analyzer info 正闭合，尚不能称全量最终通过。
- 前一全量 Flutter 实际结果4907通过/9跳过/14失败：3项生成契约漂移、1项旧 calendar 静态断言、8项测试未绑定账号、2项短列表额外自动续页。各原因及修复专项证据保留；不把原 exit1 改写成功。最终全量等待 analyzer 修正后重跑。
- `verify.ps1` 真实执行：业务/worker2845通过/79跳过/1契约失败，之前仓库/部署/模板/infra/getui/bot门禁通过；中途最小CAS源码变化的受影响闭环独立记录。全量OpenAPI exporter失败在隔离 f433 基线复现：非朋友圈15路径/26schema漂移与本次生成完全相同，identity源未变。恢复原基线契约，只并入5朋友圈路径/5schema；此范围生成比对与独立复核通过，不能声明全仓 exporter 通过。
- 最终移动Python边界123通过/1跳过、HTML300通过、32组件410页面、AST262文件、Compose render及diff检查通过。UI count旧403两失败已随本次七新态更正至410，不弱化registry漂移检查。
- 服务器20:10:35Z实际live/ready200；RAM available150MiB、swap满、高load，随后SSH读检查timeout255。本任务只限制自身旧runner/hostpytest，未改生产或其他任务；最后95%进度不代表Linux通过。最终镜像构建状态、Linux、PG5需恢复读回或独立CI，未发候选发布请求。Linux源验证不替代live镜像overlay及真实备份恢复身份。
- 下一可执行步骤：final analyzer→full Flutter；冻结源/独立质量闭合→推送本任务branch触发Mac iOS18/26、UIKit/纯Swift、完整签名候选和隔离Linux/PG5；取确切IPA版本/大小/SHA交企业重签。没有TestFlight或公开分发操作。

## 候选冻结（2026-09-28 04:45 +08 左右）

最终analyzer exit0。第二次full Flutter实际4926通过/9跳过/1旧UI调用数断言失败；实现未改，仅该test把50+1后多余空页期望3改为2，关联两文件18通过/exit0闭合，复用不变实现全量证据。三模块与iOS构建准备独立质量闭合PASS。Linux workflow固定版本/无生产访问静态复核PASS。准备唯一根代理stage/commit/push本任务branch；具体结果写[交付验证记录](../../verification/2026-09-28-ios-media-room-followup.md)。本地额外CAS运行曾漏PYTHONPATH错误导入main，5失败保留；显式本工作树导入预检后6通过/exit0，不误算candidate失败或red。

## CI 构建（精确创建 2026-09-28 04:47:27 +08）

- 源码commit `e9b5349cc81fff29f90cf50d4596c35128030a7f` 已推送独立branch，94文件freeze/依赖锁/凭据扫描独立复核通过；工作树仅无行为差异的visibility换行已恢复。
- [签名候选36349326466](https://github.com/SuperJJ2333/StarChat/actions/runs/36349326466) 与 [iOS18/26完整兼容36349326541](https://github.com/SuperJJ2333/StarChat/actions/runs/36349326541) 同源运行中。签名job须前置native通过，交付还须独立compat两矩阵及完整生产compile通过。
- 首Linux [36349326488](https://github.com/SuperJJ2333/StarChat/actions/runs/36349326488) 实际153通过1失败/175.85s；旧fixture默认写/data导致非root CI PermissionError，PG5/expand被前序阻止未执行。正将BUSINESS_AVATAR_STORAGE_ROOT设本run临时目录，仅workflow窄修；不改业务权限或跳过失败。
- 服务器恢复后最终候选image261f六输入实际hash与冻结源一致，生产e304/a508保持；任务PG无dependents已停止，backup/data/log保留。旧Linux151通过的hostexitmissing和旧源限制保留；最终CI不得冒用该结果。

## 主目录原调查快照（历史记录）

以下内容保留原始授权与调查事实；其中待确认/未实现等状态只代表实施前快照，当前状态以上文候选门禁为准。

# 朋友圈媒体与房间体验修复、iOS 企业重签候选

## 恢复入口

- 用户本次九项要求：异步朋友圈上传/会话同限制、房间通知及角标即时清除、二态日历、无感续页与旧检索、密钥丢失公告管理、公告关闭持久化、多媒体批量转发/选中背景、视频封面、待企业签名 IPA。
- 授权边界：修复与 iOS 候选构建；用户重签回传后再分发。未授权本轮服务候选发布、Android 发布或 TestFlight 上传。
- 状态：只读调查完成主要路径；新增异步队列/封面行为设计待确认。未实施、未构建、未发布。
- 隔离工作树 C:/Users/Administrator/.codex/worktrees/ios-media-room-followup/StarChat，native 工具创建且注册成功；基线 f433381a14d4549b25001059870857d1bfe57a42。
- [设计](../../superpowers/specs/2026-09-28-ios-media-room-followup-design.md)。批准后编写执行计划并声明编辑文件归属。
- 主目录 1779 项冻结移动输入：1104 完全相同、672 仅 CRLF/LF、3 项只增加空行，缺失 0。具体见非Git baseline-source-comparison.json；不覆盖主目录其他任务修改。
- 负责人：root 负责通知、转发、共享 lease/API 接线、文档/集成/IPA；并行调查分别朋友圈、历史检索、公告，均仅只读。
- 下一步：用户确认新增行为方案及封面取舍后执行。iOS 构建预检继续独立核对，不触发云构建或发布。

## 验收台账

|ID|预期|已确认原因/方案|测试与交付|
|---|---|---|---|
|I01|朋友圈离开发表页后继续、失败可恢复|页面持有 upload/mounted/busy；改账号任务队列|待 red/green|
|I02|会话一致的图片/视频限制|现有朋友圈原视频20MiB直接拒绝，先全读原件|待准备接口联测|
|I03|打开房间清通知、即时刷新角标|缺读状态触发；iOS远端须精确room_id匹配|待两端原生/竞态验证|
|I04|仅本机有消息日可点|unknown可点及远端两探测不能覆盖整月|待本地快照/anchor验证|
|I05|滚动无感续页、旧记录快|按钮与短列表死角；每关键词重新O(N)投影|待10k/100k实验|
|I06|缺旧密钥管理员可清除/更改|确认epoch被无关sync取消；失效引用分类不完整|待权限/E2EE审查|
|I07|已关闭公告重进仍隐藏|真实lease wrapper没有持久scope|待真实接线失败用例|
|I08|批量媒体转发、持续选中背景|元数据误计完整附件内存；仅圆圈选中|待有界调度/幂等用例|
|I09|跨设备朋友圈封面|只有上传者本地poster；远端无封面DTO|等待用户小封面接口/整视频抽帧取舍|
|I10|提供待企业签名IPA|Windows无Xcode；已有GitHub macOS仅构建能力|待修复、冻结、原生门禁与构建|

## 阶段计时

|阶段|开始+08|结束|分类/结果|
|---|---|---|---|
|调查|精确首次工具时间未知|持续中|并行只读；第一个可核实clock00:49:59|
|隔离创建|精确开始未知|00:57前已完成|native create_worktree返回注册成功|
|源码基线比较|00:57:15前|00:57:15|1779路径无缺失；3差异复核仅空行|
|iOS预检|调查并行|持续中|远端workflow较本地新；纯Swift门禁含UIKit问题待修复|

首次精确起点未知；并行区间不简单相加。当前没有新 IPA、Debug 安装、生产服务或更新弹窗变更。用户各问题实际平台/build 尚未提供，不能假设全部来自公开2173或Android2188。

## 证据与交接

证据仅放 docs/verification/artifacts/2026-09-28/ios-media-room-followup。敏感会话、用户消息、密钥与原始媒体不入日志。保留此前全链路性能诊断；attempts 不等于用户数。iOS 预检不能代表 Xcode 或真机通过；拿到最终签名包前不切分发。

## 基线预检

Flutter3.44.9/Dart3.12.2可用，C盘约143GB可用；无.env。隔离工作树依赖首次pub get继承系统镜像域导致lock中三个包补丁版漂移（image_picker_ios、octo_image、permission_handler_apple），首次45项绿色只代表该漂移输入，不复用为固定候选证据。保留漂移lock及真实差异，恢复本任务原lock，显式PUB_HOSTED_URL=https://pub.dev并pub get --enforce-lockfile exit0，固定输入四文件基线45项通过、exit0（baseline-focused-locked.log/json），仅证明基线可运行，不能称新修复已通过。未升级/提交依赖，后续Flutter命令应保持该host及lock约束。iOS只读预检记录位于ios-preflight/report.md，未触发CI或取签名资料。

## 原生预检通过、签名构建与发布确认（2026-09-28 05:55 +08 左右）

- 签名运行36351498193/source083041d8，simulator-preflight job108711034572已成功。SQLCipher4/Keychain1/原生通知1实际通过，真实UIKit xcodebuild于21:51:35Z报告TEST SUCCEEDED；具体两测试执行结果独立核验中。build job108715881218已启动，尚无IPA，TestFlight入口关闭。
- API261f/0091候选与本地发布脚本完成规格→质量安全复核，0P1/0待处理P2；Linux154/PG5/迁移2及实际生产备份隔离恢复证据已齐。已发送独立服务发布确认，尚未收到答复。脚本仅本地准备，未上传或执行生产变更；最后只读现场仍e304/a508、schema0090。
- 下一步：取得同源签名job实际成功及IPA_SHA256，下载并核验artifact摘要/IPA内容与资产后提供待企业重签包。服务发布仅在本轮明确批准后执行已冻结脚本；用户重签回传后另行核验与分发。

## IPA 已交付待企业重签（2026-09-28 06:05 +08 左右）

- 同源签名运行[36351498193](https://github.com/SuperJJ2333/StarChat/actions/runs/36351498193)，精确源083041d86bf2db8541a601689e1ef69e57748aa6，21:22:36Z创建、22:02:22Z完成更新，结论success；build job108715881218成功。应用源码仍e9b5349，后续只CI/文档改变，兼容证据按已核输入复用。
- 原生预检两条UIKit导航测试真实执行通过；SQLCipher4/Keychain1/通知1通过。签名job实际Swift31测试零失败（通知2/安全会话20/通话9），push门禁通过。CI实际codesign --deep --strict、生产APNs/application-identifier、无get-task-allow、SQLCipher加载顺序/完整插件/资源SHA/版本/iPad/后台模式验证通过。TestFlight步骤明确skipped，临时签名凭据清理success。
- 下载artifact10943003558，ZIP60,866,129字节，SHA256 0f27f236a90aeb2f941ef03b2bca29d697201ebec8f1a5ed8698c05d7b98a8b8与GitHub digest完全一致；未下载证书、密钥或描述文件工件。安全复制IPA后核验内容，只有通过后才原子产生交付文件。
- IPA0.4.20+2189，Bundle ID com.liuhetong.liuhetongMobile，最低iOS16.0，大小61,246,031字节，SHA256 59fa118c8ec1890dd4f6fff15c97c9b6de7693d5bb4245619de874258ea0073e，与Mac实际输出完全一致。statistics资源SHA89eab23270dc87ce6fd07715d9abb2606455d94ce1fc16cd56d2deeaeeafb9d5与冻结源相同。Windows本地只验证摘要与内容，不冒称本地codesign。
- 已将校验后的IPA复制到主目录[待企业重签IPA](../../verification/artifacts/2026-09-28/ios-media-room-followup/ios-ipa/畅聊_iOS_0.4.20_2189_待企业重签.ipa)，副本SHA完全一致；构建期签名不是用户最终企业签名。用户重签回传后再确认最终包身份/大小并准备分发。真机APNs角标、实际锁屏和OS终止后恢复仍需设备反馈。
- API261f/0091独立发布确认仍待答复，尚未上传/执行发布脚本。本次未部署新API、改Android/公开iOS分发或发送更新弹窗；新封面服务需批准后上线。旧服务兼容客户端，未宣称跨设备新封面已经在生产生效。
- 已停止本任务4192 HTML临时预览进程（95100，Ctrl-C退出），不清理其他任务资源或工作树。待执行：交付IPA给用户企业重签；收到独立服务批准后使用冻结脚本/fresh guards部署API261f/0091；收到重签包后进入轻量分发流程。
