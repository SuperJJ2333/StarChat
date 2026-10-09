# Android 0.4.36+2205 正式发布

2026-10-08T20:30:02+08 PUBLISH_PASS；20:30:17–22后验全部exit0。用户已授权发布Android新版本及普通更新弹窗。

- [官网安装入口](https://www.liuhetong888.com/download?platform=android&install=1)，官网双路线选择已更新。
- [CloudFront正式包](https://d12fjr06o6tga5.cloudfront.net/downloads/ChatFlow-0.4.36-build2205-arm64.apk)，[直连备用](https://www.liuhetong888.com/downloads/ChatFlow-0.4.36-build2205-arm64.apk)。83110942bytes，SHA256 `b71e83940b7918232baa196501b324737f46d96cd6dab33b1b8ba55a490eecf9`。
- 源码c628fe2e6706000cd721d6118c3e8ef8d372d7e2，含3c37b529共享历史/弱网/语音修复；仅Android静态元数据后续提交a0e3a892fffc1cab122c0a054e1af5afb6e0e20f。未合main或push。

源码正式ARM64→Apktool2.12.1→16KiB对齐→固定75b31证书v2/v3单签，28步骤全exit0。25382类smali语义、清单及338原生资产保持；56emoji WebP/225SVG/两字体及SQLCipher六个key/blob定义导出通过。官方锁SHA79437b4f…e885，1902冻结输入前后相同。首轮镜像依赖解析漂移包作废，完整返工证据保留，未分发。

共享5632PASS/9既有skip等测试复用经独立1424输入审计：c628仅两版本字段及iOS测试入口改变。发布helper30PASS，独立QUALITY再核对30PASS；本机Docker离线导致PG6skip，旧实际隔离PG6PASS的事务/相关输入不变并经SPEC核对复用。Node primary54/managed51、managed企业下载3PASS；primary两个旧iOS2194测试期望已对齐既有2205源码，iOS产品字节未改。全仓verify缺.env未执行，不借用生产秘密。

SPEC20:22:18接受后QUALITY接受；private上传及合并SHA同最终包。CloudFront精确新增第9条香港源站路径，原8条、origin/policy均保全，Deployed及HEAD/CORS通过。官网页/registry与当次冻结SHA一致，latest-arm64原子切换2205。

仅SettingService事务更新Androidversion/build/notes三键；实际运行路由Android/旧无platform均2205，iOS2205，恰好三条审计读回。两端最低build3及URL、iOS五项设置和清单/首页字节保持；35容器ID/image/restart/start、schema0095保持。工作站及服务器严格HTTPS direct/CDN/latest HEAD200，83110942bytes/MIME与小元数据一致，公开版本接口未授权401；未公网回拉完整包。

用户暂时无法USB，真机安装/保留数据升级、物理设备弹窗和帧耗时未验证。Redmi K80后台重入闪退根因仍待ApplicationExitInfo/logcat，本包不宣称修复该未定位崩溃；iOS登录调查独立。

记录：[任务](../workflow/tasks/2026-10-08-android2205-release.md)、[发布JSON](artifacts/2026-10-08/android2205-release/publish-prep/prepared-2205/release.json)、[成品](artifacts/2026-10-08/android2205-release/delivery/ChatFlow-0.4.36-build2205-arm64.apk)、[生产结果](artifacts/2026-10-08/android2205-release/execution/21-publish.json)、[后验](artifacts/2026-10-08/android2205-release/postflight/route-result.json)。私有备份`/opt/starchat/docs/verification/artifacts/2026-10-08/android-2205-201900`，旧2204包及路由保留；未知漂移不盲目重放或回滚。
