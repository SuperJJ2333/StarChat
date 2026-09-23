# Debug2164与群主转让服务器修复

状态：生产转让修复已上线；Mi6 0.4.5+2164 Debug已保留数据安装并启动。候选基线e8bf1440，隔离路径`.worktrees/debug-feedback-2164`。仅集成本次35份源码/测试/契约文件，保留主工作区其他房间/搜索修改；构建承接2163已验证优化覆盖，来源由不可变输入清单绑定。

## 验收台账

| 项目 | 实现与证据 | 发布/设备 |
| --- | --- | --- |
| 验证码品牌 | 按用户最终澄清，仅APP登录/验证/换绑提示加“畅聊 ChatFlow”，不解释短信签名；没有可用自定义审核模板，未修改供应商短信正文；auth86通过 | 已安装2164，用户效果待复验 |
| 群主转让 | 旧群首次查询按权威登记；业务404不再误报缺接口；任期未知保持NULL。70后端+3真实Synapse+PG并发+30Flutter，独立规格后安全审查通过 | API/worker均已开启，实际Settings读回true |
| 图片公告 | 待解密不再报格式错误；密钥到账与图片失败自动恢复。38专项、3态HTML验证通过，E2EE/严格格式检查保留 | 2164已安装，原群由用户复验 |
| 钱包 | 账号/epoch持久显示缓存、冷启动先显示/后台更新、30秒暖进入去重；旧QR不授权付款，余额写前重新取权威；记录复用全部账单行和时间格式 | 2164已安装，冷启动/弱网效果待用户复验 |

## 验证与返修

- 前端298通过；32组件401屏契约通过；HTML钱包筛选/颜色/行布局真实浏览器确认，候选地址http://127.0.0.1:8156/index.html?screen=wallet-history-all。
- 首轮Flutter3931通过/1失败（账号重登金额），启动后共享代码还在完成最后安全补丁，混合编译输入不能作发布证据。冻结后重跑3932通过、analyze0。原失败保留于debug-feedback-2164/flutter-full.log，成功于flutter-final.log。
- 独立钱包审查发现并关闭：同State换scope、惰性epoch采样、异步初始化退出后监听、页面闭包被共享store持有、旧scope网关使用新账号、实际订单状态映射。固定输入13专项及4用例复验通过。
- 后续补充已复现的汇率恢复：首次失败后点击刷新没有再次请求。该小增量红fxCalls期望2实际1，修复后相关17通过；root重新运行整个wallet/finance-entry/ledger受影响167通过，独立复审通过，analyze0。手动刷新仅绕过客户端30秒窗口，服务端60分钟策略不变。全量未覆盖最后两文件变更，采用3932全量＋最终167影响回归的证据组合，不把新测试计入旧全量数量。
- 完整verify原轮后端2706通过/68条件跳过（1894.88秒），移动边界因两条旧398屏断言失败而exit1。新增公告三态后计数401已修正，按影响复跑移动108通过/1跳过及全部后续门禁；迁移唯一0087、UI契约32/401、API import/AST/OpenAPI/Compose全部通过，续跑脚本exit0。未重复已通过且未改变的后端，也不把原verify退出码改称0。

## 生产准备

基底API ba801c6c26822d62134ce9333c870b5fc61192c657937a88029c050b26ed1e8b，worker07019a1b76d1b4780ee911580be03ecdbd8a570b9db2a78eb15c42a544c183ba；两角色只覆盖api/groups.py与modules/groups/transfer_coordination.py，唯一额外配置变化BUSINESS_GROUP_TRANSFER_COORDINATION_ENABLED=true。保留既有诊断及客服直接结算代码；schema0087，无新迁移。

0700远端发布目录/opt/starchat/releases/debug-feedback-transfer-20260923；完整335项源码身份、备份隔离PG恢复、迁移前后原行原列摘要已通过。候选API38cf79c517675e26a1407ea6cfd6cdbec3d96a215178e3ad9c17ddbe4eb34f91，worker85620b2cf0ddd4d94ca510bd1fffaf0d85bdefd45eac5cdf56494ab14985ea50。当前只读注册群1、权威一致1、任期NULL1、满10人0、历史转让意图0；不输出身份资料。启用前重新检查运行基线。

