# 会话可靠性修复双端发布 0.3.97 / 2136

## 授权与恢复入口

2026-09-19 用户明确要求：修复合并 main 并推 GitHub，发布 Android 更新弹窗，提供 iOS IPA 供其企业签名后回传分发。沿用固定 Android 签名和非强制更新，iOS 签名回传前不修改线上 iOS。

前置实现：[会话修复](2026-09-19-logical-conversation-reliability.md)。发布遵循 mobile-delivery-workflow、android-apk-rebuild、mobile-release、app-release-deployment。授权包含发布，不重复征求确认。

## 源码与工作区

实现 e5a85093；交接 bfe61a64；冻结候选 **96637621fc2bf7f09259d62a1f4764eb1188f8ce**（0.3.97+2136）。main 已快进并推送 GitHub；远端 refs/heads/main 已回读精确一致。原远端 b308598d，原本地主分支8051edb5。

根工作区存在其他任务未提交修改。先创建仅本地备份ref refs/backup/conversation-release-main-wip-20260919 和命名stash，在隔离worktree预演5个重叠文件；保留双方新增内容、恢复行原始时间戳、保留新测试覆盖，旧测试的转换器修正已被新测试包含。主分支快进后恢复原有未提交修改；10个未跟踪文件SHA一致，无未解决冲突。备份不推送，其他任务修改不纳入发布。构建在干净的 .worktrees/conversation-reliability 完成。

## 验收台账

| ID | 要求 | 状态 / 证据 |
| --- | --- | --- |
| R1 | 合 main 并推 GitHub | 已完成，远端96637621 |
| R2 | 版本与源码冻结 | 0.3.97+2136；bump_version脚本+版本契约2通过 |
| R3 | Android源码构建、重建、对齐、固定签名 | 已完成，流水线exit0 |
| R4 | Android产物SHA/签名/清单/DEX/资源验证 | 已完成，SHA92ab0158…，签名/语义门禁通过 |
| R5 | APK先发布再更新弹窗，不强更、不影响iOS | 20:06:52已发布；重复apply零新增审计；服务器公网门禁通过 |
| R6 | 同源iOS构建与企业重签IPA交付 | 已完成候选取回/验包；60,499,612bytes，SHA cdfaf354…0a53 |
| R7 | 用户回传后iOS分发 | 等待用户企业签名；本次不提前发布 |

## 基线与测试复用

2026-09-19 19:51 +08线上Android0.3.96/2134/min3，iOS0.3.96/2134/min0；API1539d35。Android SHA7628fbd…26b，iOS enterprise-60a09413，manifest2134。页面Android按钮无版本文案，2134文案属于iOS区域，因此本次不修改下载页/首页/manifest。

实现门禁证据见 [client verification](../../verification/2026-09-19-logical-conversation-client.md)。此次冻结仅增加成对版本号，前轮相关输入未变，复用已有全量与补测；另运行版本契约、实际Android/iOS构建和平台CI。不能将未提交的根工作区当构建来源，也不能把CI取消/未执行说成通过。

## 阶段计时与产物

启动约19:43 +08（首次准确采集19:49:53）；合并预演/备份至19:51；版本冻结/main推送约19:53。后续精确工具时间写入artifacts。产物：docs/verification/artifacts/2026-09-19/conversation-mobile-release/{android,ios,production,integration}。

负责人：root负责Git/整体验收/记录；Android代理只构建工作树及android产物；iOS代理只CI与ios产物；生产代理只生产发布脚本/验证，不共享文件写入。

下一步：收到用户企业重签IPA后，按交接文档核验实际签名/内容/账号存储连续性，再发布iOS。Android与iOS真实设备验证仍由用户进行。

## 补充验证

合并恢复后的root room_page多出一处重复anchor字段声明，独立复核发现后删除重复声明；root三个冲突产品文件Dart analyze exit0 No issues found。未修改冻结构建源。GitHub冻结候选Flutter全量3543通过、analyze无问题；Android debug与完整iOS native compile成功。

## 产物交付

[Android发布证据](../../verification/2026-09-19-android-0397-2136-release.md)；[iOS企业重签交接](../../verification/2026-09-19-ios-0397-2136-enterprise-resign-handover.md)。iOS候选提供给用户，仅AppStore候选签名，必须企业重签后回传，不作为线上企业安装包。

## 发布完成

Android20:06:52 +08已发布；20:07:20重试0新增审计；20:08:12服务器两URL完整SHA/Range/鉴权通过；20:14:33工作站完整SHA/Range/鉴权通过，临时隧道已关闭。iOS候选60,499,612bytes已验包交付，线上iOS仍2134；企业签名回传是R7依赖，非当前已完成分发。

当前全部产品构建源仍为96637621；后续仅文档提交用[skip ci]，按未变输入复用此SHA的成功门禁，不取消或重跑已有CI。构建工作树保留交付文件，不删除IPA/APK。主工作区其他任务修改仍未提交，命名stash/backup ref保留以便取证，未推到GitHub。

## 最终自动验收

候选96637621的三条GitHub运行均completed/success：android-ci35441268045（含3543Flutter测试/静态分析/Android debug/后端基础设施）、iOS签名35441268068、iPhone15兼容35441268083（iOS18.6和26的媒体、历史持久化及新进程恢复）。模拟器诊断任务排除不支持arm64模拟器的mobile_scanner，不能代替扫码或完整插件组合验收；完整生产设备编译另已通过。观察时间20:17:48 +08。最终实际设备覆盖安装/弱网验收未由本任务代测。
