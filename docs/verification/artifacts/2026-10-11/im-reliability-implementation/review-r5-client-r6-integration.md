# R5 客户端与 R6 集成复核

审查顺序：先 SPEC/domain，再 QUALITY。集成候选 4662f576（R5 ddfa73b9、R6 c772a503/6ee91ed7/1f527262/8242b89f）。root 非上述实现者。

SPEC/domain PASS：iOS 普通推送携带版本/持久 revision/IANA/时段；静态静音无 sound；挂起期间由已部署 Sygnal 在发送时判定跨午夜/DST。缺少有效 timezone 时保持可见静音并待重试，不依赖 NSE 定时器。AppHome 已实际装配 policy，Swift 使用现有 APNs channel。服务端 fixture 已由作者在精确 Sygnal 验证，原生和真实设备仍未执行。

QUALITY PASS：注册 generation/owner、RPC timeout、服务端 429 硬退避保持；偏好并发收敛与持久 revision 序列化，诊断无 token/正文。R6 每房真实传输单飞、跨房上限 2、解析独立；UI 超时不释放 SDK ownership。复核发现的删除持久行、页面注销、scheduler 启动前已有前台发送边界均已有正式回归及修复；registry 保留 detached settlement，AppHome 实际传入 roomSettlements。真实未结束的两个房间会继续占满传输额度，这是容量约束，不能用 UI timeout 冒充释放。

独立组合验证：message_send_scheduler_test、unbound_resolution_retry_test、outbox_send_flow_test、ios_push_policy_test、matrix_pusher_service_test、managed_pusher_gateway_test 共 135 PASS，exit 0；日志 r5-r6-integrated-tests.txt。第一次命令日志相对路径多一级导致 shell 重定向失败，Flutter 未启动；纠正路径后本组合执行通过，不把前一次 shell 的退出码计为测试通过。

结论仅覆盖源码/确定性专项。共享全量、Android 成品、iOS 原生编译及 Focus/静音/锁屏的真实声音与点击验收仍待。通知平台准入未放宽，VoIP 策略未变。
