# Android0.4.37+2206紧急回退交付

21:59:46.536530+08 PUBLISH_PASS，22:00:03+08当次四项后验通过。已撤下2205当前渠道，恢复原0.4.33聊天实现，以0.4.37+2206固定签名源码重建发布，普通更新配置已启用。[官网安装](https://www.liuhetong888.com/download?platform=android&install=1)、[CloudFront安装包](https://d12fjr06o6tga5.cloudfront.net/downloads/ChatFlow-0.4.37-build2206-arm64.apk)。已装2205可直接覆盖，不卸载或清数据。

原源2a32683a→候选fe9e07abc36cba22596e975fd833c6c61b531145，只升版本及必要一次性事务索引回退桥，保留2205新写索引、正文/密钥/token；metadata0392e41a，1876移动输入零漂移。成品82848798bytes/SHA fb7005f59c0a8e7a16a633a06f5cca10d30784c4508912cb442d95cefbd02436，包com.liuhetong.mobile/ARM64/非debug、固定75b31单签v2/v3，28构建/重建/资源/DEX/清单门禁实际全部0。官方原锁ac096保持。

Bridge RED→5真实SDK通过，analyze0issues，mobile307通过/23既有skip；全量首轮5411通过/49失败/9skip，48测试目录及Fake委托失败已复核，1原日期跳转失败在纯原2a复现，按用户先回退原行为保留，不能称全量全绿。原Android手机USB无法连接，未做全房间覆盖/弹窗真机验收。发布helper30通过，PG6本机skip且原交易体/实际隔离PG6旧证据输入相同经SPEC复用；全仓verify预检缺.env未运行。来源/成品SPEC→QUALITY接受。Node官网metadata54/51通过；修正测试CRLF转换后54/51复验并逐字验证iOS块未改，生产页面逆向字节等同。

当次postflight：CloudFront9→10精确HK路由Deployed/旧9及policy保留；服务器本地合并SHA、两地HTTPS HEAD200/正确大小/CORS；当前官网/registry/latest一致；实际Android/iOS/legacy版本路由及唯一trace3审计；两端min3、iOS2205五键/安装清单、35容器id/image/restart/start及schema均保持。无公网完整APK回拉、无main合并/push。新备份`/opt/starchat/docs/verification/artifacts/2026-10-08/android-2206-215100`，trace android2206-20261008-215100。U映射已恢复原任务，无新隧道。

[任务及计时](../workflow/tasks/2026-10-08-android2206-emergency-rollback.md)、[闭合收据](artifacts/2026-10-08/android2206-emergency-rollback/closure.json)、[四项后验](artifacts/2026-10-08/android2206-emergency-rollback/postflight/)、[独立故障调查](../workflow/tasks/2026-10-08-android2205-empty-room-investigation.md)。2205具体根因未证实；新采集同账号2206已出现入房/同步成功各一次，仅按诊断层级报告，不等于全部手机验收。
