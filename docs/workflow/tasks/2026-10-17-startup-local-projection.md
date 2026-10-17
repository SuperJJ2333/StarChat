# 冷启动首屏本地投影

- 用户授权：2026-10-17四项明确实施要求，延续上一轮模拟器Debug安装；无公开发布/真人发送。
- 状态：用户2220反馈重新打开：群头像缓存缺失、启动网络提示、完整SDK恢复后入房仍显示加载页。真实模拟器暖入房已复现；先前合成PASS不足以验收此路径。
- 工作树：C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat；最终产品d7ee45ed、测试4bd61e99，已安装APK117230f0…af83c0。
- 负责人：root文档/构建/交付；startup_pipeline独占计划Task1产品文件；冻结后独立审查。
- 规格：[首屏本地投影](../../superpowers/specs/2026-10-17-startup-local-projection-design.md)。前序：[2218任务](2026-10-16-interactive-cache-startup.md)。
- 下一操作：startup_pipeline诊断与行为RED；root真实设备证据及计划/版本/交付。确认范围后修复、独立审查、原生验收及保数据安装普通Debug；无正式发布或真人发送。
- 精确起始：首次本轮工具时间未单独记时；03:46:29+08工具时间已记录，后续实时追加，不估造主动工时。

2026-10-17T03:57:18.6839115+08:00 方案0e1f3ad3已冻结并按用户授权实施。采用同Client.initLocalCache()分阶段（替代init新增参数，保持override兼容），Factory.createForStartup返回安全本地40房间投影，完整恢复Future约束派发。startup_pipeline独占产品文件，root独占版本/文档/交付；V映射root管理。候选0.4.50+2219元数据61909dbf，6版本检查通过。Task1 SDK首个RED运行中；无新APK。


2026-10-17T04:15:09.0132847+08:00 Task1 Ruling: Add optional background-resume scheduling barrier from main to factory/SDK; release after actual cached AppHome frame, ordinary callers continue by default. Event-loop yield alone cannot guarantee paint before full-store materialization. No-cache/recovery/error/disposal must release or cancel safely. Cost if wrong: deadlock or delayed background recovery; require lifecycle tests. Authorized four-point sequence unchanged.
2026-10-17T04:25:52.3345291+08:00 Task1 intermediate entry-13: 8 PASS reported and log final marker confirmed. Actual main held recovery includes list/tab/room/scroll/durable pending/network0, then same page/room/txid one transport after release. Still WIP: old-entry behavior RED, merge and bounded-state edge cases, fixture asynchronous cleanup, adjacent tests and analysis; not source freeze or delivery gate.
2026-10-17T04:49:04.6407458+08:00 Task1 fix round1/5 dispatched to original startup_pipeline from25d851d7: P1 fatal SDK completion reused forever on Retry; P2 actual main missing visible anchor-after-release assertion. review-1 SPEC and QUALITY CHANGES REQUIRED. WholeDB preflight and optional-key/global-account-data merge boundaries explicitly assessed; latter not concrete admitted early-UI blocker. Full/build remain not started.
2026-10-17T05:25:12.1862625+08:00 最终全量02c76dcc：6093PASS/9SKIP/0FAIL，full analyze无问题，均exit0；flutter-full-2219/receipt.json，24分24.476秒。mobile boundaries377PASS23SKIP、UI34components/540screens PASS。原生integration候选debug-native-2219构建中，普通main尚未构建/安装；模拟器仍2218。
2026-10-17T05:40:08.9525583+08:00 原生native-entry-2219-2 PASS，非流式覆盖安装保留UID/firstInstall，实际main合成场景与全隐藏场景均通过。普通main正在debug-main-2219构建重建校验；当前设备暂时仍是验收入口，必须普通main恢复后才能交付。

## 2219 真冷启动反例与修正决定（2026-10-17）

