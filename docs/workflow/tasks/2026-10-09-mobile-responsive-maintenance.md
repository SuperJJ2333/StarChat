# 历史后台维护、资源瘦身与差分更新

## 恢复入口

- 用户授权：2026-10-09明确要求清理资源→动态表情分离→测量实现差分更新；并修复2207等待旧索引与交互/内存问题。
- 当前阶段：用户明确批准方案并要求模拟器 debug 包；历史、资源、差分三个独立域实施中，尚未集成验收或安装。
- 工作树：managed android2205-sync-deadlock/StarChat，实施基线 b09bf2f2；primary 本次确认已有 .git，不沿用历史无 Git 假设。三个代理互斥所有权，根负责集成/build/device。
- [批准设计](../../superpowers/specs/2026-10-09-mobile-responsive-maintenance-design.md)及[实施计划](../../superpowers/plans/2026-10-09-mobile-responsive-maintenance.md)。本次只安装模拟器 debug，不升级正式官网或弹窗。
- 时间：2026-10-09+08；03:39源码核对/03:40差分实验及更多预算路径核对，后续时间以工具证据为准，起点工时未知不估算。
- 下一操作：完成有界 BLOB worker/过渡去重修复与独立评审，集成回归后固定身份重建 debug，保留数据覆盖安装 emulator-5556。

## 验收台账

| ID | 预期 | 当前证据 | 缺口 |
| --- | --- | --- | --- |
| ROOT | 解释2207旧索引等待 | Client/Database/TimelineIdStore逐段源码证实普通sync和snapshot仍await完整prepare | 无用户手机堆栈，不宣称唯一空白根因 |
| UX | 键盘/切房/快滑优先且内存有界 | 既有view最多200models；动画默认无总上限且SuperEmojiMessage直接Image.asset | 尚无新实现/Android帧与heap实测 |
| SIZE | 清测试/备用后分离大表情 | 复用[体积审计](../../verification/2026-10-09-android-apk-size-audit.md)，0.71/1.21/7.29MiB | 未改pubspec、未新包 |
| DELTA | 测量可验证还原补丁 | [实测JSON](../../verification/artifacts/2026-10-09/android-apk-size/entry-delta-measurement.json)：10.56MiB/节约86.675%，完整SHA正确 | 桌面实验非手机更新实现 |

## 版本与实验

旧2206 SHA fb7005f59c0a8e7a16a633a06f5cca10d30784c4508912cb442d95cefbd02436；新2207 SHA ad8cc9d8826130449e21eb094b42728349bcf0590f021b71ac82e8c03fe0e324。实验measure_entry_delta.py运行exit0，输出patch11,074,501bytes及完整还原83,110,942bytes，1次确切还原断言通过。第一轮整ZIP record比较没有可copy记录（header变化），输出47.88MiB；第二轮payload粒度60,577,810bytes可copy，10.56MiB。改进有依据，不隐藏首轮无copy；两个产物均本地实验，最终artifact已由第二轮替换。

实验在Windows/PowerShell7、现有Python/zstandard进行，只读已签名输入；不安装依赖，不实现移动端。脚本整个literal载入内存仅用于桌面选型，绝不能直接复制为手机实现。输出所有临时文件在docs/verification/artifacts/2026-10-09/android-apk-size/。未运行Flutter门禁、没有新的生产发布或后台隧道。

## 交接

- 正式2206与候选2207仍原渠道；iOS原渠道不改。
- 已排除“init必须等首次网络sync”这一泛化结论：当前init显式waitForFirstSync:false，列表预览有限页但旧JSON读取成本待量测。
- 下一implementation需保留旧source+delta的原子权威，不能仅unawaited prepare，不能把旧索引不ready当作无消息。
- 设计审阅要求来自brainstorming/SKILL.md的architectural gate，说明用户功能授权已存在；待审的是新写出的具体方案。

## 已批准实施阶段

模拟器 emulator-5556/Android9/x86_64 已连接，现有 .debug 为2204，保留数据与固定签名覆盖升级。普通 nonlimited sync 和 snapshot 被持住 reader 的 RED 已复现，初步过渡权威 GREEN；250k/1M 前台 SQL 扫描仍超过预算，正在改有界 worker，不能将初步通过写成完成。资源域 focused56与传输2通过，真实生命周期取消无需覆盖 Flutter 测试不变量；差分 Python4/Flutter22/Android JVM7通过，实际2206→2207流式补丁约10.635MiB、完整还原 SHA 正确。官方 pub.dev离线锁门禁已通过，镜像host首次失败65保留。完整verify缺.env，未执行不称通过。可恢复证据位于managed docs/verification/artifacts/2026-10-09/mobile-responsive-maintenance/各域；后续最终报告迁回primary。

## 实施裁决与已测边界（04:31+08 后继续）

