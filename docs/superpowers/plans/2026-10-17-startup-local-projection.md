# Startup Local Projection Implementation Plan

> Use subagent-driven-development for one coherent cross-module implementation task, independent specification then quality/security review, followed by root-owned delivery. User already approved the four-point design and original emulator delivery; continue without another permission loop.

**Goal:** Valid cached account opens a real interactive messages list and rooms before full SDK initialization, including durable text pending.
**Architecture (revised after real-device failure):** Independent bounded account-bound AEAD display projection; minimum secure account/install/key admission before display, unchanged whole Matrix DB preflight and SDK restoration after first content frame. Same Client/Room/page and existing outbox. Prior Task1 SQLCipher projection is historical implementation evidence, superseded for the fast path by Task4 and its ADR. Full original checks still gate transport.
**Tech:** Flutter/Dart, vendored Matrix, SQLCipher, Android Debug.
**Spec:** docs/superpowers/specs/2026-10-17-startup-local-projection-design.md.

## Authorized Android release follow-up (2026-10-17)

User explicitly requested “好的，请你推送Android新版本更新弹窗” after2221Debug delivery. Root now owns ARM64 standard release build/rebuild/fixed signer, fresh production capture, immutable/CDN availability before alias/static and transactional Android popup publication, audit/public checks and exact source backfill. Independent specification then quality/security review binds the final package/executor before remote writes. Target0.4.52+2221; preserveiOS2215, minima3 and other services. No product code changes or new forced-upgrade policy. Evidence/task separate: docs/workflow/tasks/2026-10-17-android2221-release.md and docs/verification/artifacts/2026-10-17/android2221-release/. Reuse same-source shared/native evidence under change-impact rules, retaining all original failures and known device/libcrypto/antivirus limitations.

## Constraints / ownership

- Same isolated tree7747e54a (productc29597e0). Root docs/version/packaging; startup_pipeline sole product writer; reviewer read-only after freeze. No child agents by implementer.
- Preserve normal create/login defaults and security/crypto semantics. No new plaintext persistence, destructive migrations, schema/financial/auth contracts. Migration/missing/corrupt identity may use existing safe recovery UI; validcached path must not await fullSDK.
- Initial room projection<=40; room recent event head<=40 reused. Full hydration never replaces active Room/controller/page/anchor/pendingtxid; cancels stale account/generation/disposal results. Remaining rooms may expand in background.
- Existing real local account checks precede localCacheReady; business verified dispatch additionally waits initializationCompleted. Failure handling must not leave fake ready capability or unhandled detached-future errors.
- Evidence only docs/verification/artifacts/2026-10-17/startup-local-projection/. ShellpwshUTF8, PythonUTF8. No messages to real recipients. Native tests synthetic isolated data; install-r only.
- Previous2218 passes are baselines, not evidence of this corrected cold-start behavior. Resource-limited host: focused concurrency1, no concurrent Gradle/fulltest.

## Review focus

1. Bounded SQL queries include only selected room IDs, not loadall then take40; selection/order/cache visibility is correct.
2. Partial Client readiness never becomes network send/auth authority; full init errors/revocation invalidate local routes.
3. Full room merge preserves object identity and live updates, with safe handling of newly created/removed/hidden rooms.
4. Cold-entry tests traverse actual main, installation gate, factory, bootstrap, AppHome, RoomPage; held fullSDK does not implicitly release before assertions.
5. Cache scope and pending journal stay consistent across startup, retry, account switch and disposal; no duplicate txid/network send.

## Task1: Staged local startup and actual-entry acceptance

**Owned files:** apps/mobile_flutter/third_party/matrix/lib/src/client.dart; src/database/database_api.dart; src/database/matrix_sdk_database.dart; apps/mobile_flutter/lib/features/matrix/matrix_client_factory.dart; matrix_e2ee_client.dart; core/matrix_startup_client.dart; core/session_bootstrap_controller.dart; main.dart; core/installation_startup_gate.dart only if required; focused matching tests and integration_test/android_startup_local_projection_test.dart. Additional required product file must be declared to root before editing. Preserve LF SDK files.

