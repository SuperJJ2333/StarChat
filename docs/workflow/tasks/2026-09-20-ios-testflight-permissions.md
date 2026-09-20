# iOS TestFlight 权限修复测试包

用户授权权限修复、TestFlight构建与测试分发，明确不用企业签名。计划：[执行计划](../../superpowers/plans/2026-09-20-ios-testflight-permissions.md)。
工作树.worktrees/ios-reboot-session，分支codex/ios-testflight-permissions-20260920，整合基线56480ba2。2026-09-20 23:12+08继续执行；此前精确启动时间未知。
已确认GitHub签名及ASC秘密名称存在；最近ios-testflight运行35509514613是Flutter checks失败，签名上传未执行。现有工作流另有profile来源错误，准备复用已成功的ios-0353签名实现。
下一步：权限TDD、签名/ASC预检、测试、构建上传。当前无新IPA或TestFlight安装成功证据。

## 23:31 +08 候选冻结
源码d988cae9（应用修复93d404ff，二进制门禁方法符号纠正d988cae9），已推送独立分支。候选0.3.103/2145；Apple预检35519306955确认下一build2145，现有公开外部TEST组575f1470-dc5c-486a-8da4-609762010f66，邀请https://testflight.apple.com/join/7sfEhgvE，用户已有邀请。
权限29专项通过；Flutter3701全量通过（2:51），analyze0；mobile88通过/1Windows无Ruby跳过；Node3；策略检查通过。根仓库verify已在同源业务代码2d463207完成（API2209/58环境跳过）；对services、business tests、verify脚本比较无差异，复用该门禁，重跑移动/工作流影响范围，避免重复22分钟后端检查。
规格审查通过后安全审查通过；发现并修正TestFlight可安装状态判据、原生门禁实例方法签名。原生模拟器测试仅证明预授权读取/请求，不代表真机首次弹窗。真实旧2144包被新二进制门禁正确拒绝。
Apple预检与完整CI分开运行；23:31:44+08已dispatch完整TestFlight工作流。上传后必须VALID、不expired、IN_BETA_TESTING、关联原公开组且公开链接仍启用才算安装可用。Apple审核/出口合规不以伪造声明绕过。当前等待CI，尚无新IPA/上传完成结论。
证据目录docs/verification/artifacts/2026-09-20/ios-testflight-permissions，candidate-input-hashes.json固定输入；临时文件均在此目录，不含密钥。

## 23:45 +08 内部邀请确认与证据复用
用户明确答复“内部测试邀请”，取代上一节外部分发假设。仅关联既有内部TEST组6c3548a1-b45d-41c7-b4b1-e7a567d15081，不提交外部测试审核。完成条件为VALID、未过期、内部READY_FOR_BETA_TESTING或IN_BETA_TESTING及该组关联。
运行35519856915的flutter-checks/job106101963167成功，日志与job JSON保存在任务证据目录；23:41取消尚未上传的后续作业，整个run为cancelled，不能声称整轮通过。固定该run及d988cae9完整SHA，校验全部Flutter输入一致（仅排除另行执行的integration_test）后复用单元全量结果，analyze和原生门禁仍重跑。
内部脚本Node3、交付Python4、模拟器契约Python5通过。一次命令误写不存在的test_ios_simulator_workflow.py，未执行测试；已纠正为test_ios_simulator_ci.py并通过。规格增量审查通过；安全审查无代码阻断，要求同步内部邀请文档，已完成。
相机预授权依据CI实际simctl help能力；不支持时只限定模拟器运行时覆盖，Pod与IPA相机门禁保留，真机首次弹窗待验收。下一步：推送内部候选并启动签名/上传流水线；仍无新IPA或可安装结论。

## 2026-09-21 00:09 +08 原生夹具排查
内部候选05c2e3cc/运行35520619498：Apple及Flutter checks通过、模拟器编译通过；实际权限断言mic通过，photos denied阻断上传。日志native-ci.log显示simctl依次grant photos和photos-add均成功，Photo插件源码区分读写与仅添加访问级别，NotDetermined映射denied。尚不能仅凭此断定应用缺陷。
按最小假设验证调整1d3df5e3：只grant完整photos，保留photos/PhotosAddOnly全部严格断言，并只读记录临时模拟器本应用TCC service/auth_value。无生产代码或授权断言放宽。专项9通过，运行35521565834重跑原生与后续交付，继续复用固定全量Flutter证据。当前尚未生成或上传新IPA。

