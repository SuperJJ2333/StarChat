# Android2222冷启动发送耗时及群资料诊断

用户要求实测0.4.53+2222 Debug冷启动→入房→发送耗时，定位关键延迟，并报告非好友头像不加载、群人数持续0。用户另明确授权在模拟器“测试群”发送可被成员看到的测试消息。

工作树`C:/Users/Administrator/.codex/worktrees/interactive-cache-startup/StarChat`，分支codex/interactive-cache-startup-20261016，起始6d6b5302；测试起点emulator-5556已装0.4.53+2222，UID10090/firstInstall2026-09-26保持。root独占采集脚本/文档和matrix_e2ee_client.dart、room_page.dart、新startup_room_member_handoff_test.dart及既有startup_local_projection_entry_test.dart。2026-10-18T04:15+08已完成计时、修正、验证及2223普通Debug保数据交付；正式分发保持已回退2216。

| ID | 验收 | 状态 |
| --- | --- | --- |
| CP-01 | 真实冷启动及操作时间、持久化/SDK发送/服务器确认分开 | r5/r6可靠，发送1597/1495ms，持久排队56/136ms |
| CP-02 | 用同一时钟和原生阶段找关键延迟，标明自动化开销 | 房间241/236ms；Matrix发送1516/1236ms是最大跨度；r6实际事件HTTP245.603ms，余下约990ms未细分 |
| CP-03 | 复现非好友头像并追溯Matrix成员/业务好友解析来源 | 根因是持续有效的timeline缓存头遮住SDK成员；缓存member未映射；好友业务头像回退掩盖此错。已修，真实非好友头像初次观察与恢复后均可见，资料页同图并提供添加到通讯录 |
| CP-04 | 复现群人数0并核对权威成员状态 | 旧版真实0→发送后7；已修，2223冷启动先省略未知人数，后台自动变7，无需发送消息 |

证据docs/verification/artifacts/2026-10-18/android2222-cold-send-profile/。内置ext.chatflow.performance仅保留闭合枚举计时，不保存正文/账号标识/VM凭据；原生日志只内存提取startup phase。原账号截图仅本地证据。

采集第一轮r1因UI转场空XML解析失败，没有输入或发送。r2/r3各实际发送1条测试消息，但VM通道未接入；55秒观察超时不是消息耗时。r4扩展尚未注册，未发送。r5/r6各发送1条并可靠确认，总共4条，均为用户授权“测试群”。r6只持久化HTTP类别/固定方法/状态/时长，未持久化URL/headers/正文/标识；恢复原profile开关并关闭自建forward。

可靠两轮数据：main_entry缓存命中1319/1235ms，首缓存内容1754/1687ms，SDKready5489/5140ms，内容→SDKready仍3735/3453ms。它们不含原生/引擎启动。自动化launch→确认14812/13234ms含UI XML查询、定位、输入与探针开销，不能称纯APP加载耗时；各内部trace不能和不同起点的host时钟直接相加。r6 Matrix /sync longpoll等待2962ms也不能直接视作发送阻塞。发送跨度内客户端生命周期、假sync/数据库、加密等待的精确贡献尚未逐段插桩；不能把1.5秒全归网络。仅两个同设备/房间/网络样本。

2222安装包SHA0ca7e72dd909e9c4cbb1a8f5ce1022d282ab156a3c29a454e2ea1bfb71382298，来源b53e7387，固定证书75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。修正沿用已批准2026-10-17-startup-local-projection计划的同页metadata交接；无schema/权限扩展。pending缓存member isJoined=false/power0/canMentionAll=false，群不走好友数量猜测；canonical移除/空头像优先，timeline缓存保留。

RED：member-red-valid.log共5失败/5通过，含SDKready空成员、pending空成员、refresh旧投影、异步换Room晚结果、actual main首帧（0）；取消lease用例原已通过。member-red.log为未映射V盘环境失败，member-red-mapped.log含fixture配置错误，不作为行为RED。GREEN-r1进行中，最终须SPEC→QUALITY及冻结共享门禁。SDK Room.setState本身会发onRoomState，refresh显式淘汰是边界一致性，不能声称生产SDK缺事件。

环境Flutter3.44.9/Dart3.12.2、Win11、JDK17、API28 x86_64；host native Olm3.2.15 / SQLCipher4.10.0 / SQLite3.50.4，DLL hashes复用run-full.ps1预检。pubspec.lock SHA a43833c8e7c3d6faa93d21babdc61dfe4b3563c7ac00912006f26daa8e0ecc5d；.env不存在，不导入生产密钥运行聚合verify。阶段时间按r5/r6 receipt及后续门禁receipt；其余未精确计时，不估算。