- 用户明确个人使用；原动效上游当前 Personal Use Only 与原目录 MIT 标注不符，按实际源许可与历史取得 commit 未知记录，不虚称商业授权。静态 Microsoft 完整 MIT 保留。仅本地资源集/私有 debug，本轮不公开上传资源或改正式渠道。
- Task3 规格→质量分别发现后台持租约与 await pause 后取消竞态；两轮 genuine RED→GREEN 完成，最终26Flutter/9native，双评审PASS，尚无系统安装端到端设备证据。
- Task2 首轮74Flutter/15pressure/30Python资源门禁；SPEC 四缺口（许可/通话/WiFi切换/ETagRange）返工，不能复用首冻结宣布最终通过。
- Task1 native source DELETE journal 与并发写入 BUSY 实证后采用 key 后 WAL、只读 source worker、同 cipher/account/source revision 绑定的 metadata sidecar。曾30 focused通过；正在同尺寸旧写/rollback/大批次查重hint回归。不能把阶段性30视为最终门禁。
- Root 安全裁决：不接受未知 ID 当作 absent，不接受后续气泡重排掩盖查重。对任意未索引不透明旧JSON，首次精确未知ID查重不存在普遍恒时算法；保留前台 UI/缓存/本地 pending 可用与离 UI 有界扫描，之后持久加速。首次未知 ID 可能仍等待扫描，不能宣称首轮收发完全与 N 无关。1M首membership曾8865ms，250k1055ms；其他room capture约1ms、UI timer有进展，测量含 encrypted checkpoint/key 开销。RSS增量约5.9–9.7MiB或首轮17MiB含VM/native，不能说整个进程≤8MiB。
- 100room/10legacy×250k实际恢复预览2457ms，getRoomList仍等必要预览；不称瞬时列表。既有 stale preview 正确性不能随意跳过。
- Root 确认 >512当前批 hints可被逐出、internal positions>256可能 RangeError，已要求真实600/1000events与两房300覆盖修复，未闭合前不能打包。
- policy/部署policy/template三个适用前置门禁已实际PASS；full verify仍缺.env，Flutter/shared/analyze/设备/build未开始。

## 集成门禁开始（2026-10-09）
用户说明仅个人使用，资源许可保留真实 Personal Use Only；无商业授权推断。本轮仍仅私有 debug，不上传资源集/更新正式官网/推送正式弹窗。
Root 同步 pubspec/core 为 0.4.39+2208，version contract 3PASS，官方 pub.dev normal pub get --enforce-lockfile exit0，依赖锁未升级。
Task2最终SPEC/QUALITY通过；Task3最终SPEC/QUALITY通过。Task1复核原问题2跨legacy实际分页与问题3自适应迁移/GC已修；完整SPEC仍NEEDS_FIX，首次精确未知ID查重1M约8.96sec仍阻塞global sync，仅允许后续质量审查后的私有debug验证，不构成全部性能目标完成。
Root适用Python边界门禁376PASS/23SKIP；SKIP需逐项记录原因。App flutter analyze clean；整个vendor analyze exit1/51issues，正在同工具baseline复现，不能写全量analyze通过。
Root全量Flutter发现相关失败 cooperative_matrix_database_test cached receive burst：Legacy membership requires preflight outside transaction；已交作者真实RED→GREEN修复，最终SHA/评审/全量与build均须重新绑定。当前未打包、未安装。

Close-test correction and extended foreground paths:
First timeout was a test waiting for reader entry after null uncommitted metadata; corrected exact source identity fallback preserves generic callback once. Subsequent serial-close RED separately proved real ordering deadlock: search awaits writer gate while exact lookup needs timeline cancellation; close now starts both stores' cancellation before draining, Future.wait eagerError false then collection finally. Public-history GREEN2 and cooperative13 preserve this regression. Root independently inspected implementation and actual logs. Final extended SDK scoped analyzer Noissues. Current full vendor remains explained baseline51 diagnostics. Root-owned native keyboard case raised to50 actual show/hide cycles (100 transitions), no production implementation changed. Android synthetic audit.debug data isolated from existing user.debug; final stable-signed overwrite retains data. Refreeze/final reviews/shared/native/build remain pending, no installation claimed.

## 私有debug交付（2026-10-09 06:16+08）
已完成0.4.39+2208 x64 debug固定签名重建及emulator-5556保留数据覆盖安装，SHA ca846bc29f68f070856ebd23597f179adf19abaa7ccc29635ba031ca54bfb369，启动被动smoke PASS。测试程序实际包名.audit，不是.audit.debug；原QA IME已恢复。完整性能SPEC仍NEEDS_FIX，首次1M未知ID约5.13sec，100rooms缓存2.39sec，非正式发布。全量5706PASS/9skip/1测试测量FAIL随后affected file8PASS；原生23PASS/1同测量FAIL随后focused1PASS，不虚称两次全量exit0。资源/搜索/差分SPEC→QUALITY通过，正常依赖锁冻结1928files，26个构建步骤exit0。完整证据/限制/下一步见../../verification/2026-10-09-mobile-responsive-maintenance.md。下一步继续首轮精确查询及预览等待优化，真机profile待设备；官网正式2206/iOS2205/弹窗不变。