**Interfaces (approved equivalent API):** Client.initLocalCache() opt-in wrapper preserves existing init overrides; localCacheReady and initializationCompleted completion interfaces; concrete future ownership/error delivery documented in report. MatrixClientFactory.createForStartup() returns sameClient once safe bounded projection available, normal create unchanged. MatrixSdkE2eeClient/public session interface exposes complete initialization barrier with immediately complete default for ordinary fakes/clients. Bootstrap announces local eligibility first, awaits full barrier before authenticated dispatch. main test dependency seam defaults production, injects platform/store/factory/API adapters only and must call actual production main composition. Names can be adjusted only with root-notified equivalent semantics. Approved scheduling clarification: optional full-recovery resume barrier is released after the actual cached AppHome frame; ordinary callers continue by default. No-cache, recovery, errors and disposal must not wait indefinitely for a nonexistent home frame.

- [ ] RED: genuine persisted SQLCipher fixture with>40 rooms; hold full initialization device-key/allroom stage. Assert factory returns within local projection while full completionpending, <=40 local rows and no allroom scan; data/keys no unauthorized exposure.
- [ ] Implement opt-in sameClient local-ready stage. Existing minimum encrypted identity/Olm path retained; guarded full continuation merges Room identity. Preserve defaults/source compatibility. Add error/dispose/accountgeneration and defaultnormal-init regression cases.
- [ ] RED at app.main: real stored eligible identity + synthetic API; hold full initialization, advance beyond3seconds, assert real cached messages list and no business full-screen loading; click tabs, enter cachedRoom, scroll actual viewport, durable textpending with network send0. Explicitly prove barrierstillpending at each assertion.
- [ ] Wire actual main to createForStartup and session readinessbarrier. Full recovery merges same page, preserves anchor/pendingtxid; releasebarrier and existingpermissionchain sends exactlyonce. No static screenshot/new mockhome shortcut.
- [ ] GREEN failure/retry/logout/accountswitch/hidden/redacted/corrupt/no-cache cases; preserve safety UI only where necessary. Input enabled only when existing safe durable queue ready.
- [ ] Package native integration target using same test scenario and real AndroidSQLCipher synthetic isolated fixture; no liveaccount store mutation. Emit safe counts/timing only. Host tests must use real IO runner where FakeAsync otherwise hangs.
- [ ] Run focused tests/analyze, source diffcheck, commit ownfiles; report exact red/green commands/exit/native hashes, commit/filehashes, lifecycle decisions and remainingissues. No fullsuite/build/install by worker.
- [ ] Root independent SPEC→QUALITY review, resolve blocking originalscope findings before sharedfull.

## Task2: Frozen verification and emulator delivery

Root owned docs/pubspec/AppConfig/iOS metadata parity as version contracts require; no iOSbuild. Candidate0.4.50+2219 subject fresh installed/source reservation check. Preserve signer75b31, x86_64debug.

- [ ] Focusedboundary/UIregistry impact checks and verify.ps1environmentpreflight; fullFlutter/analyze only afterTask1reviewPASS, save source/lock/native identity.
- [ ] Build conventional-rebuilt/fixed-signed synthetic native integration target; drive test on emulator with real entry delays and assertions, preserve realuserdata. Record outcome honestly. Reuse identical host gates.
- [ ] Build ordinarymain source once, Apktool2.12.1→zipalign36-P16→fixedsign→semantic/nativeasset/manifest/signature checks. RawAPK is intermediate.
- [ ] install-r ordinarymain; compare UID/firstInstall/version/baseAPKhash; coldlaunch actualUI observation, no humanmessage sending. Keep native synthetic test evidence separate from realuserdata smoke and Debug performance separate from profileperformance.
- [ ] Update task/currentstate/report, timings and links; clean onlyownedmaps/processes. Keepworktree/artifacts; no productionpublish/merge requested.

## 2219 真冷启动反例与修正决定（2026-10-17）

普通 main 0.4.50+2219 已保数据安装，成品 SHA256 283cbcf18f90e1dbd81c65edb19154f11693e84789057d07d0b8fea1a258066b，固定 75b31 签名，UID10090/firstInstall 不变。但实际账号冷启动录像 main-cold-video-2219 明确 FAIL_PERCEIVED_LOADING：仍出现启动、本地聊天及本机会话加载页面。6093PASS/9SKIP 与原生合成入口 PASS 均不覆盖该性能反例，不能记作用户目标完成。

