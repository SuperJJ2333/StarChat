# Android2213 返回最新门槛与正式分发

授权：用户要求提高“回到最新消息”上滑出现距离，修改后发布Android渠道与更新弹窗。小范围设计：约一屏且至少600逻辑像素才出现；搜索/引用历史上下文保留入口；跨窗口坐标重基不能让按钮消失或误现。含已验证debug2212缓存/快滑/表情修复；不改iOS/minimum或发送聊天广播。

2026-10-09，本轮起始准确时钟待首次记录；root拥有room_page.dart、continuous fling专项、版本文件与本任务发布元数据。managed W树b09bf2f2+既有2212 WIP，不重置。正式基线需新读取；预期Android2211/iOS2205/candidate2209，不将旧快照当实时事实。

计划：[执行计划](../../superpowers/plans/2026-10-09-android2213-return-latest-release.md)。

| ID | 验收 | 状态 |
|---|---|---|
| R1 | 轻微上滑不显示，超过一屏显示，返回最新隐藏，历史上下文可返回 | 已实现，真实Widget及原生通过，已正式发布 |
| R2 | ARM64正式新版本固定签名重建，含2212修复，门禁与审查 | 28构建门禁/最终双审通过，已交付 |
| R3 | CloudFront/官网分发、普通更新弹窗与审计，iOS/min保持 | 17:17:44+08 PUBLISH_PASS及四项后验通过 |

下一步：真实RoomPage阈值RED→最小实现→专项/共享及审查→正式0.4.44+2213构建→新基线CAS发布→后验与记录。真机USB仍不可用，保留前任务已记录性能边界。

## 2026-10-09T17:04+08 实施与独立审查
可靠起始16:51:15+08，较早只读调查精确起点未知。真实RoomPage轻微100px上滑后incoming使context标记true，原无距离门槛RED；初次仅无incoming控制PASS不是BUG RED。已增加累计阅读距离max(600px,viewport)，跳最新复位，定位成功explicit返回，坐标重基不计入距离；按钮独立VLB。专项初次保留generic context例外仍误现，确认普通pin也属于context后改为明确locator成功标记；11项通过。
独立SPEC指出外层hasLater/context条件使首次VLB未挂载、没有incoming时无法显示P1；暂停取消共享测试exit1并保存日志，去外层条件、增加无incoming100隐藏→1200显示→100隐藏行为，最终11项PASS，SPEC→QUALITY接受。最终全量重新冻结1f806c8d20cbe1b410aa36ac194616b651c5961d251b797cbab89fb08b85641f后串行运行；取消测试不当通过。发布runtime17契约通过；旧双新路径断言适配为仅一个APK新路径，旧14全部保留，初次16PASS/1FAIL留档。边界377/23、UI34/535、policy3通过。
16:55:54+08新只读HK正式Android2211/iOS2205、schema0095、35运行容器，SGCF14/Deployed；分发代码以新快照CAS，仅Androidversion/build/notes，PG事务函数逐字hash不变且API/worker身份不变，复用真实PG6证据。两个自有0700暂存目录已创建，尚无生产渠道/设置写入。包版本0.4.44+2213，尚未构建；下一步最终共享/原生缓存历史17→normalpubget冻结→ARM64构建。

## 2026-10-09T17:13+08 正式构建与上传
最终共享5758PASS/9条件skip（17:00:47–17:06:19）、analyze0、当前native缓存/历史/生命周期17PASS，IME恢复/helper清理通过。ARM64冻结2dc702fe2b8fdf5acf0f92f368bf201dd858be38bbdbf96e0fd31e798a66f630/1941，最终共享files逐项一致；旧emoji/SQLCiphercore原生仅在指纹不变范围复用，不复用旧RoomPage按钮或声称release性能。
0.4.44+2213 ARM64源码→Apktool→zipalign→75b31→28门禁exit0，六个SQLCipherkey/blob导出存在。最终APK08a7448114ad5d768b534b81b61668e03a71a2c26f95e894297e098838f15271/73139489bytes，保留全字体，无新增混淆。prepared release JSON f5d21d4096d49c45e8f00f4b1ef49299949c5bbe13cfbee8d9d5267a57318126。
准备脚本字符串适配误改含2211的固定AWS账号，真实fresh policy新测试RED捕获；显式恢复固定218022113852，最终18契约PASS，尚未调用任何云写入。旧17契约不覆盖此缺陷，不能单独当最终验收。reviewer重审最终runtime与成品中。17:13:19当次HK十设置/静态/schema/35容器/alias精确前态无漂移。私有runtime已上传两地，APK五块顺序上传并逐项SHA，公开渠道/设置暂未写。下一步finalSPEC→QUALITY接受→组装/不可变安装→CF15Deployed→alias/官网/SettingService→后验。

## 发布闭合 2026-10-09T17:18:57+08
R1–R3已正式发布与服务器验收完成。17:15:23不可变APK安装；17:15:41CF InProgress→17:17:23Deployed/HEAD/CORS；17:17:37alias→17:17:44PUBLISH_PASS→17:17:47exact3audit。17:18:22–28四项后验全绿：HK/static/平台/schema35runtime保持，SG15/策略保持，实际Android/iOS/legacy投影与3审计，工作站严格TLS官网/CDN/latest HEAD及page/registry/401，无公网完整APK回拉。源码primary54/managed51 Node通过，主与managed各自页面布局和非Android内容保全；自建SOCKS结束清理。
成品/签名/源冻结、scope限制、可靠起点约27.7分钟和回退入口见[最终报告](../../verification/2026-10-09-android2213-release.md)。0700备份/opt/starchat/docs/verification/artifacts/2026-10-09/android2213-release-165500。Android正式0.4.44+2213，iOS0.4.36+2205/min3/候选2209保持，未Git合并或push。没有剩余构建/发布步骤；真机USB不可用，用户手机覆盖/实际弹窗/profile待反馈，不称任意历史/设备零卡顿。
