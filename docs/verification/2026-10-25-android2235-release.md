# Android 0.4.66（2235）交付验收

用户授权：交付新版APK并更新官网下载入口，暂不推送更新提醒。APK构建与官网方案分别完成独立规格→质量/安全审查，均PASS。官网已切换，发布后检查PASS。

## 工件身份

- 源码：`52bbd8c5751d250d49c643c309e270ae496feb59`，继承消息时间顺序、群聊分页/引用缓存及统计助手HTML注入修复。
- 后续版本契约/任务记录提交：`5d7d4010`；只同步未来iOS流水线版本，不改变此APK来源，不构建/发布iOS。
- 版本：0.4.66 / 2235；包名 `com.liuhetong.mobile`；standard release、ARM64、`lib/main.dart`、非debug。
- 最终APK：`D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-25/android2235-release/arm64-final/final.apk`。
- 大小：73,655,386字节；SHA256 `0e438befc0d27773333002720adf47315f54cb5b12113b622f9c9bebe570a434`。
- 固定证书SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，RSA3072、v2/v3有效。
- 构建UTC 2026-10-25 07:13:54—07:20:43；源码冻结2158输入前后一致，清单SHA256 `81383b5d5f29c7846855c5995ecef8684681caa66c52eb3c9e818aae511dcaef`。

## 构建与验证

完整源码构建→Apktool2.12.1常规DEX/资源/manifest重建→build-tools36对齐→固定签名，20步退出0。25,415类、168,869方法的smali语义保持，manifest语义一致，274原生/资产条目字节保持，6DEX经常规重建。未加混淆或第三方壳。

与旧2233总大小恰好相同，但新libapp SHA `28c74d0155a80e4cdf70f059f87154415fa1bb342e41dc00aca388c1622f0f79`，旧为 `b4bb7af4ca6fafb7e32b9f208770f1fc8711f7c330ea3dce1641a8420e7d85be`。统计HTML也已变化，并与冻结源码一致，已排除误交旧包。

| 检查 | 结果 |
| --- | --- |
| Python版本契约 / Android边界 | 3 / 37通过 |
| Flutter版本运行测试 / analyze | 16通过 / exit0 |
| mobile聚合 | 首次403通过/1 Ruby跳过/1 workflow版本失败；修正六处未来构建版本后404通过/1跳过 |
| 共享Flutter回归 | 复用6410通过/9诊断跳过，诊断开启变体9通过；1721输入逐项比对仅版本对改变 |
| 源码/工件规格及质量安全 | 两次独立审查PASS |
| 官网发布器离线保护 | 10通过：设置/源码漂移、工件不符、回退、保留并发变更及精确CDN路由 |

首次版本契约失败发现时本地APK已完成，但官网尚未切换；修正后完整补跑通过，保留原失败记录，不称首次全绿。构建有既有Kotlin/API/unchecked提示。

## 发布范围与恢复

只新增2235不可变APK、CloudFront精确HK源路由、更新latest-arm64及download.html/android-release.json。新鲜快照冻结35容器与配置；十项Android/iOS设置、最低版本、iOS2215安装清单、首页/网络脚本、其他ABI别名、S3策略保持。数据库检查使用只读事务，没有设置写入或提醒发布。

切换前后精确哈希检查，共享发布锁，私有备份0700，失败仅回退仍等于本次写入的文件，遇并发变化停止覆盖。历史2233APK保留。

2026-10-25T07:56:46.609674Z切换回执 `PUBLISHED_DOWNLOAD_ONLY`，08:03:37.206138Z新鲜后验 `POSTCHECK_PASS`。服务器重组APK SHA/大小与本地一致；CDN Deployed，直连/CDN HEAD 200及CORS通过；公开页面/JSON/网络JS哈希、MIME与JSON no-store通过。十项设置完全不变（Android提醒2233/iOS2215/最低3），零数据库写入；35容器ID/镜像/重启次数/启动时间不变，其他别名及S3策略不变。

官网：[安装页](https://www.liuhetong888.com/download?platform=android&install=1)；[2235不可变APK](https://www.liuhetong888.com/downloads/ChatFlow-0.4.66-build2235-arm64.apk)。HK备份 `/opt/starchat/docs/verification/artifacts/2026-10-25/android2235-download-only/website-backup`；SG配置备份 `/home/ec2-user/android2235-download-only-20261025/cloud-2235-before.json`。失败或主动回退须先核对当前状态与本次目标一致，不能覆盖并发变化。新增不可变文件/路由不会因静态回退自动删除。

官网源文件两份按冻结前态核验后回填候选工作树；未覆盖主树既有改动。详细回执在证据根distribution的install、cdn-check、switch、postcheck及hk/sg-final-snapshot JSON。

## 限制与下一步

真实ARM64设备覆盖升级、冷启动消息顺序、连续历史分页、多人群聊和后台恢复仍需实机反馈。Ruby/CocoaPods hook未执行；既有原生ELF16K页兼容/RELRO问题不由ZIP对齐解决。本轮不构建iOS，不把历史CI失败改为通过。打包卫生筛查未见敏感文件或PEM私钥，不等同全量第三方逆向安全审计。

候选分支 `codex/android2235-release-20261025`；不合并/推送。主工作区既有516项状态（含509删除）保持。

证据根：`D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-25/android2235-release/`，包含build receipt、版本与mobile原始日志、两份构建审查、distribution单一发布记录/快照/测试/审查及分步回执。任务见[任务记录](../workflow/tasks/2026-10-25-android2235-release.md)。
