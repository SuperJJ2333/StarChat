# 2204 RoomPage 生命周期断言调查与修复计划

**目标：** 正常进入会话、上滑历史、窗口重排和返回最新时，组件依赖、可见行几何读取及滚动位置生命周期一致，无 debug 红屏，并保留真实历史/已读/E2EE 行为。

**授权与范围：** 用户 2026-10-07 四项缺陷请求、“请你继续”、后续红屏截图和“进入会话或上滑历史”触发反馈。沿已批准的聊天/历史窗口行为做缺陷修复，不增加功能，不变更鉴权、密钥恢复或财务规则。常规调查及最小缺陷修复属于本次用户范围；正式发布、main 合并/推送未获授权。

**基线：** 分支 `codex/room-lifecycle-assertion`；复用 worktree `C:/Users/Administrator/.codex/worktrees/history-icons-performance-2204/StarChat` / U: 单一路径；起点 HEAD `2d2e9da5fa412391dce5db4a3f20d7009352aa9f`，实际 2204 移动源码 `3a620495ae048d3e4141f099e1926ecedc8669cd`。Flutter 3.44.9 / Dart 3.12.2，锁 SHA `ac0966cb75f61763073bfc48ef5e8b93b85cf6cf46ebaa921d8b3739c62694ac`；无 CodeGraph 索引，不创建索引。

**关联：** [任务台账](../../workflow/tasks/2026-10-07-room-lifecycle-assertion.md)、[产品规格](../specs/2026-08-12-starchat-product-modernization-design.md)、[移动交付工作流](../../runbooks/mobile-delivery-workflow.md)、[前任务计划](2026-10-07-history-icons-performance.md)。本计划当前处于调查阶段，尚无生产修改或新版本。

## 边界与文件所有权

- root 负责最早错误捕获、根因判断、明确领取后的最小生产修复与最后门禁；潜在源码限 `apps/mobile_flutter/lib/features/matrix/room_page.dart` 和直接相关 `timeline_scroll_anchor.dart`，仅在真实缺陷 RED 和根因确认后实施，扩围须先说明证据及更新所有权。
- room_lifecycle_repro 独占新 `apps/mobile_flutter/test/features/matrix/room_page_lifecycle_test.dart`。framework_assertion_audit 只读生产 SDK/源码，并独占新 `apps/mobile_flutter/test/features/matrix/conversation_cached_row_lifecycle_test.dart`，用**公共 Flutter 组件复刻现行首页缓存模式**（缓存 GlobalKey 行与 ListView.separated 重排）；未挂真实 MatrixHomePage，未覆盖真实首页服务/账号数据，3项诊断PASS，尚无 RED。lifecycle_record 只写本计划和新任务台账；索引由 root 管理。
- 证据只放 `docs/verification/artifacts/2026-10-07/history-icons-performance/framework-assertion-2204/`；原始敏感设备/服务器日志、正文、媒体、密钥和 tokens 不保存或输出。仅保留安全静态断言、编译源 frame、计数和身份元数据。
- 保留 Flutter 断言；不改 SDK、不切 release 隐藏错误、不吞异常制造通过、不卸载/清数据/降级；不通过手工给 controller 挂两份 fake positions 伪造产品 RED。
- 前任务资源/历史/服务器成功或失败证据保持原身份。2204 原启动 smoke PASS 不替代本次真实交互；新源修改不能沿用旧包或旧全量结果冒称修复完成。

## 1. 捕获与区分最早异常

- [x] 读图并核对已安装 0.4.35+2204、PID8170；用户触发为进入会话或上滑历史。
- [x] 核对本地 SDK：`framework.dart:6268` 是 InheritedElement 停用时 dependents 必须为空；设备 retained 栈只有 attached/多 position 两类，未包含 6268 首栈。
- [x] 只读审计真实 RoomPage：100ms timer 的行/viewport 几何读取缺少部分 attached 条件；`.position` 的 hasClients 防护未排除多附着。明确这些事实不证明 6268 首因。
- [x] 核对正常 snapshot 稳定 ID 去重、两 sliver 索引不相交；正常 GlobalKey 使用本身不是根因。条件性初始 adapter 同 txid 假设尚无合法来源事故证据，必须先证伪/真实 RED 后才能主张修复。
- [x] safe-only capture 19:50:09.241083–20:00:10.142693+08 已结束，exit0、487内存行、raw_saved=false，安全目标记录为空。没有新首栈，不据此认定原场景未再发生或缺陷消失。
- [ ] 保留最早 6268 的安全静态栈及具体 inherited scope，或在测试中独立定位前置条件违规；区分第一错误与后续清理/滚动异常。
- [ ] 根因必须解释当前单个 AnchoredTimelineList 为什么能出现多 position，或证明它是此前树更新异常后的后果；合法 GlobalKey reparent、SessionGate 动画、history clone 都不得仅按相关性归因。

