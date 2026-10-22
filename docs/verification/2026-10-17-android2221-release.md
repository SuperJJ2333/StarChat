# Android 0.4.52+2221 更新发布

用户明确授权发布Android新版本更新弹窗；**已于2026-10-17 20:53:44+08发布成功**。普通更新，保留iOS2215、最低支持build3及全部其他服务。

正式ARM64成品：`com.liuhetong.mobile`，0.4.52+2221，73,524,314字节，SHA256 `ab4652c05c3d1b1cef7a001ce542ba21a22103b7dd5fd6e709d3efc759b9e572`。沿用固定75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff证书，v2/v3验证成功。源码HEADf409de3c，移动端与已验收45355d5f相同。最终包包含头像缓存、错误离线提示、入房加载页及取消重入修复，也包含此前Getui同意前初始化修复；不宣称安全软件告警已消除。

构建20:38:19–20:47:24+08，共9分4.684秒：源码release→Apktool2.12.1→zipalign36P16→固定签名→清单/DEX/原生与Flutter资产复核，20门禁exit0。25415类/168869方法，清单语义一致，smali无改变；13非app原生库与2216逐字节一致，仅libapp变化且LOAD16KiB静态检查通过。

共享验证按变化范围复用：原全量6134PASS/9SKIP/2FAIL exit1如实保留，后续29夹具修正、最终15+41受影响覆盖及完整analyze0。五场景真实Android入口延迟SDK验收PASS及普通Debug冷启/暖入房验收证据复用；移动端源码diff为空。发布保护35专项PASS，历史PG6例通过精确事务/四依赖/schema闭包复用，未新跑PG。完整verify.ps1缺.env未执行，不导入生产秘密。

独立SPEC→QUALITY审查通过，冻结包SHA `f08eeb715dce7e2047de013f996bc0bc1b9c3878ae263e282da2998592a30e8a`；runtimeSHA `7b2e5d4ae3e64baeb51a3e59b90746557ce348d848f0e70fcc488d91402ad282`。审查与真实构建/门禁/执行回执见[证据目录](artifacts/2026-10-17/android2221-release/)，[任务记录](../workflow/tasks/2026-10-17-android2221-release.md)。

执行标识 `startup-20261017-2221`；服务器私有备份 `/opt/starchat/docs/verification/artifacts/2026-10-17/android2221-startup-20261017-2221`。原2216APK保留；任何未知结果停止写入，先读回现值和本次trace，不盲目重放。生产新鲜基线Android2216/iOS2215/min3、35容器/schema0095、CDN19规则；只新增2221不可变路由、两静态文件和三Android设置审计。

局限：真实ARM64设备安装和旧客户端可见弹窗尚待用户观察；API28同源Debug不能替代真机。既有libcrypto16KiB/RELRO与K80安全软件告警未确认解决。HEAD验证仅证明访问/大小，不是公网重新下载验签；内容身份来自本地构建和上传完整性。当前已装2221Debug不会收到同build重复更新提示。

## 发布后验

20:52:06上传5块/73,524,314B通过，20:52:08服务器合并完整SHA匹配；20:52:11不可变APK落盘，20:52:30 CDN变更提交。20:53:13 CDN Deployed、HEAD200、CORS通过；保留原19路由和bucketpolicy。20:53:30 alias切换2221，20:53:44 PUBLISH_PASS，20:53:47真实路由函数/三条审计读回PASS，Android2221/iOS2215/min3与两URL精确匹配。

20:54:21新鲜保留检查PASS：35容器ID/image/start/restarts、schema、guard/probe、四设置依赖、旧2216APK不变，七静态/aliases/十设置精确，备份0700。工作站TLS验证、双APK HEAD/长度/CORS、registry版本/SHA/MIME/no-store、下载页、iOS清单逐字节及Android/iOS/legacy未授权401全部PASS；没有公网下载完整安装包。

发布后两工作区仅回填download.html与android-release.json，CAS及目标hash通过；primary旧2213registry按独立审查的精确旧hash备份纠正。其他源文件未覆盖。自建SOCKS已关闭，W映射已移除。

正式入口：[Android下载](https://www.liuhetong888.com/download?platform=android&install=1)；[不可变APK](https://www.liuhetong888.com/downloads/ChatFlow-0.4.52-build2221-arm64.apk)。后续人工验收使用低于2221的正式客户端；服务端发布成功不等于已观察每台手机弹窗。
