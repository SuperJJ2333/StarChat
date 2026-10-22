# Android 2217 官方测试下载

## 恢复入口
- 用户授权：本轮“你可以放在官方的测试安装包下载入口，让我单独下载更新”。仅测试入口，不启用正式更新弹窗。
- 工作树im-reliability，分支codex/android-consent-20261016，源码746f1712、分发起点c59b49e5。所有权见[计划](../../superpowers/plans/2026-10-16-android2217-candidate-download.md)。
- 当前：测试入口已发布，12:59:32+08换页、13:00:34+08交接完成；12:45:25+08开始记录。候选固定SHA385663ac9d6cfb9befc726151c69883ee540fafd705f5cb9037ec85df1d0d8ac，73,262,170B，0.4.48+2217，75b31签名。原构建20门禁及专项证据复用，不改移动源码。
- 下一步：用户已确认2217仍在K80安装时报同名风险，详情只有名称；跟随[调查任务](2026-10-16-android-antivirus-review.md)请求厂商复核，保数据升级结果尚未确认。本次分发操作已完成，不重放上传/发布；临时18977隧道已确认关闭。

| ID | 验收 | 当前状态 |
| --- | --- | --- |
| ENTRY | 既有测试区块指向2217，标明ARM64与测试用途 | PASS，精确页面SHA读回 |
| ARTIFACT | 服务器完整SHA/大小与既有候选相同，官网及CDN可下载 | PASS，完整SHA/不可变文件/CDN Deployed |
| PRESERVE | 正式Android2216/iOS2215、十项设置/别名/其他静态/schema/运行容器不变 | PASS，当次前后核查35容器与所有保护字段 |
| WEB | TLS验证下小页面GET与包HEAD，页面真实SHA与链接一致 | PASS，工作站6项HTTPS检查，服务器HEAD |
| DEVICE | K80覆盖升级/告警复测 | 告警项 FAIL_USER_REPORT：用户确认2217仍报同名风险；覆盖保数据未确认。分发验证通过不等于检测通过 |

证据目录：docs/verification/artifacts/2026-10-16/android2217-candidate-download/。服务器暂存/备份独占android2217-candidate-download-20261016；出现不确定远程写先检查现值，不盲目重放。没有财务或应用服务部署。

## 完成：2026-10-16T13:00:34.764393+08:00
ENTRY/ARTIFACT/PRESERVE/WEB全部通过；DEVICE待K80。2026-10-16T12:59:32.230308+08:00 CANDIDATE_PAGE_PUBLISHED；正式2216/iOS2215/min3/十键/35容器保持。CloudFront Deployed、6HTTPS检查PASS。3候选+8恢复测试共11PASS；Node47/4与基线相同，完整verify缺.env未运行。不可变工件SHA与本地完全一致。见[最终报告](../../verification/2026-10-16-android2217-candidate-download.md)及result.json。

阶段：12:45:25+08开始；12:47:38–45实时基线；12:50:09–12:52:03上传及完整性；12:55:40不可变安装；12:55:56 CDN提交；页面发布与公网结束时刻见收据。未测量的主动时间不估算。下一步用户通过官方测试入口下载2217进行K80复测，不重放本次发布。临时loopback18977隧道关闭状态见tunnel-cleanup.json。

## 后续反馈：2026-10-16 13:22+08记录

用户已反馈2217仍显示a.gray.BulimiaTGen.f，风险详情只有名称。分发验收ENTRY/ARTIFACT/PRESERVE/WEB保持原结论，DEVICE告警项改为失败；尚无保数据升级完成证据。腾讯公开风险库对2216给出同名中风险，对2217返回未知，不能直接推断手机引擎或根因。复核材料已生成、尚未发送，见[跟进报告](../../verification/2026-10-16-android2217-antivirus-followup.md)。本轮没有再次修改下载入口或正式弹窗。