退出条件：证据足以支持一条具体因果链或可独立验证的缺陷，不用 screenshot/secondary stack 推断全部根因。

## 2. 真实产品路径的失败行为用例

- [x] 新测试挂实际 RoomPage，1200 合成事件、360×800、真实 read/lease 边界和100ms timer；快速反向拖动、cache-anchor↔latest、MotionPageRoute push/pop 与混合媒体；真实SDK held/context+limited sync+history/ballistic后执行公共窗口动作，**旧 sliver center 实际被替换，覆盖现有 GlobalKey 行重排路径**；静态group/direct→group变化和active拖动中真实公告服务合成响应展开。NEW `room-page-lifecycle-six-metadata.json` 绑定20:02:17.4049407–20:02:42.4506457+08测试/analyze各exit0，最终 **6 PASS/0 FAIL、未复现原缺陷**；最终test SHA `9b25b91880d1c8695c3eab3bc0daa1ccba15b3449bbab19e5d47caa9fa106642`。旧3项回执只作历史输入身份，不重复计数；return-latest和center窗口动作设置错误均为fixture问题，不是产品RED。未直接断言具体旧消息ID裁剪或Element/GlobalKey实例保持。
- [x] 公共 Flutter 组件复刻现行首页缓存模式的3项诊断PASS/exit0，未挂真实MatrixHomePage/首页服务/账号数据；与实际RoomPage6项共**9项诊断PASS**，覆盖不同，非全量，不能证明原始6268已修复。停止无新依据的同类stress，下一步依赖最早静态异常栈/具体缺失输入。
- [x] 两个新增测试文件均文件级analyze exit0/no issues，测试输入SHA各自与最终回执匹配；本轮诊断tests/docs独立SPEC→QUALITY待审，回执由root在证据目录独立归档，不等于根因修复的审查或完整移动门禁。
- [ ] 根据第一步的新事实增加缺失条件：离屏/keepalive 行、同帧窗口中心变化、异步 history/sync 到达或真实路由生命周期；优先 public application interfaces，不破坏真实产品生命周期。
- [ ] 在生产修改前运行失败用例，记录首异常/预期缺失、真实退出码、输入 hash、工具/OS/锁与日志；独立确认失败是原 BUG 而非 fixture 或环境。

退出条件：L1–L3 相关具体缺陷真实 RED。尚未满足，不先改 production guards 当成完整修复。

## 3. 最小根因修复与相邻回归

- [ ] 实现符合第一/二步证据的最小变化：正确解绑/树身份/单列表拥有权，或仅对实际附着可见行做几何读取；不改变可见已读、提及、撤回、窗口连续性及返回最新语义。
- [ ] 原 RED→GREEN，检验无长期双挂载、无离屏行坐标读取、无丢消息/错误已读；相邻历史锚点、快滑、异步窗口裁剪、route pop/push 与媒体观察通过。
- [ ] 先 SPEC 审查：是否解决实际缺陷和保留既有语义；再 QUALITY/SECURITY：controller/key/render 生命周期、async cleanup、无敏感日志/异常隐藏。若审查要求修改，按受影响范围增量复核。

## 4. 最终同源验证与有身份的交付

- [ ] 冻结最终源/相关输入，focused→analyze→完整 Flutter 共享门禁；预检 `verify.ps1` 的环境，缺环境如实记未执行，不引入生产秘密。未改的平台/资源门禁只按输入相等和覆盖范围复用。
- [ ] 若需要新 Android 候选，先核对线上/CI/其他任务版本占用后保留新 build；按 [APK 重建流程](../../runbooks/android-apk-rebuild.md) 源构建→常规 DEX/资源/manifest 重建→对齐→固定 signer→实际完整资源/语义/签名审查。只用本 worktree 的 U: 路径，不沿用旧 S: helper 或混用输出路径。
- [ ] 保留数据覆盖安装，读回实际版本/UID/首装/包 SHA；运行原进入会话/上滑历史/快滑/返回最新场景并捕获静态首异常。启动 smoke 与交互验收分别记录；手机弱网、iOS 平台验证单独记录其覆盖和缺口。
- [ ] 更新任务记录和 root 管理的索引，区分源已提交、包已构建/安装、正式发布和用户真实复测。原 2204 证据不覆盖后改源的新包；未经授权不合并 main/推送或正式发布。

最后更新：2026-10-07T20:05:37.287+08:00。当前只有调查及9项诊断PASS，无原始6268首栈或真实缺陷RED；生产源/SDK未改，无新构建或发布。
