# 0.4.46体验五项优化实施

用户2026-10-16已批准方案并要求推进，允许模拟器安装Debug。当前阶段：实现/独立审查完成，Android实际main及修订原生门禁通过，iOS待匹配签名/真机验收；基线92846f60，工作树im-reliability/StarChat，分支codex/mobile-experience-2216-20261016。root负责集成/构建/HTML及记录；Tasks1–4各自实现与审查已结束，原生测试-only修正已独审并提交27b00b9f。

[批准规格](../../superpowers/specs/2026-10-16-mobile-experience-2216-design.md)；[执行计划](../../superpowers/plans/2026-10-16-mobile-experience-2216.md)。完整恢复账本：docs/verification/artifacts/2026-10-16/mobile-experience-2216/progress.md，任务完成后逐项更新，不重复派发。

开始03:06+08；Flutter3.44.9/Dart3.12.2；emulator5556在线，已安装debug2215/min24/target36，UID10090、原安装时间2026-09-26，必须install-r保数据。候选预定0.4.47+2216，构建前复核占用。依赖已用pub.dev enforce-lockfile恢复，锁SHAa43833c8不变；默认镜像首次恢复因试图变更216项而被锁门禁拒绝，没有接受升级。

正式两端2215保持，尚未发布新候选。iOS真实APNs与签名/真机覆盖依赖只阻断相应验证，不停止客户端修复。

| 验收 | 当前状态 | 证据/下一步 |
| --- | --- | --- |
| S1启动/S2历史 | Task4完成，独审通过，commitbb33f6b1 | 初始164专项；修复缓存衔接7项+82相邻回归PASS，均有重叠不可直接相加；真实挂载等待保留只读缓存，ready重建live订阅 |
| S3媒体预览 | Task2完成，独审通过，commit9cb19ddd | 初版97专项PASS，GIF内存路径复审修复31相关PASS；静态首帧/非空fallback/有界缓存读取 |
| S4乐观媒体发送 | Task3完成，独审通过，commit231111dc | 初版96 distinct专项；修复第一轮75、第二轮46相关PASS（不可相加）；行内恢复/重试/取消、晚到缩略图和取消云端源不阻挡就绪兄弟项 |
| S5权限 | 代码已完成并独审通过，commit14e0b09e | 24专项PASS、11项analyze clean；两处Darwin初始化不申请，按需授权/状态刷新，mic/camera fail-closed |
| S5 APNs | 用户确认沿用原服务器身份，匹配回签/真机待验 | Sygnal TeamHY9Q7Q35S5与源码一致，公开回签Team7XL5R8V6RC不同；凭据未修改，真实到达未验 |
| HTML parity | 5个demo完成 | 12相关交互PASS，34组件/540画板contractPASS，浏览器失败/重试/授权延后/静态播放验证 |
| Debug设备 | main2216保数据覆盖安装；11媒体发送/ACK/重启/视频播放已验证 | android-main-debug/receipt、main-eleven-ack-after-cold.json；原生修订5用例driver exit0，全程完成，main已恢复；离线实验模拟器失联后已恢复，不记PASS |

03:28+08 Task1完成规格→质量/安全独立审查，Task2接管窄范围RoomPage预览。Task1较大回归186PASS/1AppHome时序失败，单跑候选与精确HEAD基线均PASS且有相同LateError诊断，未称大回归全绿。Frontend562/567，5项旧发布测试锁2213/2205；7个相关输入与baseline Git blob完全相同，证据frontend-baseline-inputs.json，未更改无关分发行为。最终共享全量与原生门禁仍待。

03:30+08 Android Debug旧包am start报告timeout/13433ms，之后Flutter attach恢复且只读自测房间检查PASS。该数值含Debug启动/挂接环境，不能当正式首屏SLO。当前工具进程：frontend4186 loopback server，旧2215 Flutter attach（80140）；Playwright experience2216已关闭。构建前需停止挂接，不能让旧源码hot reload覆盖候选。临时材料均位于本任务artifacts目录。