03:05+08：GREEN-r2共40 PASS/0FAIL，含完整actual-main五场景/生命周期/页面回归；退出0收据已写。GREEN-r1失败在第五场景首次手动audit（SDK解除前），不是产品交接回归；隔离同输入通过，修正前提为全部两图已绘制，再开始逐帧严格审计。独立entry_safety_review顺序SPEC→QUALITY初审无阻断，待冻结确认。

版本占用预检：两工作区任务/计划未发现2223或0.4.54占用；current-state刚完成正式2216回退，当前模拟器2222。按既有Debug交付范围预留0.4.54+2223；pubspec只递增候选。旧正式2216及iOS2215不变。

冻结df395145bf0bcde71ce262decda2a0cf25d1a795；独立entry_safety_review最终SPEC→QUALITY均PASS，绑定GREEN日志SHA c059fda675fc1dc694f3273b8c56048770e34109f58ff0bd56ce0da7300c5726。frozen-full-r1：6160 PASS/0FAIL/9SKIP，analyze0 issues，exit0/source_stable=true；03:06:07.466+08→03:51:28.730+08（45m21s），含完整测试与analyze41.6s。9SKIP均为默认关闭ANNOUNCEMENT_DIAGNOSTICS的旧用例，与上一版精确同名，无新增跳过；不算通过。未重复未变输入的旧门禁。

native-build-2223-r1已PASS：03:51:43+08→04:01:50+08；APK SHA ab3a7c3e76c0995fdcaf8dd47a7192ee3381c74eabe19a498c7096ebfc399fce，固定签名/重建语义均通过。84535是已结束exec会话号而非OS PID；自建W映射已清理。

04:02+08起并行组N1：native-device-2223-r1（exec14763，现已结束）install-r后隔离合成五场景，不打开真实账号；04:07:18+08最终PASS/driver_exit0、269.61s，五场景齐全、first-frame/feedback/post-SDK cached entry/avatar handoff全部true。UID10090/firstInstall2026-09-26保持。截图progress.png为合成验收过程，不是实际账号冷启动失败；日志白名单提取无TestFailure/框架异常/Timeout，未保存raw日志/VM凭据。只做Wakeup/dismiss-keyguard检查，读回原screen timeout60000/stay_on0，没有改变系统设置。

main-build-2223-r1（exec13658，已结束）普通main同冻结输入、独立输出，全部PASS：04:02:20+08→04:12:03+08；APK SHA d91510a4915787081a9dfce4409d08b95c27975bce6dd02f2abbee73f0fed716，126081370B，x86_64、com.liuhetong.mobile.debug、0.4.54+2223、固定证书75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。Kotlin KGP迁移提示与上一版debug-main-2222同插件清单，依赖锁未变；未升级插件或弱化门禁。

main-install-2223-r1 PASS，install-r及设备实际base.apk SHA匹配普通main，UID10090/firstInstall2026-09-26 04:06:20保持。main-members-cold-2223普通真实账号冷启动→测试群，无输入/发送：首次房间观察有可操作composer、未知人数未显示0，约8秒idle后7人；采样未见loader但不是每帧审计，不冒称所有真实帧无加载。root逐图检查room-first-observed/room-after-idle自定义horse头像连续可见，点击该头像的member-profile同图并提供“添加到通讯录”；member-nonfriend-receipt确认true/好友写入0/发送0，已返回测试群。原member-profile-receipt的false仅因只匹配“添加好友/加为好友”，保留并解释实际文案。普通main总采样04:13:19+08→04:13:41+08；非好友资料补证04:14+08。

最终独立交付SPEC→QUALITY通过，复算普通APK hash/大小、固定v2/v3签名、full/原生/安装绑定一致，未将2222发送计时混称2223速度改善。所有自建ADB forward及V/W映射均已清理，无运行构建/隧道；没有改变设备stay_on/timeout设置。模拟器留在2223普通main“测试群”。计时关键仍是完整检查及SDK sendEvent，HTTP之外约990ms尚未逐子阶段计时；本轮没有声称优化该发送跨度。

下一步：用户可直接在模拟器自行测试；如有新反馈按本记录与冻结输入继续。聚合verify因缺.env未完整运行，iOS真机未验，不阻断本次Android Debug交付。正式渠道仍2216，本任务未发布正式版或更改弹窗/下载入口。