Ruling: 采用独立有界 AEAD 首屏缓存，替代首屏依赖整库 SQLCipher 查询。用户四项明确授权支持此修正。保留原整库 preflight、SDK、业务认证与发送权限链在后台；本地展示能力不能充当通信权限。先冻结存储/失效/接口边界并独立领域与质量安全审查，再实施及真冷启重验。详见 task-3-diagnosis.md。下一步：独立缓存设计审查与行为 RED（持有整个原整库 preflight，而非仅 device-key 恢复）。

## Task4: Independent encrypted first-screen projection

Task1 and Task2 produced installed2219 but FAILED actual cold-start UX. Do not repeat them unchanged. Execute [Task4 brief](../../verification/artifacts/2026-10-17/startup-local-projection/task-4-brief.md) after independent DOMAIN then QUALITY/SECURITY approval of [ADR](../../adr/2026-10-17-bounded-encrypted-startup-projection.md). The ADR and Task4 override earlier SQLCipher-only first-frame and pre-display Olm requirements specifically for verified derived-cache display; full-store/Olm and dispatch checks remain mandatory in background. No authenticated SDK state is fabricated.

Task4 ownership/interfaces/RED/GREEN and invalidation matrix are frozen in those two files. Same single product writer startup_pipeline, independent reviewer read-only; root versions/build/device/docs. Following implementation review, Task2 frozen verification/delivery is repeated only for changed final input, with a new reserved version. Candidate2219 remains installed until successor is ready; no false completion.

## Task4 final real-cold correction (2220 observed failure)

Real-account video `main-cold-video-2220/visual-verdict.json` overrides synthetic acceptance: frame024 startup loader and frame026 conversation loader precede cached content. Cache-hit4599ms/content5733ms/fullSDK10616ms establishes ordering only. Same-Room last-event restoration is also incomplete and loses list preview/time/order.

Approved implementation clarification within original user authorization: sole product writer startup_pipeline owns main.dart, session_bootstrap_controller.dart, installation_startup_gate.dart, matrix_home_page.dart, existing Matrix wrapper, SDK client.dart and corresponding focused tests. Gate must retain native launch surface during minimum secure cache admission, prepublish already-read projection snapshot and settle local eligibility before exposing real AppHome. No fake content/identity, no blank Flutter substitute, no wholeSDK wait. Cache miss releases existing safe normal path. An 8-second start/admission budget abandons the fast path for that attempt and exposes actionable recovery; late result must not publish or start duplicate recovery, retry/dispose ownership must be tested. First content publication/background release must correspond to a frame actually sent to engine, not a deferred/offscreen callback. Time includes admission and is reported honestly; this is not a claim of zero engine latency.

Canonical lastEvent must be adopted onto the same retained Room under baseline/live-event/history-generation guards before projection retirement. Tests must include persisted last_event without timeline rows and held optional preview repair. Every visible frame from actual main is inspected using actual rendered strings/types; previous prefix-only exact-text assertion was insufficient. Slow admission (>1s), held entire preflight/opener, miss/error/timeout/dispose/retry, actionable list/room/queue and canonical preview/order all require red/green evidence. Independent SPEC then QUALITY review before rebuilding native/main. Prior unmodified gate inputs reused by impact analysis; real-account cold video remains required.

2026-10-17T08:58:14.0668085+08:00 Additional observed first-room-frame gap: async SharedPreferences/logicaltimeline beforecontroller can paintroomloader. Approved narrow preparedcachedentry ownership RoomPage +existingcentralnavigation, samelease/timeline transferonce, cancellation/accountswitch/doubletap disposaltests; list staysinteractive untilpreparedpush. No fullSDKdependency or cacheprivacycheckbypass. Native4scenarioIDs retained with explicitfirstvisible/noLoading frame assertions.


2026-10-17T09:03:18.0910526+08:00 Watchdog clarification supersedes earlier startApplication-only timer: enhanced actual-main gate uses one8second attempt envelope from_reconcileAndStart, covering prepare/reconcile/admission. Legacy gate callers retain existing behavior. Knowncachemiss cancelsbudget/releasesnormalUI; timeout retiresattempt with Retry, latecompletion cannotstartnextstage/publish, retries owner-isolated. No securitycheckbypass.


2026-10-17T09:14:15.1836577+08:00 Room hypothesis correction: source awaits alone were not a verified visible-frame defect. Warm actual-main firstroom audits PASS; forcedRED reset SharedPreferences singleton aftermainready, a condition notestablishedinproductioncachehit. That log is INVALID_PRODUCTION_REPRO, notacceptedbehaviorRED. RoomPage/AppHome ownership expansion suspended; noproductionedits made there. Trace remainingcacheawaits; keep per-frame roomassertion. Scope remainsconfirmedmainfirstframe +canonicalpreviewhandoff unlessactualIO evidencefound.

