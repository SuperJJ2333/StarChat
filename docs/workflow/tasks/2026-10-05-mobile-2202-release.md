# Android 2202更新与iOS原包交接

## 恢复入口

- 用户直接授权：“请你推送Android更新弹窗，并且给我iOS的IPA安装包给我进行签名”。Android正式发布、弹窗、网站/不可变下载必要步骤获授权；iOS仅候选供重签，不自动企业分发/TestFlight。
- [计划](../../superpowers/plans/2026-10-05-mobile-2202-release.md)，承接[2202修复任务](2026-10-05-global-search-otp.md)。0.4.33+2202；source265a5027/移动tree5cd2a854，与测试b54一致。用户已确认模拟器三项正常。
- worktree C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat，branch codex/mobile-2202-release；root只构建/CI/文档/实际发布，独立actor只publish-prep，不并发修改同一文件/运行Flutter。
- 初始读取05:18+08；主区1372 WIP保全；既有build junction原样复用，不删除历史残留。下一步新只读production baseline与正式ARM64构建。

## 验收台账

| ID | 预期 | 当前证据 | 状态 |
| --- | --- | --- | --- |
| R1 | 实时生产基线/版本占用 | 上轮05:02 Android2196/iOS2194仅历史 | 待读取 |
| R2 | 同源正式ARM64固定重建签名 | debug2202验收不能替代release | 待构建 |
| R3/R4 | Android下载/弹窗/审计/双路与iOS隔离 | 既有2196机制待冻结当次基线 | 待准备/发布 |
| R5 | iOS0.4.33+2202 IPA原包交接 | 自动37235412773 exact265a5027正在simulator-preflight，TestFlight上传关闭 | 等CI，不重复触发 |
| R6 | 证据与源静态一致/保全WIP集成 | 独立任务与计划已创建 | 进行中 |

## 阶段计时和边界

05:18–05:22+08恢复流程及源码/CI/已有脚本定位；主动准备。发布暂无生产写入。原5455全测/analyze0、原生18/26恢复证据覆盖同mobiletree，依现行复用规则无需重复全部用例。新正式包、上传完整性、平台隔离/元数据、签名候选门禁仍必做。整库verify缺本地env仍保留，不导入生产秘密。
