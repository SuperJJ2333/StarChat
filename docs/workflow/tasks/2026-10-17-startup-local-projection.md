# 冷启动首屏本地投影

- 用户授权：2026-10-17四项明确实施要求，延续上一轮模拟器Debug安装；无公开发布/真人发送。
- 状态：2219普通main已安装，但真实冷启动录像FAIL_PERCEIVED_LOADING；源码02c76dcc的全量/原生合成通过不足以覆盖此失败。独立有界加密缓存修正设计中。
- 工作树：C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat，HEAD02c76dcc；版本元数据61909dbf；上一轮产品c29597e0。
- 负责人：root文档/构建/交付；startup_pipeline独占计划Task1产品文件；冻结后独立审查。
- 规格：[首屏本地投影](../../superpowers/specs/2026-10-17-startup-local-projection-design.md)。前序：[2218任务](2026-10-16-interactive-cache-startup.md)。
- 下一操作：冻结独立缓存ADR与生命周期接口，领域及质量安全审查，然后持有整库preflight的行为RED和实施。
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
