# Android0.4.44+2213 正式渠道与更新弹窗

用户要求增加“回到最新消息”的上滑出现距离，完成后发布Android渠道及更新弹窗。已于2026-10-09T17:17:44.616655+08:00完成PUBLISH_PASS；后验归档2026-10-09T17:18:57.116956+08:00。可靠计时2026-10-09T16:51:15.3493996+08:00起，约27.7分钟，更早只读调查起点未知。仅Android正式发布。

- [官网下载](https://www.liuhetong888.com/download?platform=android&install=1)
- [CloudFront APK](https://d12fjr06o6tga5.cloudfront.net/downloads/ChatFlow-0.4.44-build2213-arm64.apk)
- [官网备用 APK](https://www.liuhetong888.com/downloads/ChatFlow-0.4.44-build2213-arm64.apk)
- [本地同一成品](artifacts/2026-10-09/android2213-release/delivery/ChatFlow-0.4.44-build2213-arm64.apk)

## 实际包含的修改

按钮从“有后续窗口/历史context立即出现”改为累计阅读距离达到max(600逻辑像素,当前消息视口高度)才出现，约一屏。小幅上滑后incoming不再误现；独立悬浮VLB始终挂载，不必等待新消息刷新，也不重建整列气泡。窗口重基不计入阅读距离；成功搜索/引用定位保留明确返回入口；返回最新后复位。

正式包首次包含debug2212验证的缓存房间列表/持久head优先、可选计数/预览/关联房间/提及恢复后台进行、可见消息ID保留和连续惯性窗口推进，以及默认静态表情和账号级最近16个两行8列。详细前置行为证据与限制见[2212报告](2026-10-09-cache-first-fast-history-emoji-recents.md)。不新增明文聊天持久化，不更改E2EE、认证、钱包或业务服务器。

## 构建与验证

0.4.44+2213，com.liuhetong.mobile，standard ARM64 release，73139489bytes，SHA256 `08a7448114ad5d768b534b81b61668e03a71a2c26f95e894297e098838f15271`。固定签名证书75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。源码冻结 `2dc702fe2b8fdf5acf0f92f368bf201dd858be38bbdbf96e0fd31e798a66f630`，1941文件，锁12ae6742… unchanged；b09bf2f2+managed既有WIP未合并，不把整个HEAD差异归本轮。

| 验收 | 证据 |
|---|---|
| R1 距离门槛 | 真实RoomPage incoming场景RED→GREEN；无incoming100隐藏→1200显示→100隐藏、incoming抑制、返回最新复位；当前专项/生命周期11PASS，当前原生缓存/历史/生命周期17PASS，含30重叠fling与<1px锚点 |
| R2 正式成品 | 最终共享5758PASS/9条件skip、analyze0、边界377PASS/23条件skip、UI34/535、policy三PASS；SPEC后QUALITY接受。正常pubget恢复后与最终共享1941源文件逐项一致；源构建→Apktool2.12.1常规重建→zipalign16→固定签名→28门禁exit0，六SQLCipher key/blob导出存在。旧emoji/加密core原生仅在精确输入不变范围复用，不复用旧RoomPage新按钮行为 |
| R3 分发/弹窗 | 五块SHA及组装完整SHA、不可变APK安装；CF14→15仅加新APK精确路由，原emoji等14项与桶策略保留、Deployed/CDN HEAD及CORS通过。alias原子切换、官网两文件、SettingService事务CAS更新Androidversion/build/notes、唯一三条审计。iOS五设置/min3保持 |
| 后验 | 工作站严格TLS官网/CDN/latest HEAD、页面/registry小元数据SHA、Android/iOS/legacy未授权401；运行版本路由实际函数投影和exact3audits、schema0095及35容器IDs/images/restart/start保持。primary54/managed51 Node通过，普通可跳过弹窗配置；真实手机弹窗未观察 |

全量verify.ps1环境缺.env，未导入生产秘密，适用拆分门禁如上。真实PG6证据仅在transact函数逐字SHA及API/worker身份一致时复用，不称新跑PG。所有stage起止/exit详见execution、构建receipt和门禁receipts。

## 返工和审查闭环

初次无incoming控制用例PASS，不当BUG RED；incoming真正触发原问题后RED。最初保留generic history context绕过门槛，诊断普通pin也设置context后改为明确locator成功标记。SPEC发现条件挂载VLB导致无incoming阈值不出现，取消当次共享exit1留档，补回归并无条件挂载，最终重新跑全量通过。

发布适配先有旧双新增路由断言失败，改为只新增APK且保留原14项。通用版本字符串替换曾误改含2211的固定AWS账号；fresh policy新用例RED捕获后恢复原账号，最终18发布契约通过，未执行带错账号的云写入。旧17测试/旧缺陷脚本审查均不当最终证据。最终SPEC→QUALITY核对固定非版本身份、22个payload文件/归档、成品及所有新门禁，两个P1关闭。

## 线上状态、回退与边界

Android2211→2213；iOS0.4.36+2205、两端minimum3、官网测试候选2209、旧APK/其他ABI、既有56个动态资源不变。没有发布差分API或发送账号聊天广播。源码主与managed各自frontend仅回填Android下载链接/registry/缓存标签及对应测试，不覆盖各自页面布局；自建SOCKS已关闭，无Git合并/push。

0700备份 `/opt/starchat/docs/verification/artifacts/2026-10-09/android2213-release-165500`；HKstage `/opt/starchat/releases/android2213-20261009-165500`，SGstage `/home/ec2-user/starchat-android2213-20261009-165500`。旧包和CF完整前态保留。回退先核对当前十设置/文件/审计无后续漂移，通过公开SettingService与备份恢复；结果不明不盲目重放。已装高build设备不能直接降级，应按另行授权提高build的回退包处理。

真机USB不可用，未验证手机保数据覆盖、实际弹窗、release/profile帧率及连续弱网组合；模拟器原生功能通过不证明所有设备零卡顿。未知百万ID首次精确定位及后台提及scanner内存边界仍见2212报告，不能承诺任何历史规模内存恒定。证据根目录 `docs/verification/artifacts/2026-10-09/android2213-release/`，构建原始记录在managed同任务android-arm64；交付摘要/签名/冻结证据复制至primary delivery。
