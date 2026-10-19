# Android0.4.63+2232 ordinary release

**当前状态：已于2026-10-19 14:27:29+08发布并完成后验，REL1–REL5通过。实际ARM64手机安装及旧版手机可见弹窗仍是单独设备观察项。**

Initial preparation snapshot: started 2026-10-19T13:54:31.711787+08:00. User explicitly authorized Android new update notification and popup after AS6 real recipient acceptance. Root sole writer; canonical interactive-cache-startup. Current HEAD1bf84dc24ec4bbcbb7f72f990c7e1d86639e8515, accepted runtime2ace unchanged. Current public ARM64 alias readback2216; exact ten settings and CDN inventory still collecting. No production write yet.

Own this task/plan/report/own current-state entry, task artifacts; later exact two-file frontend backfill only. Do not modify mobile source or other primary changes. Approved plan: [Android2232 release](../../superpowers/plans/2026-10-19-android2232-release.md).

| ID | Acceptance | Status |
| --- | --- | --- |
| REL1 | Verified same-signature ARM64 release from accepted runtime | PASS20buildsteps/fixedsigner/ARM64 |
| REL2 | Impact-bound shared/native evidence and ordered domain→quality review | PASSorderedreviews/35guards/exactPGreuse/impactclosure; originalfailuresretained |
| REL3 | Fresh baseline, immutable upload/CDN, audited ordinary Android update/popup | PASSPUBLISH_PASS/3audits/immutablefile/CDN |
| REL4 | Real API/readback/public small metadata, iOS/minimum/other services preserved | PASSactualplatform+legacy/API/publicTLS/preservation; phonepopupunobserved |
| REL5 | Exact source/doc synchronization and owned resource cleanup | PASSexact2filebackfill/docsync/ownedSSHcleanup; portsreleased |

Known limits: shared original fullFAIL6367/9/2 closed through corrected fixture27cases/analyze0 but not relabeled; iOS baseline3video host failures not Android release blockers; actual ARM64 phone and old-release popup not yet observed; original full >10s switch latency not fully remeasured; historical missing-key messages remain unrepaired. No new real test send authorized or required. Prior libcrypto16KiB/static/security-software limitations retained pending actual final native comparison.

Next: ordered DOMAIN then independent QUALITY review of freeze fb7399dd19140acca352f9823ebb13517c771280ac7bd515e71366bf9cb827c3 before first remote mutation. Build completed05:54:31Z→05:59:11Z (4m39.84s); fresh exact baseline matches2216/2215/min3/35containers/19routes. No repeated shared full gate and no production service deployment. Evidence docs/verification/artifacts/2026-10-19/android2232-release/; large build outputs in matching D:/ directory.


## Final production acceptance

REL1PASS: formalARM64/fixed75b31/20buildgates. REL2PASSwithinimpactclosure: original failures retained,35publicationguards and exactPGreuse, ordered frozenDOMAIN→QUALITY. REL3PASS: immutableAPK/CDN/alias/twostatic/3Androidsettings+audit. REL4PASS: actualplatform+legacyroute/audit/HTTPsmallmetadata and fresh preservation; realphonepopup remains distinct. REL5sourcebackfillPASS: exact2files/tworoots, documentation/cleanup receipt recorded at closeout.

Published 2026-10-19T06:27:29.285762+00:00; audit 2026-10-19T06:27:31.577518+00:00; backup`/opt/starchat/docs/verification/artifacts/2026-10-19/android2232-accountswitch-20261019-2232`0700. Artifact`87caa95520916b700445dc0ace1e53836c317dd08cf0f9695233262de08fe0c8`/73655386B, source`1bf84dc24ec4bbcbb7f72f990c7e1d86639e8515`. Details [publication report](../../verification/2026-10-19-android2232-release.md). No more production writes planned. Do not replay this operation; uncertain future rollback requires fresh settings/alias/static/trace inspection and must not erase audits. Older public2216file retained; already-upgraded clients do not automatically downgrade.