## 2026-09-21 00:20 +08 夹具生命周期诊断
35521565834仍photos denied，未上传。新增TCC诊断在重装前显示Microphone2/Photos2，排除了单纯末次photos-add覆盖假设。Flutter3.44.9的_setupUpdatedApplicationBundle源码确认测试前重新simctl install。现改为最终测试进程READY后，由宿主授权并通过本次run唯一tmp文件确认；不修改生产代码、不放宽权限断言。同时输出实际Pod预处理宏和授权后TCC状态。两个原生失败均保留，不声称相册已经通过。

## 2026-09-21 00:40 +08 连接既有测试应用
运行35522440426/5de2c16a原生宏诊断证明五项PERMISSION均1；READY后host授权显示三项TCC均2，但运行中app被终止，Flutter79测试未完成，上传未执行。日志native-ci-3.log。
依据Flutter drive源码reuseApplication路径与integration_test SDK适配器，改为一次安装→停止态grant→simctl launch→flutter drive --use-existing-app，避免重装或运行中授权。相册与麦克风status/request严格granted断言保留。专项9和两个Dart文件analyze通过；准备本次最终安装生命周期复验，未宣称原生通过。

## 2026-09-21 01:13 +08 PhotoKit夹具边界证据
第四轮35523568850未从simctl console发现VM；依据Flutter SDK改用unified log后第五轮35524470548成功连接并执行原生调用。仍photos denied。决定性证据native5/permissions-native.log 1524–1550：现代PhotoKit read-write preflight返回Unknown/auth_version2，而legacy查询Allowed/auth_version1；不能将simctl授权表auth_value2等同现代访问级别已授权。五宏实际均1，mic status/request持续通过。
规格审查批准纠正无效夹具前提：保留mic及可支持camera严格运行时断言；Photos两种status只记录诊断、首次授权明确真机待验收；五宏、原生编译及最终IPA策略符号检查仍强制。第五轮失败原样保存，不能改写为相册通过；二进制仅证明策略编入，不证明授权交互已验收。此证据范围允许继续用户授权的内部TestFlight测试交付。专项10/1Windows Ruby跳过、analyze通过。此前工作流返工不属于生产权限功能变更。

## 2026-09-21 01:29 +08 原生断言通过后的测试框架清理
运行35525177449/45613c38完成实际权限断言，但测试末尾报A SemanticsHandle was active；不是权限断言失败，整轮仍failure，未上传。原生channel-only测试无widget，改用testWidgets公开参数semanticsEnabled:false，避免默认测试语义切换与iOS实时辅助功能句柄相互作用；权限断言和driver失败退出码均不变。日志native-ci-6.log已保留。

## 2026-09-21 01:45 +08 原生通道测试执行器
35526014082/04c08893仍在WidgetTester语义资源审计失败，权限断言已完成，完整run仍失败且无上传。原生通道测试没有widget树或测试自有语义句柄；改用普通test包围IntegrationTestWidgetsFlutterBinding.runTest，保留SDK标准reportTestException/results及postTest清理，去除不适用的WidgetTester包装器。不得手写成功结果或吞异常；SDK源码已核实runTest记录Failure优先于_success。native-ci-7.log保留；Dart format/analyze通过。

## 2026-09-21 02:01–02:09 +08 原生门禁通过，签名构建中
运行35526915961，候选f25ffee9：Apple预检、Flutter checks、simulator-build/job106120745319均success；原生driver日志All tests passed，保存native-ci-pass.log。Camera与Photos现代读写首次授权明确真机待验收，未计入模拟器通过范围。
签名作业106122715943已通过推送、原生通话/Keychain、分发证书与profile检查，进入Build signed IPA。尚未取得最终IPA哈希、上传或内部可安装结论。间歇GitHub TLS EOF仅影响本地状态读取，未重启CI或关闭证书验证。

