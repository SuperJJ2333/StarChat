# Android0.4.19/2188正式更新已发布

用户本轮明确授权新Android部署与更新弹窗。实际发布2026-09-27T22:14:48.550551+08:00，ANDROID_PUBLICATION_PASS / PUBLISH_PASS，命令退出0。

| 项目 | 实际证据 |
| --- | --- |
| 版本/build | 0.4.19/2188 |
| 移动源码 | f433381a14d4549b25001059870857d1bfe57a42，1779输入仅版本两项变化 |
| 包名/ABI | com.liuhetong.mobile / arm64-v8a / release非debuggable |
| APK大小/SHA256 | 81,505,310 / aa402236aa2dbf06c5322358c6f8ad66e50f06ab5487bc08871ae34934d5e220 |
| 固定签名证书 | 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff |
| URL | https://www.liuhetong888.com/downloads/ChatFlow-0.4.19-build2188-arm64.apk |
| 别名 | latest-arm64.apk → ChatFlow-0.4.19-build2188-arm64.apk |

## 范围与验证

包含已验证验证码拒绝释放输入、锁屏门槛、消息与索引/历史搜索性能修复，以及固定错误细类/请求阶段/随机UUID诊断。实际libapp与源包一致、与本地2185不同，并含四项新诊断固定标记；标记不是行为全量验证。原历史2184的58/15根因仍未知。

仅三个Android键变化：app_latest_version/build/apk_url。iOS0.4.7/2173、双方minimum3/notes、其他ABI别名及三个静态hash保持。schema0090和17个starchat生产容器身份/image/start/restart/status保持；API仍e304、worker0e011。此前诊断freeze的29是含隔离实例的总容器，本次17按实际生产名称记录，不能混用。无API/worker/迁移发布。

版本Python31、Flutter21、publisher包装器20通过；先独立规格后安全审查PASS。共享完整门禁按1777项不变输入复用既有network-failure任务：原全量exit1与相关失败闭环保留，不声称重跑全量exit0。正式源/最终ABI及manifest、Apktool2.12.1、36.0.0对齐、单固定v2/v3签名、25,346类/6DEX语义、338native-assets、474资源、锁屏9类门禁均通过。

首轮编译为已知integration_test生成注册冲突，生成文件校正后retry0，失败日志保留。构建外层相对计时文件路径因工作目录切换失败，绝对任务证据闭环；准确构建起点未持久化而未知，完成2026-09-27T22:08:09.8157502+08:00，Gradle耗时见build-stage.json。junction替换组合命令被自动策略拒绝且未执行，保留已有独占编译输出；正式成品/日志/解包在新task独立RunId。

双侧严格TLS/无重定向：新APK/alias/旧2185/iOS安装HEAD，live/ready200和双端未授权401。仅小型JSON/HEAD，0APK GET。旧/新APK均既有application/octet-stream/no-store；首轮仅APK-specific MIME假设exit1已保留，闭合两种合法类型并拒绝HTML/未知类型后实际8探针通过，未改生产配置或重复发布。两轮自有SOCKS已关闭。

## 审计与持久备份

| 键 | 成功审计ID |
| --- | --- |
| app_apk_url | 92fb6eb3-7dad-4be0-9aec-69d161819b27 |
| app_latest_build | 9fc57df7-bbf0-412c-a335-dfba345605fe |
| app_latest_version | ba151ba5-8ff8-4149-b3d6-304bc6a37107 |

0700备份：/opt/starchat/docs/verification/artifacts/2026-09-27/android-public-diagnostics-update-2188-20260927T141437Z；before/after与本次私有前态和读回一致，当前设置/别名/static及容器再次核实。前态：/opt/starchat/releases/android-public-diagnostics-update-2188-20260927/state-20260927T141437Z.json。回退先确认本次revision仍当前，仅旧三键经SettingService审计恢复、ARM64别名CAS恢复；保留不可变包/审计，不能盲目覆盖后续发布。无需回退。

上传：2026-09-27T22:10:43.9723472+08:00→2026-09-27T22:12:42.8681610+08:00，exit0，stage0700 SHA/bytes完整匹配。发布：2026-09-27T22:14:33.7835324+08:00→2026-09-27T22:14:50.1074679+08:00，exit0。工作站探针：2026-09-27T22:16:51.2739646+08:00→2026-09-27T22:16:53.6252483+08:00。未准确记录总起点，精确总墙钟未知。

设备启动/恢复或关于页检查更新时获取新版本。真机弹窗/安装/功能反馈未验收，未分发iOS或发送其他推送。来源、工件与服务器证据均独立记录。见release.json、server-publish/publication-result.json/persistent-proof.json/workstation-tls.json及任务记录。
