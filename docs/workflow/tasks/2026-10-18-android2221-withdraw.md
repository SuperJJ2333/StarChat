# Android2221正式分发撤回

用户授权：2026-10-18「先暂停Android0.4.52（2221）正式版的更新弹窗推送和下载入口，回退为上一个公开的Android版本」。目标为0.4.47+2216，仅分发配置回退，不对已安装客户端降级。

执行工作树interactive-cache-startup，起始HEAD16049d4a/mobile clean；root独占本任务产物、两静态回填和本任务文档。批准范围及步骤见[计划](../../superpowers/plans/2026-10-18-android2221-withdraw.md)。证据目录docs/verification/artifacts/2026-10-18/android2221-rollback。

| ID | 预期 | 状态 |
| --- | --- | --- |
| WD-01 | 更新接口恢复2216/旧说明，2221停止推荐，iOS/min不变 | PASS：HOST02:26:14；真实路由及三审计02:27:21 |
| WD-02 | 官网/registry/latest恢复2216，2216双线路可用 | PASS：TLS HEAD/精确静态/public-r2全部true |
| WD-03 | 2221 origin/CDN直链撤下，包私有保留 | PASS：origin无APK/旧链接200HTML；CDN403；私有SHA保持 |
| WD-04 | 新审计、私有备份、容器/schema/其他路由不变、源码回填 | PASS：0700/三审计/35容器/19路由保持/两工作区两静态CAS |

02:23+08新鲜快照：Android2221/iOS2215/min3、35容器/schema0095、20CDN路由。2216原包SHA db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039、73,262,170B与原发布完全一致，旧两静态/十设置备份有效。快照工具首轮代码生成错误exit1（无生产写），修正后HK/SG采集成功。当前完成计划冻结，下一步8专项、规格符合性后质量安全复核，再执行受保护回退。

服务器备份计划/opt/starchat/docs/verification/artifacts/2026-10-18/android2221-withdraw-20261018，trace android2221-withdraw-to2216-20261018；SG备份/home/ec2-user/starchat-android2221-withdraw-20261018。未知结果停止，先读回，不自动重放。此操作不重建APK，复用未变的旧包身份/发布证据，生产仅作HEAD/小元数据验收。

最终状态：已完成撤回，公开Android0.4.47+2216/iOS2215/min3。8专项及规格→质量root操作复核通过；未声称独立审查或真机弹窗可见验证。Windows长度超限在启动SSH前失败，改私有payload流式SHA校验后host/CDN各执行一次成功。首次公网门禁因预期旧直链403/404但实际HTML200而失败，已保留；服务器APK不存在/HTML小页面/CDN403证明安装包已撤下，r2全部通过。没有修改全局缺失路径路由。自建隧道已关闭，产品源码及模拟器未动。详细[报告](../../verification/2026-10-18-android2221-withdraw.md)。下一步仅等待用户反馈；重新发布2221需要新明确授权，不能自动恢复。
