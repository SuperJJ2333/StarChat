# 旧日期定位与上下文：2201技术验收及模拟器交付通过

模拟器已于2026-10-05 01:02:24–01:02:39 +08保留数据安装 **0.4.32+2201**。实际base.apk SHA256与独立接受成品完全一致，UID10090、firstInstallTime=2026-09-26 04:06:20保持。真实账号十天前日期/关键词上下文反馈仍待用户，不能把合成页面、安装或启动观察当真实账号验收。

沿[批准计划](../superpowers/plans/2026-10-04-search-date-context-followup.md)与[独立任务](../workflow/tasks/2026-10-04-search-date-context-followup.md)，修复搜索退出清理取消新日期定位、持久旧命中在线始终单条无token、旧live历史耗尽状态阻止前向分页，以及实际拖动清除同向待显示窗口。保持完整本地日期索引权威，在线有界SDK上下文与真实前后token，合法本地anchor仅在网络类失败时回退；权限/来源/隐藏/撤回/账号/取消不借回退绕过。采纳前重读持久anchor以拒绝迟到撤回，实际SDK future保持资源所有权直至完成。无密钥加载、vendored SDK、依赖锁、原生存储/恢复契约变化。

实现72c1188e、版本/workflow76df11ea、测试夹具收尾e6659cf6670d6fe1158d6fd0e5e0f275f247a061。最终1871输入manifest **d2206802c3cca303ac3026d8f8406c0f4e2e9383c1f70aa21422d5fcfd99f8b8**；旧candidate-a/e7b保留历史，不用于最终包。原锁文件ac0966cb75f61763073bfc48ef5e8b93b85cf6cf46ebaa921d8b3739c62694ac。正常官方pub.dev enforced-lock解析保持版本；初次镜像环境改写在任何测试/构建前恢复，诊断日志保留。

实际RoomPage先获得有效日期/关键词RED，又获得分页状态、真实手势窗口和迟到持久撤回RED。最终页面日期通过受控持久读取定位，关键词实际拖动在两个方向请求真实SDK token并显示可命中的新增气泡，最新live窗口仍保留。最终53覆盖PASS/analyze0；原15suite172PASS/5FAIL逐项修复，未改断言。早期夹具/test-zone/无效等待失败仅为诊断，详见handoff及任务历史。

最终全量命令 `flutter test --no-pub --concurrency 2 --reporter expanded`，e665源码，00:39:38.589–00:48:09.802 +08，**5437PASS/9skip/0FAIL/exit0**。首次5436PASS/1FAIL为旧媒体临时目录删除OS32，保留关闭资源及全部断言后显式留下ignored合成夹具；具体被占用子文件/持有方未知。第二次默认并发5434PASS/3FAIL为缓存/预取/图片重试，三整文件同源38PASS后低并发全量通过，所有原deadline/断言保持；不声称并发是唯一原因、不改写历史失败。

有序原规格/domain接受（4d6933…）、夹具补充规格接受（800c1447…）、整批质量/security接受（a719d00e…），无新增P0–P2。Android独立成品审查接受（43c0b917…）；最终平台/安装有序规格→质量审查接受（954faaf398953c2d1ede39b705d42ebe49a9eec88d8e993c37c29d7ba0242942）。证据见[本轮目录](artifacts/2026-10-04/search-date-context-followup/)，核心handoff原025bb84…与inputs4b955…精确保留，夹具补充独立存放。

Android源码构建、Apktool2.12.1常规DEX/资源/manifest重建、zipalign36-P16、稳定75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff签名及独立语义/338原生资产校验通过。成品135721187bytes，SHA256 **0c74d6320c89005b08945b2951e30231fff193723a7d2a3ffacfe4051a3dceb1**；source/final kernel3570ec93…相同、与2200 f302ae73…不同，新localContextOnly/closeSearch标记存在。 [最终标准x86_64 debug APK](artifacts/2026-10-04/search-date-context-followup/android-debug/run-20261005-005006/final.apk)。01:23:42观察同PID1669持续1263.7秒，匹配Java crash记录0，仅为启动进程观察。

同源[iOS run37217656064](https://github.com/SuperJJ2333/StarChat/actions/runs/37217656064)绑定e665，全部三job **SUCCESS**：完整生产原生编译，iOS18/26 host媒体/日期/context/反向拖动门禁及native seed、新app进程保留Keychain/SQLCipher/原指纹/旧加密历史验证。不能据此承诺所有设备永不L04/L07；没有IPA/正式移动发布、iPhone实际覆盖升级或物理视频播放验收。原模拟器scanner排除限制不变，完整生产编译保留正常依赖。

整库verify预检缺.env/local.env，未执行；未引入秘密。生产版本最后00:49只读观察仍Android2196/iOS2194，本轮未变更生产。前序2200媒体缩略图/点击用户已确认；新D1/C1真实反馈待确认。临时合成夹具/旧受拒清理目录保留ignored，不复制数据库/密钥/中间包。主分支集成及WIP保全读回另记任务；已安装2201不依赖后续文档提交重新构建。