普通 main 0.4.50+2219 已保数据安装，成品 SHA256 283cbcf18f90e1dbd81c65edb19154f11693e84789057d07d0b8fea1a258066b，固定 75b31 签名，UID10090/firstInstall 不变。但实际账号冷启动录像 main-cold-video-2219 明确 FAIL_PERCEIVED_LOADING：仍出现启动、本地聊天及本机会话加载页面。6093PASS/9SKIP 与原生合成入口 PASS 均不覆盖该性能反例，不能记作用户目标完成。

Ruling: 采用独立有界 AEAD 首屏缓存，替代首屏依赖整库 SQLCipher 查询。用户四项明确授权支持此修正。保留原整库 preflight、SDK、业务认证与发送权限链在后台；本地展示能力不能充当通信权限。先冻结存储/失效/接口边界并独立领域与质量安全审查，再实施及真冷启重验。详见 task-3-diagnosis.md。下一步：独立缓存设计审查与行为 RED（持有整个原整库 preflight，而非仅 device-key 恢复）。

2026-10-17T06:03:33.8450297+08:00 Task4 ADR approved after independent DOMAIN/SPEC and QUALITY/SECURITY scoped re-review PASS; B1 mutation ticket requirement included. startup_pipeline sole writer granted exact frozen brief product/tests including native peek extension; no full/build/device until source freeze and review. Root owns docs/version/delivery. Actual installed2219 UX FAIL unchanged.
2026-10-17T06:08:13.4935161+08:00 Task4 intended B1 RED verified log task4-lifecycle-red.log:2PASS2FAIL exit1; beginCapture wronglynon-null while applyheld and nestedticketactive. Not compile/platformfailure. Worker ownsV mapping task4-mapping.txt. ProductWIP newstartup_projection +lifecycle test; no sourcefreeze/full/build.
2026-10-17T06:36:26.0004841+08:00 Workerreports remoteprivacy fence persistedpreHTTP, preservedordinaryinvalidation/relogin, clearedonlymatchingposttransactioneffect, overflowpersistentlydisablescache. Core/admission/iOSDartpeek15PASS task4-core-green-4.log; Swift tests registeredbutnotrunWindows. Actualempty/focusedregressionsongoing. Mainentry1PASS earlier; no sourcefreeze/nativePASS.
2026-10-17T07:08:37.9189325+08:00 Task4 product frozen073292752489905f2e8d3243288623aaa0f0bb5b, 30 ownedfiles. Combined223PASS then optionalwriter catch affected26PASS; finalanalysis0 reported. Fresh independent task4_code_review DOMAIN/SPEC thenQUALITY/SECURITY dispatched; full/build remainheld. Candidate0.4.51+2220, installed2219 unchanged.
2026-10-17T07:15:08.0850971+08:00 Task4 fix1 ownership extension granted third_party/matrix/lib/src/timeline.dart and matching focused regression tests: public bounded canonical-head reconciliation on sameTimeline/readingfragments, baseline identity/live mutation precedence/aggregation; no persisted cache key/media expansion. B2 independentseed scalar adoption only with baseline/historygeneration guards. Review1 complete B1/B2 only, no extra securityblocker.
2026-10-17T07:25:17.2718969+08:00 Task4 fix1 frozen523efc96da88a2087f12bf07051a805649906f6b (6 files), rootverified149PASS/final27PASS/analyze0. Same-timeline canonicalmetadata/newhead/pending/readingfork and independentseed scalar/historygeneration regression added. V removed. Scoped DOMAINthenQUALITY review underway; no full/build/device yet.
2026-10-17T07:26:57.6611770+08:00 Task4 final523efc96 reviewedPASS after B1/B2fix; combined223, fix149, finalaffected27PASS/analyze0. Full2220 running session28429 concurrency1; finalboundaries session59202. Native/main2220 builds notstarted; installed2219 still priorUXFAIL.
2026-10-17T07:35:16.1165536+08:00 Finalfull2220 stopped ownFlutterPID255140 after1304PASS at friend_requests_cache_test delayed-store setup deadlock; exit1 preserved, notfullPASS. _client awaitsaveSession nowlegitimatelyreads secureidentity; fixture holdsallreads beforeclientcreation then releasesonlyafterreturn. Granted test-onlyarm-aftersetup correction +boundedsearchsimilarfixtures. No productsecurityrelaxation. V runnercleanup confirmedbyreceipt, no build.
2026-10-17T08:04:11.1864332+08:00 Full2220-r2 complete ef8e8eb6:6115PASS9SKIP1FAIL1ERROR, exit1, elapsed26m22.828s; analyze notrun byrunner aftertestfailure. Onlyinternalenumregistration + chatsettings401retrytiming assertion; originallogs retained. Worker nowowns exact2testfiles, productunchanged. Plan: focusedfix+review, rootfullanalyze; reuse6115passing unchangedinputs, no third26minute rerun absentproductchange.
2026-10-17T08:23:55.4809566+08:00 Native2220 artifact67d5c7dd..3b8d8/127375706B fixed75b31 buildPASS6m45.079s. Install-r preservesUID10090/firstInstall. Run1 driver255 externalcoreserviceforce-stop, noappcrashstack; exactinstalledr2 fourreportscenarioscomplete butdriverexit1 nativeRenderFlex1pxoverflow. RootnotcountsPASS. Identifiedredpacketcardfixed96height(headertext48, Android49). Grantedexactcomponent+widgettest and skill-requiredminimalHTML/registryparity subjectfiledeclaration. No auth/financiallogic changes. Need focusedreview/rebuildnative beforemain.

