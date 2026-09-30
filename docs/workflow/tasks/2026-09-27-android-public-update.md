# Android 正式版本及更新弹窗

## 恢复入口

- 用户授权：2026-09-27“请你推送Android版本更新，推送更新弹窗”，允许正式Android包、下载入口和Android更新设置发布。启动诊断新API候选仍待另行审批，不把移动发布扩展为服务部署。
- [计划](../../superpowers/plans/2026-09-27-android-public-update.md)，工作树C:/Users/Administrator/.codex/worktrees/friend-video-followup/StarChat；移动起始05a2d950，已核验启动诊断1764文件输入/Flutter4775PASS/9skip/analyze0。
- 所有权：root版本/工件/静态/文档；独立版本工具agent仅bump脚本/tests；服务器预检agent仅证据。保留并行SG/S3/其他backend/frontend修改。
- 当前：Android **0.4.16 / 2185 ARM64** 已于2026-09-27 **17:39:44.552+08**正式发布，更新弹窗元数据已生效；服务器及工作站HTTPS检查、三条审计和独立发布证据复核通过。
- 下一步：用户设备下次启动/恢复或“关于→版本更新”检查时获取新版；真机弹窗/安装和功能反馈尚未核验。授权发布范围已完成，启动诊断新API及iOS发布仍待各自授权。

## 验收台账

| ID | 预期 | 当前证据/缺口 |
| --- | --- | --- |
| A01 | Android含账号资料/设置热缓存、好友三渠道精确/容差搜索、blur及视频修复 | 1764项冻结输入及正式工件来源核验；设备功能反馈待验收 |
| A02 | 全链路性能/网络监控增量保留并启用 | 源码保持，正式构建显式CHATFLOW_PERFORMANCE_METRICS=true |
| A03 | ARM64常规重建/固定用户签名、递增版本 | 0.4.16/2185、固定75b31c证书、独立重建语义检查通过 |
| A04 | 不可变下载与Android更新弹窗 | final.apk SHA3f7c6c48…已上线；ARM64别名及三项设置读回通过 |
| A05 | iOS设置不变、审计与回退、严格TLS | 十项设置仅Android三项变化；三条审计/0700备份/双侧TLS通过；真机未验收 |

## 版本与计时

旧线上Android为0.4.7/2172；本次正式0.4.16/2185高于上轮Debug2184。iOS仍0.4.7/2173。预检17:17:19+08；构建17:23:57–17:29:33+08；发布命令17:39:33.930–17:39:47.162+08；工作站TLS17:40:29.490–17:40:31.944+08；持久备份与17容器读回17:41:12.085+08。未完整记录初始总起点/等待分解，不能编造总工时。

## 交接

不重建Matrix身份、不清数据、不提高最低支持版本；不分发签名材料、不部署API或迁移。Android正式ARM64包不自动覆盖模拟器上独立debug包。发布阶段只HEAD/小型元数据，构建阶段完整工件验证保留。

## 17:29+08 最终构建/审查与上传阶段（历史过程）

移动源码b36a291139fd236e9cd0dad8e22d97d148bcefbb/1764输入1fce8a7d…，0.4.16/2185 ARM64最终包81,505,310bytes/SHA3f7c6c48…，固定75b31c66证书。实际源码构建17:23:57–17:29:33+08，首轮开发注册失败按既定规则修正，后续构建/重建/签名/独立25,346类及338资产检查退出0。规格和质量/安全工件审查PASS；releaseJSON575b6f62…生成，Androidprepare仅3设置。

版本工具15PASS，版本/update专项33PASS/3旧断言FAIL→36PASS，固定522锁未升级。完整Flutter4775/9skip/analyze与仓库已验证门禁按3项影响范围复用。五项版本/工具/test源码漂移保护回填。记录初始offline pub镜像导致的未采纳升级，恢复原锁后显式pub.dev解析并核验SHA。

服务器0700任务目录只上传，尚未发布或更新弹窗。操作包装器安全核对发现默认HEAD重定向可能转GET，正在添加任务内禁止重定向适配及专项验证；不改既有publisher源、不重复APK构建。此前8项保护测试及上传SHA留存。下一步关闭操作复核后，执行已经授权的Android包/别名/三设置审计发布。

操作P2已以禁止重定向HTTPS适配及所有publisher请求显式注入关闭；20保护测试/独立安全复核PASS，最终wrapper6e657d6c…，publisher45e02保持。上传本地/服务器APK3f7c6c48…/81,505,310bytes、record575b…及执行输入哈希一致，惰性服务器调用证明无修改。root已依据现有用户Android授权交付执行，当前生产结果待回执；无新API/iOS发布许可。

## 17:41+08 发布完成

生产结果ANDROID_PUBLICATION_PASS/PUBLISH_PASS，命令退出0。不可变APK及latest-arm64别名上线；只更新app_latest_version、app_latest_build、app_apk_url，审计于17:39:41.111+08提交。全部iOS/双方minimum3/notes、其他ABI别名和共享静态保持。API e880ec8e、worker15659d6c、schema0090及17个生产容器身份保持；无需回退。

最终包SHA256 **3f7c6c48101b49b05d216b21c367ac405d1a0f54d774a2978b020f18227b0187**，81,505,310bytes；release记录SHA575b6f62…，发布结果SHA40a1995f…。三条审计ID、严格TLS/旧2172可用、0700备份与受限恢复步骤见[服务器发布记录](../../verification/artifacts/2026-09-27/android-public-update/server-publish/report.md)。[独立发布证据复核](../../verification/artifacts/2026-09-27/android-public-update/security-review/publication-closure.md)19项比较通过，无新增网络/重复测试。临时SOCKS PID26660已关闭。

固定签名APK及范围内五项版本/工具/test源码、最终文档和所需证据已回填主目录；并行任务保留。未进行Git远端推送、真机安装或声称全部运行中设备已出现弹窗。最终交付见[验证报告](../../verification/2026-09-27-android-public-update.md)。