## 用户2220反馈补验（2026-10-17）
真实已恢复账号入房录像确认路由动画中仍显示本地消息加载页。先前RoomPage暂停决定被这一真实反例替代。继续唯一产品实施者及独立SPEC→QUALITY审查：先分别确立真实DB等待入房、群头像成员/图片缓存、启动网络未知状态的RED；冻结最小产品文件范围；实现首屏缓存交接、头像连续展示及准确网络提示。不得仅删文案留空，不允许把SDK未就绪当断网，也不能屏蔽真实网络错误。root负责设备证据、版本与构建安装。原验收保留但不作为新增路径通过证据。

Ruling: AppHome中央路由在真实本地头/隐藏过滤准备完成后推入RoomPage，准备资源一次移交，失败/取消/切账号清理；RoomPage首帧使用准备数据，不新增整页loading或空白替身。所有现有入房入口仍沿中央路由。保留即时SDK缓存路径；普通完整恢复路径纳入native验收。SessionGate只对真正offlineAuthenticated显示该离线banner；缓存恢复状态不伪造联网或派发权限。头像方案独立审查后追加，不提前放宽媒体边界。

头像扩展设计审查PASS已落实ADR追加条款。startup_pipeline独占新增产品范围：core/startup_projection/startup_projection.dart、features/matrix/matrix_e2ee_client.dart和matrix_user_avatar.dart、ui/foundation/avatar_cache.dart及必要ui/components/user_avatar.dart，加对应tests/native入口。先RED后GREEN，现有账号identity命名域/清理保持，禁止新namespace和unscoped回退；详细验收遵循task4-avatar-design-review.md。原生报告新增完整恢复后入房、群头像成员、无误离线断言，真实账号新cache形成后第二次冷启动必须复查。

头像接口范围补充：允许features/matrix/avatar_url_resolver.dart纯canonical authenticated thumbnail URL构造公开函数及对应test，复用既有_thumbnail规则仅做磁盘键，禁止假token/网络请求/伪loggedin；local/full同URI输入应选同URL版本。

真实2221交接修正：首帧头像正确但local→full清空已paint FileImage，远程provider首次解码透明露出灰背景。仅MatrixUserAvatar/UserAvatar及对应tests可改：当前owner/scopedidentity/effectiveURI一致时保留已成功paint图片作widget内桥接，完整provider就绪后正常显示；撤销/跨账号/URI变更或移除立即失效，不新增全局缓存。RED/GREEN逐帧验证图像和mosaic成员映射，native报告新增avatar_handoff_continuous。审查后重建2221修订；先前真实cold失败保留。

交接验收澄清：原nonempty场景解除SDK时位于RoomPage，offstage列表不能证明可见头像连续。因此保留原4场景及原队列/锚点断言，增加第5场景actual-main-avatar-handoff，始终显示列表跨SDK解除，逐帧证明成员稳定和图片不断档，networkheld/after均0，avatar_handoff_continuous=true。root runner已按5IDs及单独handoff证据门禁更新，旧4场景结果仍保留其原范围。

交接范围最终补充（7ada9f1d）：真实第五场景证明 MatrixHomePage 把 previewOnly 变化误当成 owner 变化并清除 row GlobalKey，故授权该文件与既有 matrix_home_snapshot_refresh_test.dart。仅同 owner 模式切换保留 key/自建 ProfileRepository；真正 account/API/Matrix/identityCache 更换仍清理。组件已paint图片桥接与父级状态连续性共同通过第五场景；独立 SPEC→QUALITY 审查通过。

取消重入竞态补充：真实SQL held→切tab/返回→再点同房的意图不能并入已取消opening。授权MatrixHomePage/AppHome/RoomNavigationCoordinator及既有entry/coordinator tests：取消只退休尚未register的attempt，token保护晚到register/push/error/finally，不影响active或跳过lease清理；origin非根route popped退休仅匹配pending，pre-association前捕获origin/intentepoch。移除列表重复去重后由coordinator统一处理doubletap/anchor。真实RED、相关回归及独立SPEC→QUALITY后重建，两次native失败保留。
