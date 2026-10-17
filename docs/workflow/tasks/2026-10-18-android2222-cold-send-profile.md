# Android2222冷启动发送耗时及群资料诊断

用户要求实测0.4.53+2222 Debug冷启动→入房→发送耗时，定位关键延迟，并报告非好友头像不加载、群人数持续0。用户另明确授权在模拟器“测试群”发送可被成员看到的测试消息。

工作树interactive-cache-startup，起始6d6b5302；emulator-5556已装0.4.53+2222，UID10090/firstInstall2026-09-26保持。root独占采集脚本/文档和matrix_e2ee_client.dart、room_page.dart、新startup_room_member_handoff_test.dart及既有startup_local_projection_entry_test.dart。2026-10-18T03:00+08已完成根因采集及最小修正，专项验证中；正式分发保持已回退2216。

| ID | 验收 | 状态 |
| --- | --- | --- |
| CP-01 | 真实冷启动及操作时间、持久化/SDK发送/服务器确认分开 | r5/r6可靠，发送1597/1495ms，持久排队56/136ms |
| CP-02 | 用同一时钟和原生阶段找关键延迟，标明自动化开销 | 房间241/236ms；Matrix发送1516/1236ms是最大跨度；r6实际事件HTTP245.603ms，余下约990ms未细分 |
| CP-03 | 复现非好友头像并追溯Matrix成员/业务好友解析来源 | 根因是持续有效的timeline缓存头遮住SDK成员；缓存member未映射；好友业务头像回退掩盖此错 |
| CP-04 | 复现群人数0并核对权威成员状态 | 真实0→发送后7；roomInfo空members导致0，非服务器人数真的0；修正与回归中 |

证据docs/verification/artifacts/2026-10-18/android2222-cold-send-profile/。内置ext.chatflow.performance仅保留闭合枚举计时，不保存正文/账号标识/VM凭据；原生日志只内存提取startup phase。原账号截图仅本地证据。

采集第一轮r1因UI转场空XML解析失败，没有输入或发送。r2/r3各实际发送1条测试消息，但VM通道未接入；55秒观察超时不是消息耗时。r4扩展尚未注册，未发送。r5/r6各发送1条并可靠确认，总共4条，均为用户授权“测试群”。r6只持久化HTTP类别/固定方法/状态/时长，未持久化URL/headers/正文/标识；恢复原profile开关并关闭自建forward。

可靠两轮数据：main_entry缓存命中1319/1235ms，首缓存内容1754/1687ms，SDKready5489/5140ms，内容→SDKready仍3735/3453ms。它们不含原生/引擎启动。自动化launch→确认14812/13234ms含UI XML查询、定位、输入与探针开销，不能称纯APP加载耗时；各内部trace不能和不同起点的host时钟直接相加。r6 Matrix /sync longpoll等待2962ms也不能直接视作发送阻塞。发送跨度内客户端生命周期、假sync/数据库、加密等待的精确贡献尚未逐段插桩；不能把1.5秒全归网络。仅两个同设备/房间/网络样本。

2222安装包SHA0ca7e72dd909e9c4cbb1a8f5ce1022d282ab156a3c29a454e2ea1bfb71382298，来源b53e7387，固定证书75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff。修正沿用已批准2026-10-17-startup-local-projection计划的同页metadata交接；无schema/权限扩展。pending缓存member isJoined=false/power0/canMentionAll=false，群不走好友数量猜测；canonical移除/空头像优先，timeline缓存保留。

RED：member-red-valid.log共5失败/5通过，含SDKready空成员、pending空成员、refresh旧投影、异步换Room晚结果、actual main首帧（0）；取消lease用例原已通过。member-red.log为未映射V盘环境失败，member-red-mapped.log含fixture配置错误，不作为行为RED。GREEN-r1进行中，最终须SPEC→QUALITY及冻结共享门禁。SDK Room.setState本身会发onRoomState，refresh显式淘汰是边界一致性，不能声称生产SDK缺事件。

环境Flutter3.44.9/Dart3.12.2、Win11、JDK17、API28 x86_64；host native Olm3.2.15 / SQLCipher4.10.0 / SQLite3.50.4，DLL hashes复用run-full.ps1预检。pubspec.lock SHA a43833c8e7c3d6faa93d21babdc61dfe4b3563c7ac00912006f26daa8e0ecc5d；.env不存在，不导入生产密钥运行聚合verify。阶段时间按r5/r6 receipt及后续门禁receipt；其余未精确计时，不估算。

03:05+08：GREEN-r2共40 PASS/0FAIL，含完整actual-main五场景/生命周期/页面回归；退出0收据已写。GREEN-r1失败在第五场景首次手动audit（SDK解除前），不是产品交接回归；隔离同输入通过，修正前提为全部两图已绘制，再开始逐帧严格审计。独立entry_safety_review顺序SPEC→QUALITY初审无阻断，待冻结确认。

版本占用预检：两工作区任务/计划未发现2223或0.4.54占用；current-state刚完成正式2216回退，当前模拟器2222。按既有Debug交付范围预留0.4.54+2223；pubspec只递增候选。旧正式2216及iOS2215不变。

下一步：冻结后共享全量/analyze，Android重建固定签名及本机验收；未经最终验证不称已交付修复，当前模拟器仍是2222。旧正式2216保持。
