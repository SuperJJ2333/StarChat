# 2026-10-09 私有 Android debug 交付

已完成用户批准的方案实施与模拟器 debug 推送阶段；全量性能目标仍有明确缺口，未发布正式渠道。

## 实际安装
- 2026-10-09 06:15–06:16 +08，emulator-5556，Android9/x86_64。
- com.liuhetong.mobile.debug：0.4.35+2204 → 0.4.39+2208，adb install -r Success，无卸载/清数据。被动启动仍在前台、进程存活、AndroidRuntime 错误0，不等于真实账号收发及真机性能验收。
- [APK](artifacts/2026-10-09/mobile-responsive-maintenance/delivery/ChatFlow-0.4.39-build2208-x64-debug.apk)：125811233 bytes，SHA256 ca846bc29f68f070856ebd23597f179adf19abaa7ccc29635ba031ca54bfb369。
- 固定证书75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff；source→Apktool2.12.1 DEX/资源/清单重建→zipalign16KiB→固定签名→独立重解包/语义/资源/ABI校验，BUILD_2208_PASS。
- 输入1928files，manifest dc52b47efbe8c6e38ed4e6074861ff1f6154f37bb71809eff69ed57c5edd2219；基线b09bf2f2加冻结工作树变更。原QA键盘已恢复，临时助手已删除。

## 实现与证据
旧历史保留不可变源与增量权威，分页/同步普通入口不等待完整迁移；有界只读加密worker、持久成员加速、WAL、取消/关闭和大批次查重修复。保留数据/E2EE，不用临时排序或未知ID当不存在。

资源排除测试/备用资源与动态WebP，保留完整静态SVG/字体；动画私有缓存、SHA校验、ETag/Range恢复、WiFi预取、内存裁剪及交互共享维护预算。原生诊断发现搜索索引输入时仍读正文，新增租约及每条正文前后暂停检查，取消页面关闭重启游标；7真实RED→66 focused GREEN、SPEC→QUALITY PASS。用户明确个人使用，真实Personal Use Only标注保留；本地资源集未上传，未部署的默认CDN地址不能称可用，静态回退可用。

Android差分已实现流式64KiB缓冲/签名描述符/基线和成品SHA/原安装器确认与完整包回退。实际2206→2207补丁11151156bytes（10.64MiB），约省86.58%下载量，完整还原SHA相同。不是最新2208补丁；当前正式API未配置签名差分，仍完整包回退。

## 验证结果及复用
最终生产输入全量Flutter5706PASS/9SKIP/1FAIL，唯一FAIL是新测试将反向列表位移符号算反。修正仅测试采样：AxisDirection及live帧中心可见气泡，保留锚点≤1px、渲染位移与滚动差≤2px、Ballistic/单scrollposition/≤200models。整个受影响RoomPage文件8PASS；不将全量exit1写为exit0，不重复未改生产的全量门禁。

Android原生全套23PASS/1FAIL（同一取样问题），修正后对应原生1PASS；合计覆盖24项，包含50真实键盘展开/收起循环、历史pending输入、100k记录刷新、切房、250k/1M真实加密存储/旧写失效/关闭。复用未受test-only采样影响的其余23项，不伪称重新全套exit0。

App analyze无问题，最终两项测试文件analyze无问题。vendor全库51已有问题exit1，独立同工具baseline52/新增0，保留解释。Python边界376PASS/23SKIP；policy/deployment/template PASS。完整verify因缺.env未执行，不导入生产秘密。详细receipt/review/input及失败原日志保存artifacts/2026-10-09/mobile-responsive-maintenance/。

## 未完成的性能/分发范围
原生1M首页面201ms，首次精确陌生ID查重5131ms，第二次212ms；100rooms/10legacy×250k缓存恢复2386ms。任意不透明旧JSON首次准确成员确认仍随N扫描且阻塞该同步/写操作，完整历史SPEC仍NEEDS_FIX；质量仅批准私有debug。后台扫描虽离UI，不可承诺任意历史量全部恒时、完全无卡顿或进程RSS≤8MiB。Debug合成场景build p95约21.7ms，未做真机profile/实际账号端到端验收。

正式Android2206/iOS2205、官网候选2207与更新弹窗均未改；无服务器写入/资源或补丁公开分发。下一步继续降低首次精确成员确认及必要预览等待，并以真机profile和大历史账号验收为正式升级门禁。
