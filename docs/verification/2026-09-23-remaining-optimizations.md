# 其余优化增量验证（2026-09-23）

当前状态：最终隔离候选验证通过，源码已回填主目录，未构建安装包、未发布。工作树 `.worktrees/remaining-opt`，基线 `7140ace247d1874fea0285914c5696e3c0212370`；继承上一批已验证红包查询过滤改动。

## 改动与收益边界

- 朋友圈缩略图按实际 DPR 和裁剪显示计算解码尺寸，保持纵横比；最多 1,048,576 像素、单边4096，不放大原图。测试中4096×1024原图解码为2048×512，RGBA像素占用按4字节计算由16MiB降为4MiB（75%），这不是整机内存或FPS测量。原图查看、下载缓存和账号隔离保留。
- SDK 主文件成功、缩略图暂时失败时只重传缩略图。红测原主文件上传2次，修复后1次；保留加密描述、MXC、相同事务 ID 及单次事件发送。不是字节断点续传或进程重启上传恢复。
- 诊断复用既有认证、16KB限制和每分钟批量通道，增加前台 build/raster 超预算帧的分子/分母。旧服务端422会话级停用新增字段、保留普通事件；换账号/迟到结果隔离。正常帧只作为分母，不上传聊天或硬件身份。它测量采样超预算率，不是精确丢帧数量。
- 文本 Outbox 保留既有三次服务器重试政策，持久化跨重启预算与期限，使用原子认领和拥有者结算。覆盖账号切换、页面销毁、未知结果、重复唤醒和迟到失败；retryCount 是累计认领次数，serverRetryCount 才是服务器重试预算。SQLite 只加列升级至 schema2，旧客户端可能不能打开新版库，回退应前向修复，禁止清空待发消息。

## 已取得证据

统一日志目录：[remaining-optimizations](artifacts/2026-09-23/remaining-optimizations/)。

| 覆盖 | 命令/结果 | 日志 |
| --- | --- | --- |
| 缩略图最初红测 | 缺少降采样，3预期失败 | thumbnail-red.log |
| 缩略图规格/质量审查后的红绿 | 1080期望/540实际失败；cover修复33通过，exit0 | thumbnail-cover-red.log / thumbnail-cover-green.log |
| 上传阶段复用红绿 | 1失败3通过；修复22通过 | upload-red.log / upload-green.log |
| 帧统计API红绿 | 1失败43通过；修复44通过，exit0 | diagnostics-api-red.log / diagnostics-api-green.log |
| 帧统计客户端红测 | 缺少 recordFrame 编译失败 | frame-red.log |
| 最终诊断/上传联合定向 | 34通过，exit0，覆盖封顶、失败重试、账户切换、在途快照、120Hz/后台不计数 | diagnostics-upload-green.log |
| Outbox 红测 | 32通过3预期失败：v1字段、错误认领、页面销毁后预算 | outbox-red.log |

工具：Windows10.0.19045，PowerShell7.6.5，Flutter3.44.9/Dart3.12.2；Python3.12。未升级依赖，pubspec.lock保留原内容。Flutter命令使用 `--no-pub`。`upload-evidence.json` 记录该批初次绿测输入，随后测试 import 的 lint 修正由联合定向测试覆盖；最终整合输入另录。

## 审查与未完成事项

图片/上传/诊断先规格符合性后质量安全审查；质量审查指出 fit 缩略图会模糊，已改为 cover-aware 且复审关闭。受保护设计提案已完成同序审查，但不表示获得用户批准或已实施。

本轮 `scripts/verify.ps1` 在业务阶段发现11个头像夹具失败：模块收集时固定的 NOW 在长测试中超过了15分钟令牌有效期。未变源码单跑13项通过；模拟收集后16分钟的用例复现401，新回归复现 ACCESS_TOKEN_INVALID。只将测试签发时间改为夹具执行时刻后，模拟延迟的完整模块14项通过；生产鉴权没有改动。

