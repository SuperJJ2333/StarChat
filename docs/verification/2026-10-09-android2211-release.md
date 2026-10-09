# Android0.4.42+2211正式分发与更新弹窗

用户本轮明确授权Android新版本更新分发与更新弹窗；正式发布于2026-10-09T10:19:43+08，最终检查归档2026-10-09T10:23:02.724266+08:00。首次明确调查时刻10:01:29+08；更早准确开始未知。只发布Android，保留iOS、minimum3和普通可跳过更新策略。

## 交付

- [官网下载](https://www.liuhetong888.com/download?platform=android&install=1)
- [CloudFront APK](https://d12fjr06o6tga5.cloudfront.net/downloads/ChatFlow-0.4.42-build2211-arm64.apk)
- [官网备用 APK](https://www.liuhetong888.com/downloads/ChatFlow-0.4.42-build2211-arm64.apk)
- [本地同一成品](artifacts/2026-10-09/android2211-release/delivery/ChatFlow-0.4.42-build2211-arm64.apk)

0.4.42+2211、com.liuhetong.mobile、ARM64 release；73139489bytes（69.75MiB），SHA256 `4eb0f8bb7fc3dd9f1f3f85cb4a73489b3cc8ae5841f0114a6d9cb7766d80751e`，固定签名75b31c66…ba61fff。更新说明：优化动态表情播放与内存缓存；动态表情点击单独发送，改善表情面板和会话切换体验，修复朋友圈相册大图误显示闪照选项。

| 验收 | 结果与证据 |
|---|---|
| R1 正式构建 | 同源1935移动输入与debug2211共享门禁文件列表完全一致；5730PASS/9skip、analyze0、native5、边界377/23复用。正式独立源码编译、Apktool2.12.1常规DEX/资源/清单重建、16KiB对齐、75b31v2/v3、完整语义/资产/ARM64AOT与冻结前后校验28步骤exit0；六个SQLCipherkey/blob导出存在。锁12ae保持，无新增混淆或打包填充 |
| R2 分发 | 5块各SHA→组装完整SHA→不可变下载路径；old2206保留。CloudFront12→14只增新APK精确路径与资源revision路径、原12与桶策略保持；Deployed、APK HEAD/CORS200，latest-arm64原子切换 |
| R3 弹窗 | SettingService既有事务CAS，version/build/notes唯一3条审计；Android2206→2211；iOS五键和两端min3保持。traceandroid2211-20261009-100300，PUBLISH_PASS |
| R4 动态资源 | revision de380a20b3183d0a3e5f6e6c，56WebP/7643074bytes逐项源站与CDN真实下载SHA/大小/MIME验证，单条最多207310bytes，不超过小文件门禁；已嵌入清单digest01004804…8a2cfa匹配。按现有Wi-Fi空闲预取策略，本地验证缓存；未塞回APK。个人使用授权沿用用户原答复，资源上游许可与来源保留既有provenance |
| R5 后验 | 实际运行Android/iOS/旧默认route函数投影、exact3audits，工作站strictTLS官网/CDN/latest HEAD及page/registry SHA、三种未授权版本HTTP401；schema0095与35容器IDs/images/restarts/start及其他ABI/iOS清单不变。primary54/managed51 Node、18发布专用测试、三policyPASS |

源仍在managed W树b09bf2f2+WIP，本轮没有源码Git提交/合并。新优化相较debug未变；发布metadata同步主与managed各自frontend布局，仅Android链接/registry/缓存标签与对应版本契约测试改变，iOS内容保持。官网测试候选入口2209继续单独存在，不误称其自动升级到正式2211。

## 实际发布过程与返工

所有精确start/end/exit均见本任务execution与managed build receipt；构建标签100400不是准确开始时刻，不用标签推算工时。构建准备→官方pubget/锁→同源freeze→ARM64构建28gate；private上传5块/资源与runtime；10:16:45资源安装，10:16:49APK不可变安装；10:17:09CloudFrontInProgress→10:19:14Deployed；10:19:33CDN56资源验证→10:19:36alias→10:19:43官网/设置→10:19:45审计→10:20:26四项后验全部通过。

发布脚本初次版本适配遗漏quoted iOS字段：3FAIL/14PASS，修复后17PASS；新联合资源路由真实RED1→18GREEN。独立resource-only CloudFront中间态会令最终计划CAS拒绝，SPEC指出后改为单次联合12→14，旧cloud入口被阻止且未执行。源码同步primary54PASS，managed旧2204期待/网页导致两次失败，按该树自己旧基线仅替换Android内容后51PASS；失败日志保留，无产品或鉴权放宽。

Settings transact与既有真实PG6PASS实现逐字相同，SHA2a58136b…400742，当前API/workerIDs/images与当次基线相同；证据指针及比较见postgres-evidence-reuse.json，不称本轮新跑PG。共享verify.ps1所需.env缺失，不导入生产secret；适用门禁拆分执行/复用。SPEC→QUALITY分别完成，发布后实际回执已重读归档。

## 回退与限制

0700备份 `/opt/starchat/docs/verification/artifacts/2026-10-09/android2211-release-100300`，HKstage `/opt/starchat/releases/android2211-20261009-100300`，SGstage `/home/ec2-user/starchat-android2211-20261009-100300`；保留旧APK/原CF完整配置和设置。回退先核对当前文件/十设置/审计，无漂移时用既有备份和SettingService恢复；未知结果不盲目重放或覆盖后续版本。动态revision只增不可变文件，不删除旧聊天或媒体。

仅自建loopback SOCKS用于工作站TLS验收，已关闭，仅停止自己进程，无全局代理改动。没有公网完整回拉APK，资源小文件逐项验证不等同下载APK验签。服务器分发/弹窗配置完成，不等于手机已出现弹窗、完成保留数据覆盖或真机性能达标；authenticated-user HTTP未执行，实际route函数只读投影与401证据分开记录。原百万历史陌生ID首次查约5秒和手机profile缺口保留。

下一步：用户不卸载覆盖升级2211，反馈实际更新弹窗、表情直发/复开、房间/键盘切换体验。服务器API/差分patch接口未部署，新正式包差分通道仍按现有fail-closed完整APK回退；本轮不宣称差分公网发布。