2026-10-17T08:54:52.9004940+08:00 Final native2220-r3 four actual-main scenarios PASS driver0; ordinarymain2220 installed preserving UID/firstInstall and artifacthash863ae7bc..d1f. However actual-account cold video FAIL_PERCEIVED_LOADING: frames024/026 display startup/local-list waiting before cachedlist; previewloss after fullrestore under investigation. Do not mark complete. Synthetic acceptance must cover every intermediate visibleframe. Root owns docs, startup_pipeline read-only rootcause diagnosis then bounded RED/fix proposal.


2026-10-17T08:58:14.0668085+08:00 Additional observed first-room-frame gap: async SharedPreferences/logicaltimeline beforecontroller can paintroomloader. Approved narrow preparedcachedentry ownership RoomPage +existingcentralnavigation, samelease/timeline transferonce, cancellation/accountswitch/doubletap disposaltests; list staysinteractive untilpreparedpush. No fullSDKdependency or cacheprivacycheckbypass. Native4scenarioIDs retained with explicitfirstvisible/noLoading frame assertions.


2026-10-17T09:03:18.0910526+08:00 Watchdog clarification supersedes earlier startApplication-only timer: enhanced actual-main gate uses one8second attempt envelope from_reconcileAndStart, covering prepare/reconcile/admission. Legacy gate callers retain existing behavior. Knowncachemiss cancelsbudget/releasesnormalUI; timeout retiresattempt with Retry, latecompletion cannotstartnextstage/publish, retries owner-isolated. No securitycheckbypass.


2026-10-17T09:14:15.1836577+08:00 Room hypothesis correction: source awaits alone were not a verified visible-frame defect. Warm actual-main firstroom audits PASS; forcedRED reset SharedPreferences singleton aftermainready, a condition notestablishedinproductioncachehit. That log is INVALID_PRODUCTION_REPRO, notacceptedbehaviorRED. RoomPage/AppHome ownership expansion suspended; noproductionedits made there. Trace remainingcacheawaits; keep per-frame roomassertion. Scope remainsconfirmedmainfirstframe +canonicalpreviewhandoff unlessactualIO evidencefound.