按交付工作流的证据复用规则，比对上一轮 `rp-claim` 已通过候选与本轮634个后端/测试/verify文件的原始SHA，只有诊断API与两份测试不同（`backend-evidence-reuse.json`）。未变业务与worker复用上一轮完整2622通过/65跳过及真实PG6项证据；变化范围以本轮诊断44项、延迟头像14项及OpenAPI/启动检查覆盖。没有升级Python依赖。约37%进度后主动停止重复API进程68220，外层verify exit1、子进程-1（取消）；`verify-cancelled.json`与原日志保留，**本轮该完整脚本不算通过，不合成一个新全量通过数**。

本轮此前已完成infra144、getui28（2既有弃用提示）、bot9；后续步骤按原verify逐项续跑，`verify-remainder.ps1` exit0：mobile108通过/1跳过、UI32组件/398页面、AST266、API导入、Alembic唯一head0087和离线升级、OpenAPI与Compose均通过。最终候选Flutter全量3912项通过（4分48秒），analyze无问题，Outbox质量复审已关闭全部问题。最终mobile108通过/1跳过、UI32组件/398页面通过。

现有 Starlette/httpx 弃用提示与视频测试替身的降级日志有记录，未通过忽略断言或升级依赖隐藏它们。没有千人加密群实压、真实设备内存/FPS、Android/iOS安装验收、生产启用证据。受保护项目与现有实现的对应清单见[增量计划](../superpowers/plans/2026-09-23-remaining-optimization-increments.md)及[设计提案](../superpowers/specs/2026-09-23-remaining-protected-optimizations.md)。

## 最终并发审查与主目录整合

Outbox 规格审查后，质量审查发现重复到期唤醒、准入失败失去重试和迟到失败覆盖其他拥有者三类问题，均有红绿回归并关闭。最终121项定向通过，analyze无问题（10.1秒）；见 outbox-admission-race-red.log、outbox-admission-race-green.log、flutter-analyze-admission-final.log。此前3910项全量通过早于最后竞争修复，仅作阶段证据，最终冻结候选另跑全量。

主目录同时出现独立的登录/客服/钱包改动。此次只回填本任务拥有的无冲突文件；OpenAPI由主目录合并后的API重新生成，不覆盖其他契约。头像测试已有相同运行时钟修复及1小时延迟回归，保留主目录版本，参考同日 test-collection-clock 报告，不重复加入16分钟同类测试。隔离候选的全量结果不冒充并行主目录的全量结果。

最终候选全量日志：flutter-full-final.log（exit0，3912）；输入SHA见 final-inputs.json。主目录23个源码/测试文件逐项复制并记录SHA（integration-source.json）；合并OpenAPI重新生成并check通过。主目录并行修改不包含在候选全量证据中。

主目录整合验证：169项Flutter定向测试通过（14秒），analyze无问题（33.8秒），23份源码/测试SHA与候选一致；日志 main-focused.log、main-analyze.log，记录 main-integration-check.json。

补充主目录检查：诊断API单独44项通过（main-diagnostics.log）。合并运行诊断+mobile的额外扫描遍历主目录历史构建/文档产物，超过10分钟后停止已核验PID3236，exit−1，记为取消而非通过（main-scan-cancelled.json）。本任务完整mobile隐私/边界门禁以最终隔离候选108通过/1跳过为依据，回填23份源码SHA一致；不宣称主目录其他任务的未测产物通过本次安全扫描。

下一步：批准受保护设计后逐批形成ADR及实施；构建、真机与部署仍未执行。源码和文档已回填，工作树保留以便复核。

## 后续发布状态更新

2026-09-23 19:00：诊断接收端已按单文件增量发布，客户端四项对应代码未构建新包。以[生产发布报告](2026-09-23-diagnostics-release.md)为准；上文“未发布”为当时历史状态。用户明确安全/账号恢复/容灾等剩余提案暂不处理。
