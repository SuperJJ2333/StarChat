# Android 0.4.47（2216）发布记录

当前状态：2026-10-16 11:04:15+08正式发布成功，普通更新配置已启用；11:04:30路由/审计及公网轻量后验通过，11:06:29服务保持检查通过。

用户明确授权新Android版本与普通更新弹窗。候选包含五项体验优化与超级表情可见自动播放修复；源码544b61b6，构建HEAD35f59abbb6bdaa0fe6c826aaff904130bb6dea76，移动目录相同。iOS下载与设置、两端min3、后台业务服务保持。

## 正式包

- com.liuhetong.mobile，standard/ARM64/nondebug，0.4.47+2216。
- 最终SHA256：`db914f66229cffa79825954200845ac841fd10486c77fb8ecce94dbef7b41039`；73,262,170字节。
- 固定证书SHA256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，v2/v3通过。
- 2026-10-16 10:34:49–10:44:06+08：源码Release构建→Apktool2.12.1→zipalign36 P16→固定签名→重解包语义/资源校验20步骤全部退出0。25,414类、168,863方法重建语义一致。
- 新旧正式包13个非应用原生库字节相同，仅libapp.so改变；源包与最终包全部原生库一致，Matrix导出符号契约保持。

## 验证口径

同移动源码的共享全量6038PASS/9SKIP/0FAIL与analyze结果复用；同源实际main Debug在API28/x86_64模拟器保数据安装、自动播放及后台/离屏恢复通过。此前原生集成driver exit0与All tests passed按输入闭包复用；reportData为null，不能据此声称有逐项设备时延。实包SPEC→QUALITY通过。发布工具35专项通过，保留RED→GREEN；事务源码与选择依赖严格闭包复用历史6PG通过，不声称本轮新跑生产PG测试。

既有libcrypto ELF16KiB/RELRO风险未修复：native inspector真实exit1保留；ZIP P16不代表16KiB设备运行通过。没有ARM64真机/所有ROM/弱网矩阵验收。全仓verify.ps1缺本地.env；插件Kotlin/deprecation编译诊断保留，不称全部仓库无警告通过。

## 发布和回退

发布包freeze `5df015a69df956450a6e1d8ec9c728324fce9c3bfa1be2863f18385aa3d551a6`，runtime `7d7812617eb31db6b949a7f7ab3fb1e16f72508ef8896d72b9a503f8da055479`。新不可变APK经5块上传及服务器完整SHA确认；CloudFront精确路由17→18、11:03:24 Deployed及HEAD/CORS通过后切换arm64别名，随后仅改下载页/Androidregistry和Android版本/build/说明三键。11:04:30真实路由读取Android0.4.47+2216/min3、iOS0.4.46+2215/min3，恰好三条审计。普通更新配置已验，未声称真机上实际看到弹窗。

- [官网Android下载](https://www.liuhetong888.com/download?platform=android&install=1)；[不可变APK](https://www.liuhetong888.com/downloads/ChatFlow-0.4.47-build2216-arm64.apk)。
- 工作站8个HTTPS请求/11断言通过，保留证书校验，无完整APK重复回拉；两端HEAD200/73,262,170B，JSON版本/SHA、下载页及iOS清单原始字节保持，三个无鉴权版本路由401。HEAD不等于设备安装或重复验签。
- 11:06:29 postflight确认35容器身份、schema0095、永久guard/设置依赖、旧2215不可变APK保持，十键完整后态正确。首次postflight错误地把随registry切换的字段old_artifact当成旧包，客户端断言exit1；改为固定旧文件路径后真实exit0，没有生产修复写或隐藏失败。
- 备份：`/opt/starchat/docs/verification/artifacts/2026-10-16/android2216-experience-20261016-2216`，已实测0700；trace `android2216-experience-20261016-2216`。CloudFront前态备份在SG私有stage的cloud-2216-before.json。
- 回退需先核对十键、三条trace、静态after哈希和alias仍属本次；通过SettingService事务和新的审计恢复原Android三键，再按需恢复本次两静态与旧alias。不要覆盖后续发布、删旧APK或盲重放。CloudFront仅在配置仍精确匹配本次目标时以当前ETag恢复前态，桶策略保持。
- 自建SOCKS于11:04:40关闭，仅PID337672；构建W映射已清理，无运行中本任务构建/CI/发布命令。

源码回填已按七份before/四份staged精确SHA执行：本地旧iOS2213文案同步为已经发布的2215，只是本地源文件一致性，不重新发布iOS。admin-home仅替换两处版本/build文案，额外钱包会话校验字节保留；两份network脚本只换行差异，未修改。最后交付证据独审PASS。

[任务](../workflow/tasks/2026-10-16-android2216-release.md)，[构建](artifacts/2026-10-16/android2216-release/arm64-final/receipt.json)，[门禁绑定](artifacts/2026-10-16/android2216-release/gates/gates.json)，[构建SPEC](artifacts/2026-10-16/android2216-release/reviews/spec-build.md)，[构建QUALITY](artifacts/2026-10-16/android2216-release/reviews/quality-build.md)。