回退命令：python3 /opt/starchat/releases/debug-feedback-transfer-20260923/release.py rollback；恢复先前镜像/配置，保留意图、注册表和审计。未知任期且满10人的旧群仍需管理员凭真实接任证据补录；不伪造30天，不直接改生产群权限。

## APK与边界

0.4.5+2164 Debug，arm64，固定75b31c…ba61fff签名及完整Apktool重建检查。安装前2163设备SHA与上一最终包一致；安装后首次安装时间2026-09-20 09:35:24保持不变。

不将本地测试等同原群公告/低端机交互或真实资金验收，不发送测试短信、不代用户发红包或充值。钱包历史当前最近50条，筛选只含已加载内容；当前生产单BusinessApiClient生命周期通过scope/epoch换绑，不声明支持任意多实例同scope/epoch注入。

详见[转让](2026-09-23-debug-feedback-transfer.md)、[公告](2026-09-23-announcement-decryption.md)、[钱包](2026-09-23-wallet-warm-cache.md)。具体主动执行分拆未知；命令自身时长与时间戳保留，不累加并行时长。

20:43前后启动2164源码构建；冻结1513+前端测试输入与依赖身份通过，锁文件仅源镜像URL差异，无依赖版本/内容差异。

## 已安装Android

20:49:53+08读回Mi6 0.4.5+2164 Debug；install-r保留数据，首次安装时间2026-09-20 09:35:24不变，启动Status ok/进程在运行。APK cbd4e177dd1962efda3efbfd796a2b82dbb9bb0fc1fab7ec2600e615318f0c18，145445163字节；固定证书75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。源码构建218.9秒；完整重建与独立读回27317类、339库/资产一致、清单语义相同，DEX/资源确已重建，zipalign/apksigner通过。未对用户账号执行金融操作。

## 已上线与最终验收

20:56:27+08前完成：真实运行API 38cf79c517675e26a1407ea6cfd6cdbec3d96a215178e3ad9c17ddbe4eb34f91、worker85620b2cf0ddd4d94ca510bd1fffaf0d85bdefd45eac5cdf56494ab14985ea50；两者Settings协调true，healthy、restart0、无新异常。335源身份逐角色一致，22其他容器ID/启动时间未变；schema0087，无生产数据库迁移及静态后台覆盖。备份隔离恢复136表218320行、原行原列摘要一致。

服务器与工作站经既有jumper分别HTTPS健康200、未授权转让查询与钱包/后台接口401、空客服登录422；均保留TLS校验。未执行生产群转让、未代用户发短信或处理资金。临时19048 SOCKS已关闭；8156 HTML预览保留。

应用输入冻结见[清单](artifacts/2026-09-23/debug-feedback-2164/frozen-inputs.json)，构建后逐项复核无漂移；完整Flutter3932与最后FX167影响回归组合覆盖最终输入。最后仅修UI计数测试，不改变APK业务源码。应用最终[APK](artifacts/2026-09-23/debug-feedback-2164/final.apk)、[设备读回](artifacts/2026-09-23/debug-feedback-2164/device-readback.json)、[生产结果](artifacts/2026-09-23/debug-feedback-release/verified.json)、[运行开关](artifacts/2026-09-23/debug-feedback-release/live-flags.json)。

异常保留：首轮Flutter混合输入失败；verify旧screen count两失败；生产准备host没有python命令改python3后通过；构建既有Kotlin/Java弃用与unchecked提示未冒称零warning。此次不发布iOS/官网分发/Android正式升级设置，也未把主目录未验room/search增量带入2164。下一步由用户复验原群图片公告、群管理转让、钱包弱网返回/冷启动；仅针对具体反馈继续定位，不重复已完成门禁。