## 2026-09-21 02:11–02:19 +08 签名包门禁修正
35526915961的build-upload实际已导出0.3.103/2145 App Store IPA，codesign/APNs/SQLCipher/版本检查通过；权限门禁依赖完整本地符号名，App Store导出裁剪符号后假阴性，上传未执行。旧workflow失败时未保存IPA，只有signed-ci.log，因此本次需要重建一次。
二进制门禁改读Mach-O ObjC运行时类/实例方法表，指定selector必须绑定指定类且IMP位于可执行段；不改变签名或关闭strip。新增19测试，最终专项29通过/1Windows Ruby跳过、Node3通过，规格通过。旧2144与清空符号表副本均正确拒绝；Unknown策略真实正方法表解码不变，证据metadata-gate/real-metadata-evidence.log。
增加native-evidence固定35526915961/f25ffee9与实际成功job/断言步骤；完整mobile目录零差异、原生job除调度if完全一致才复用。原生复用规格及安全review通过，避免再重复模拟器编译。新workflow失败时保留needs-verification候选，不绕过校验上传。

## 2026-09-21 02:30–02:38 +08 最终包校验与上传完成
运行35528706992，源码2de62b75bd5f01b2c4268f875984f61b94a65233，iOS 0.3.103/2145；最终IPA SHA256 4fdef120e186630032066d8a4110092b81c506849291a27907d3cc5626e27855。02:30:12签名、生产APNs、iPad、权限声明、SQLCipher及原生权限运行时方法表全部通过，证据final-signed-ci.log。GitHub已验证产物ChatFlow-iOS-signed ID10610573233（14天保留），无需重复回拉整包。
02:32:00 altool返回UPLOAD SUCCEEDED with no errors。02:36首次Apple轮询窗口结束，最后状态NOT_YET_VISIBLE，exit75；整轮CI为failure，不能表述全部通过或内部已可安装。02:37启动仅分发/查询运行35529655259（distribute-only=true，build-number=2145），未重建、未重复上传。
证据final-diagnostics/testflight-status.json及final-diagnostics/ios-upload.log。下步读取35529655259的Apple状态，构建VALID且内部可测试才关联既有内部TEST组并读回。Camera/Photos首次弹窗、设置跳转及iOS16.7.16整机重启仍待真机验收。

## 2026-09-21 02:43 +08 Apple处理完成，出口合规阻断
仅状态运行35529991314/4abb0ce0：build ID b6ac0d45-b5d4-41f8-a852-e9cda0dacbde，VALID、未过期，internalBuildState/externalBuildState均MISSING_EXPORT_COMPLIANCE。明确不是上传失败或待处理，用户需完成实际加密申报或提供既有有效口径；已通过异步问题请求，不能自动填“不使用加密”。
另一独立脚本问题：buildBetaDetail读取成功后，GET builds/{id}/betaGroups返回403。准备改为Apple文档支持的betaGroups/{id}/builds并用精确build ID比较，保留所有安装条件；只改分发查询脚本，不重建IPA。
本地TLS EOF后使用项目既有jumper建立loopback SOCKS 127.0.0.1:18745（exec session8935），恢复GitHub读取；不关闭证书校验、不改全局代理。35529655259仍NOT_YET_VISIBLE/exit75，35529887999读组403，均保留失败日志。后续查询4abb0ce0仅加安全阶段诊断，未改包。
时间：本次连续恢复窗口从23:12到02:43约3小时31分，包含00:09–02:19原生夹具/二进制门禁返工，02:24–02:30最后签名构建、02:30–02:32上传、02:32–02:43 Apple等待及查询。主动/工具精确拆分未知，不虚构精确工时。更早会话修复用时未知。
下一步：确认合规申报后运行ios-testflight.yml distribute-only=true/build-number=2145，无需重建；读回VALID、未过期、内部可测试和固定内部组关联。设备验收独立等待。

## 2026-09-21 02:47 +08 等待用户申报
用户明确答复“我在 App Store Connect 完成申报后告诉你”。保留2145，等待确认；不要误认为申报已完成。分发查询已改用Apple官方betaGroups/{id}/builds路径，精确资源ID判断关联；新增4个真实main/fetch模拟回归先403红后绿，Node共7通过，交付契约Python4通过。规格复审通过；质量复审后提交。仅脚本和文档变更，不需重建应用或重跑Flutter全量。
主工作区仅新增交接task及current-state索引，保留其他任务；未合并或发布main无关批次。相关文档链接检查通过。
