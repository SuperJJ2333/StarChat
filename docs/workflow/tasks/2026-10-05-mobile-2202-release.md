# Android 2202更新与iOS原包交接

用户直接授权Android更新弹窗及iOS原始IPA供签名；iOS分发不在本次范围。承接[修复任务](2026-10-05-global-search-otp.md)和[计划](../../superpowers/plans/2026-10-05-mobile-2202-release.md)。

| ID | 结果 | 证据 |
| --- | --- | --- |
| R1 | 完成：实时HK/SG基线、build未占用 | publish-prep/hk-live-snapshot.json、sg-live-snapshot.json |
| R2 | 完成：正式ARM64固定重建/签名 | android-release/run-20261005-052238/artifact.json |
| R3/R4 | 完成：更新/下载/十键隔离/3审计/双路 | hk-publication-result.json、hk-final-check.json、hk-route-audit-final.json、cdn-final-check.json |
| R5 | 完成：同源原始IPA交接，未iOS分发 | ios-candidate/candidate-identity.json，CI37235412773 SUCCESS |
| R6 | 源回填及证据完成，收尾集成 | frontend522PASS；有序release-review.md；main-integration.json |

05:18–05:22+08恢复；05:22:38–05:26:49正式构建；05:24/05:28实时生产冻结；05:52:27实际发布。CI05:16:28–06:01:13完成；15:20–15:21最终读回和IPA取回校验。暂停期间不算主动工作时间，总主动时长未捕获。30offline+6PG PASS、frontend522PASS，复用未变mobiletree5455PASS/analyze0及18/26恢复门禁。verify缺本地env不执行。

详细成品、原包链接、摘要、风险边界与恢复路径见[报告](../../verification/2026-10-05-mobile-2202-release.md)。下一步：用户企业重签后回传最终IPA，另行检查再按授权发布；无需重做本次构建。