下一步：Task3独审→Task4；root同步HTML和证据，最终冻结版本，执行共享门禁、常规重建固定签名Debug保数据安装、单成员房间合成媒体验证。回退以旧成品/兼容缓存为依据，不卸载、不降级清数据；未触及生产部署。
04:01+08 进展更正：此前记录的4186浏览器服务和旧2215 Flutter attach均已停止，Playwright窗口已关闭。Task2初版97专项PASS/analyze15clean，独立审查发现GIF缩略图内存命中绕过静态首帧的P2，正在一轮窄修复。Task3尚未派发，避免RoomPage并行写入。HTML最终12相关用例及34组件/540画板合同通过，已有发送首帧+转圈、失败/重试演示截图；发现的无效CSS token已换为现有elevated。候选pubspec与iOS交接workflow已同步0.4.47+2216，2项版本门禁PASS；没有构建/安装/CI/正式发布。设备仍UID10090、2215，内存可用约3.23GiB/虚拟60.91GiB。

04:41+08阶段补记（精确步骤起止未记录） 当前候选HEAD5762dd7a；Task2已完成含审查修复，Task3独占实现发送链路，主门禁26PASS后正在相邻回归。pubspec/workflow/AppConfig已一致0.4.47+2216（既有编译版本contract RED→3PASS），无新包/CI/发布。11份新合成媒体已仅放入模拟器Pictures/ChatFlow2216Verification，所有SHA一致，未发送。准备了实际SQLCipher/缓存历史合并原生入口、常规重建Debug脚本、共享全量门禁脚本。发现Flutter drive默认结束会卸载应用，因此执行时改为显式adb install-r、UID/原安装时间守卫、现有VM driver；没有清数据步骤。HTML行内重试/取消RED1→相关12PASS。iOS签名/APNs匹配资料问题待用户回复，客户端独立实施继续。


2026-10-16T05:09:48.5108256+08:00 S4状态：初审发现3项缺口；第一轮修复75专项PASS。复审已接受失败行操作及阶段/晚到缩略图刷新，但取消尚未返回的云端原文件仍会让整批等待，正在第二轮窄修复；未把未审查源提交或构建给用户。S1/S2启动/历史仍待Task4，新增只读预览搜索/折叠/底部tab门禁检查前提。全量、原生、Debug新安装与iOS CI均尚未执行。当前HEAD6b70a49e，公开版本仍2215。

2026-10-16T05:25:31.0586675+08:00 用户明确确认：只能使用服务器原有 APNs 签名身份。Ruling: 下一版推送固定沿用 HY9Q7Q35S5 / com.liuhetong.liuhetongMobile / production，不切换到公开包的7XL5R8V6RC；最终回签必须匹配该 Team/Bundle/aps-environment，否则不能宣称后台通知可用。若无法获得该身份的分发签名，仅签名与真实APNs/覆盖安装验收受阻，客户端、Android模拟器和iOS无签名CI继续。公开旧包Team不同，覆盖安装/Keychain可访问性需真机验证，禁止以卸载清库规避。

2026-10-16T05:26:39.7602527+08:00 Task 3: complete (231111dcb1ca9560c8b7c4c2bc1557e1c28143f9; initial review3findings→fix1F1/F2closed→fix2F3closed, scopedSPEC PASS/QUALITY APPROVED).11manifestpaths verified/stagedexact/committed. Initial96distinctfocusedPASS, fix1 75affectedPASS, fix2 46affectedPASS not summedunique; analyze clean. Native/shared/device gates pending. Task4 startup/history freshimplementer next, no Task3writer remains.

2026-10-16T05:49:54.8410672+08:00 Task4 SPECFAIL / QUALITYnoadditionalfindings: oneP2AppHomecached→warmupreplacementpendingresource. Fixround1 startup_history_2216 resumed, staged8pathsimmutablebase. Ruling: extendTask4ownership narrowlytoAppHome display+held-resourcebehavioraltests tofulfillstablecachegoal; preserveexactcapability/auth/readiness/outboxordering andsame-accountboundary. Costifwrong: startup/revocationregression, mitigatedbydelayedattach+accountreplacementtests andscopedreview. Rootshared/native/CIstillpending; sourcebaselinef541ab38.

