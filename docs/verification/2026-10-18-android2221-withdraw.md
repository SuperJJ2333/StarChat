# Android2221正式分发撤回至2216

用户2026-10-18明确要求暂停Android0.4.52（2221）更新弹窗和下载入口，回退上一公开Android。已完成服务端分发回退至 **0.4.47（2216）**；不对现有安装降级。

## 结果与时间（+08）

- 02:23新鲜HK/SG快照确认前态2221、iOS2215、最低支持3、35容器、schema0095、20条CDN路由。上一公开2216保留包73,262,170B，SHA256 `db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039`，匹配原发布记录。
- 02:26:14 HOST_WITHDRAW_PASS：两静态文件恢复2216；latest-arm64指向2216；十设置事务CAS仅恢复Android版本/build/说明，SettingService写入三条新审计。Android URL、最低支持及全部iOS设置保持。
- 2221源站APK移入0700私有备份，完整SHA `ab4652c05c3d1b1cef7a001ce542ba21a22103b7dd5fd6e709d3efc759b9e572` 保持；未删除包或历史审计。
- 02:26:34 CDN撤回提交；后验为Deployed/Invalidation Completed。精确移除2221一条路径，剩余19条及bucket policy与发布2221之前一致。
- 02:27:21真实更新路由/三审计读回PASS，35容器ID/image/start/restarts、schema、设置依赖、永久guard/probe保持，iOS静态与其他ABI alias保持。
- 02:28:56前公网TLS轻量验收PASS：2216源站/CDN/default alias HEAD200且长度准确、registry和下载页精确2216、registry no-store、iOS清单不变、三类未授权API401。没有完整下载安装包。
- 两工作区download.html及android-release.json按精确SHA CAS回填；自建SOCKS停止，无其他进程受影响。

## 旧2221链接的实际响应

CDN直链为403。原站旧直链为HTTP200、Content-Type text/html、8,528B，源站APK已不存在，因既有缺失路径处理返回HTML而非安装包；未为改变状态码修改全站路由或重启服务。

首次公网检查将“撤回”过度限定为403/404/410，故原站HTTP状态检查失败；原APK实际已不可下载。该失败保留在public-result.json。核实源站文件不存在及HTML类型/有界大小后，public-result-r2.json按“已撤回安装包”的真实语义通过。不得将原站响应说成404，也不声称已关闭用户手机上此前打开的弹窗。

## 验证、来源与恢复

8项精确回退保护测试PASS（另一次同8项复测，不累加数量）；按规格符合性→质量安全顺序做root操作复核，非独立审查声明。未变APK/移动代码，不重新构建或执行Flutter全量；沿用已发布2216包身份，仅做本次配置/内容/分发检查。

准备工具最初两次失败分别为只读快照代码生成错误、Windows命令行长度超限，均未发生生产切换。后者改为私有运行目录流式传输并SHA验证，之后HOST/CDN阶段各执行一次成功；未盲目重放未知生产写入。

证据：[任务](../workflow/tasks/2026-10-18-android2221-withdraw.md)，artifacts/2026-10-18/android2221-rollback/ 下plan、hk/sg-before、host/cdn-result、host-postflight、cdn-readback、public-result-r2、backfill-result及tunnel-stop。执行前活动源码16049d4a，产品/mobile无修改。主动准备完整起点未单独计时；生产切换02:26:14、CDN提交02:26:34及各门禁时间以回执为准，不按文件mtime推算耗时。

HK私有备份：`/opt/starchat/docs/verification/artifacts/2026-10-18/android2221-withdraw-20261018`，mode0700。SG配置备份：`/home/ec2-user/starchat-android2221-withdraw-20261018`。审计trace：`android2221-withdraw-to2216-20261018`。恢复2221必须作为新的授权操作，先读取实时设置/文件/路由，不能重放旧发布或删除本次审计。

当前正式下载：[Android 0.4.47（2216）](https://www.liuhetong888.com/download?platform=android&install=1)。已安装2221/2222 Debug不自动降级；实际手机检查更新的可见结果未人工操作验证，服务端实际路由与审计已确认。