2026-10-17T09:27:39.5524975+08:00 Firstframe/canonicalhead finald7ee45ed independentlySPECthenQUALITY PASS task4-firstframe-review.md; rootverified24manifesthashes, fullanalyze0(15.7sec). Gate21PASS; affected150PASSwith2commandpatherrors corrected39PASS; all4actualmaincasesPASS inclvisibleframeaudit. Newnativebuild debug-native-2220-r4 started. Installedordinarymain remains9d658 priorUXFAIL; nofinaldeliveryclaim.


2026-10-17T09:40:32.8104734+08:00 Native r4 buildPASS fixedsign source d7ee45ed APK81d378d1..709e75. Devicepreservedidentity butnativeentryr4 FAIL driver1: livepostFrame audit uses guarded expect concurrently withtesterpump; twoindependentcases abort fixture, twolegacycasespass. Productfailure notestablished, do NOTmarknativePASS. Authorizedone-test-file callback-safeexpectSync correction keepingallframe/queue/assertions andkeys; independentreviewbefore rebuiltnative. Realdata untouched.


2026-10-17T09:57:46.4311197+08:00 Nativefixture4bd61e99 onefilefiveexpectSync changes independentlySPECthenQUALITY PASS; host4PASS/analyze0, unchangedproductd7ee. debug-native-2220-r5 buildPASS; native-entryr5 executing. Ordinarymain debug-main-2220-r2 builds concurrently withinstalledAndroidfunctionaldriver only (nohostfulltests/sharedbuildoutputoverlap); cannotinstalluntilnativePASS. Nativefixturetimingsnotperformanceclaim; actualcoldafterallbuildactivityends.


2026-10-17T10:01:25.4373258+08:00 Native-entry-2220-r5 PASS driver0/198.656s fourIDscomplete; independentfirst_visible_content/no_loading_frames/first_room_content alltrue, originalpreflight/opener0, networkheld0 after1; hidden/empty0. Syntheticprimingandconcurrentordinarybuild timingsnotrealcoldlatency. FixedsignednativeAPK4b98853e..c914f. Ordinarymainr2 verifydecode/checkongoing; waitbeforeactualaccountrecording.


2026-10-17T11:59:22.7759271+08:00 DELIVERED: ordinarymainr2 fixedsigned117230f0..af83c0/126064986B installed5556 UID/firstInstall/deviceSHA MATCH. Native r5 four scenarios PASS, explicit3framebooleans true. Actualcoldr2 admissionRejected retainedasnonfastpath; regeneratedcache r3 HIT1128/content1450/preflight1804/SDK3977ms, visible native→realcachedlist andcanonicalpreviewretained. Finalpassivesmoke stableforeground/fatal0. No all-starts/no-engine-delay claim. Rootdocsfinalization only; no productionpublish/realrecipient sends.


2026-10-17T14:09:17.7750586+08:00 REOPENED user2220feedback. Root actual fully-restored ordinarymain warm-room.mp4 reproduces transient roomloader in route transition then bubbles. Existing held-SDK firstroom tests did not cover ordinary database branch. Evidence user-feedback-2220 local screenshots/video private. Productwriter diagnostic+test RED only until bounded scope declared; root owns docs/build/device.


2026-10-17T14:13:21.5869549+08:00 Feedback rootcause confirmed: warm-room getEventList delayed after routepush, projection applies only while SDKpending; actualmain realDB RED feedback-warm-room-red.log exit1. Avatar null→emptyURI wrongbranch + missingmembers + resolver needsunrestoredclient. SessionGate status!=authenticated wronglylabels loading asoffline. Approved room/network product scope AppHome/RoomPage/SessionGate+tests; avatar AEAD optional boundedmembers and existingcache readonly design under independentDOMAIN→QUALITY review. Candidate793217b7 0.4.52+2221 reserved; versioncontract3PASS; no newAPK. Coldbaseline confirms initials+offlinecapsule; concurrenthosttest meansnotlatencybenchmark.