2026-10-16T06:16:48.4411838+08:00 五项实现已完成任务级SPEC→QUALITY审查，候选源码冻结bb33f6b144f0054b0079a98206b4f945acbe0eb5；整分支审查与单次共享全量已启动。运行记录shared-final-bb33f6b1；Android原生/实际main构建安装和iOS CI仍待。所有实际媒体发送继续限定单成员加密自测房间。


2026-10-16T06:54:14.4526254+08:00 集成阶段：整分支实现SPEC/QUALITY通过，CI原生发送持久化目标遗漏修复79e08436；离线历史旧测试文案已对齐并增加实际重试恢复，独审通过b37377e9。首轮主机环境缺原生库导致失败；已从上次成功门禁找回完全同SHA Olm3.2.15/SQLCipher4.10并采用短V路径，完整复跑中，不能把首轮说成通过。发现测试夹具日期过期/零时限竞争/清理资源未显式拥有，待本轮结束后窄修。iOS CI38817420484设备IPA成功且本地验包通过（34981074B/SHAbe466573…7e4da9）；5个原生目标继续运行。Android新Debug仍待构建安装。

2026-10-16T07:12:23.6450224+08:00 Fixturecommit a3dde0e6 SPEC→QUALITYPASS,18focused/analyze3clean;runtimeunchanged79e08436. AndroidnativeDebug build exec48723:source/rebuild/sign/identityPASS,semanticcomparisonrunning since07:09; notinstalledyet. iOSCI38817420484 completed:deviceIPA PASS,4native targets21PASS,2outboxtests failMEDIA_STORAGE_UNAVAILABLE beforeDB. SeparateexistingnativeXCTest capabilityprobe38821916056 dispatched07:10,same79e08436,no sourceedit/deviceIPA rebuild. Exactcausepending,productionfail-closed retained. Allcandidate/publicationstatesremainseparate; finalreportdraftcreated.

2026-10-16T08:07:48.675128+08:00 Main Debug source a3dde0e6/rebuild/sign/semantic PASS, 125966682B SHA ae7e9eabd7bd1fb56eafd1e5907c279fea2232e688654656aa7791a1f5d9d619; install-r preserved UID10090/firstInstall2026-09-26. Actual guarded one-member encrypted room UI sent9JPEG+GIF+MP4; after cold restart11uniqueIDs/11txids/11sent+serverACK, noSDKecho. Native initial aggregate FAIL/255 retained; 7individual widgetsuccess/4failures snapshot, bad host/live binding mixture isolated into2dedicated nativehistory cases plus3existingnativeoutbox, reviewR1/R2fixed/specqualityPASS, commit27b00b9f. Correctednativebuild exec84464 inprogress. iOSfresh capabilityprobe38821916056 SUCCESS4PASS/4SKIP/0FAIL, iOS26.2DataProtectionreadbackabsent confirmed; original21PASS/2ERROR remainsFAIL, realiPhoneoutboxpending. Emulator offline probe: wifi/data toggling caused alladbshellunresponsive; stopped onlyownedprobes29930/56951, rebooted onlyLDPlayerindex1 withldconsole (diskpreserved), reattach/networkrestorepending. Offline acceptanceNOTPASS. Public2215unchanged.

2026-10-16T08:17:56.657044+08:00 Android correctednative27b00b9f PASS: build08:05:30–08:12:43, SHAda3c1812838710be46df6f256b13eb05cec32c0d5948216b5eeebef014dc5833; run08:13:38–08:14:41, directdriver11.078s/exit0/All tests passed. Entrypoint registers5testWidgets (3media+2history); Android skip predicatefalse. Callbackdatafile is null (no optionalreportData supplied), not detailedcaseresults; actual success is response.allTestsPassed gated SDKdriverexit0. OriginalFAIL/255 retained. MainDebug a3dde0e6 exactSHA restoredinstall-r08:15:27–08:15:38, UID10090/firstInstall preserved; final guarded room11unique sent/serverACK and previews retained. Nativeharnessdoesnotopeninstalledaccount. Finalattach66906 detached08:17, nohotreload. Networkwifi1/data1 restored; offlineattemptNOTVERIFIED. iOSmatchesoriginalTeamrequiresrealdevice/signing; no2216publication.
