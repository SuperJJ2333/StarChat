# Android 0.4.64 (2233) formal update publication

## 恢复入口

User authorization2026-10-22: 发布正式更新弹窗. Status published and verified; device observations remain separate. Root owner; canonical interactive-cache-startup; source 6cbc09d5da26a8443df77d3522fbc22c5856f774. Scope this task/plan/report/own index entry/artifacts and exact two static backfills. [Approved plan](../../superpowers/plans/2026-10-22-android2233-release.md). Updated 2026-10-22T03:20:27.748540+08:00.

## 验收台账

| ID | Requirement | Evidence / result | Device gap |
| --- | --- | --- | --- |
| R1 | Formal fixed-signature ARM64 artifact | PASS20buildgates, exact finalSHA | Physical ARM64 not observed |
| R2 | Current baseline and ordered review | PASS35guards,1716inputs, spec→quality frozen approval | Real-room scrolling not observed |
| R3 | Optional audited update popup | PUBLISH_PASS 2026-10-21T19:19:53.971153+00:00,3audits | Visible popup not observed |
| R4 | Public/platform/rollback checks | PASS TLS HEAD/metadata,401,Android/iOS/legacy,35containers and old2232 retained | None for server scope |
| R5 | Exact source/docs and cleanup | Source CAS two files both roots PASS; cleanup receipt separate | None |

## 版本与证据

Android0.4.64+2233,com.liuhetong.mobile,ARM64, fixed75b31, SHA `77c17e4c96b24569690a80f1954f00acb267b01b407941ffe2b95c51621bf573`, 73655386B. [Publication report](../../verification/2026-10-22-android2233-release.md). Authoritative evidence under canonical docs/verification/artifacts/2026-10-22/android2233-release; large APK under corresponding primary arm64-final-r2. Aggregate verify missing .env, not executed; native limitations retained.

## 阶段计时

Build 2026-10-21T19:05:26.7123948+00:00→2026-10-21T19:12:32.8559114+00:00; actual publication 2026-10-21T19:19:53.971153+00:00; audit 2026-10-21T19:19:58.659725+00:00. Per-phase timestamps in frozen package execution/scroll-20261022-2233. Exact total active time unknown; initial failed freezer and fixture/Windows rename diagnostics retained.

## 交接与回退

Backup `/opt/starchat/docs/verification/artifacts/2026-10-22/android2233-scroll-20261022-2233`0700, trace android2233-scroll-20261022-2233. No further production mutations planned. Next only user-device popup/retained-data/scroll observations if supplied. Before any rollback read fresh live settings/static/alias/audit; use new audited operation and retain immutable packages/history. Owned SOCKS cleanup recorded separately.
