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
