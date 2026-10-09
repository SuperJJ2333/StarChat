# 大历史会话交互、快滑与弱网顺序修复

## 恢复入口

- 目标/授权：用户2026-10-08“针对该问题进行修复”，包括大历史房间、手机正常操作、输入法键盘与房间切换；延续已确认的自动重试保持位置、分页增量处理、锚点/惯性一致方向，无需重复确认内部可逆实现。
- 规格：[本次规格](../../superpowers/specs/2026-10-08-history-interaction-fix.md)。前置调查：[大历史任务](2026-10-08-large-history-2204.md)、[新消息顺序任务](2026-10-08-weak-network-order-2204.md)。原批准计划中的RED→根因修复阶段继续执行。
- 状态：源码修复与自动化完成；待真机、待正式版本交付。[实施计划](../../superpowers/plans/2026-10-08-history-interaction-fix.md)已实现；Android原生编译及SQLCipher接口检查通过，独立SPEC→QUALITY产品审查接受。
- 工作树：C:/Users/Administrator/.codex/worktrees/history-icons-performance-2204/StarChat；Flutter唯一运行入口U:/apps/mobile_flutter；分支codex/history-interaction-fix，基线70dee48a5b2a3b135db6df095f12ff6ce2ca6807。primary全部原有WIP保留。
- 文件所有权：fix_retry_insertion仅controller与automatic_retry_order_test；两个设计代理仅各自证据目录，产品代码只读；root拥有本任务规格/计划/台账/汇总/索引。后续单元分配记录在ledger。
- 源码commit：3c37b52960ab79b46566fb16d84fab280b34a7c2；之前ORDER 4d086187和FLING d9abd7ba均在该分支。46项修复文件提交前后SHA与最终测试输入一致，未合并main或推送。
- 最后记录：全量Flutter实际exit0，5632PASS/9既有ANNOUNCEMENT_DIAGNOSTICS opt-in skip，1424输入零漂移；格式44文件零变更、app/vendor分析0问题、移动Python354PASS/1既有Ruby skip、UI34组件/535页通过。Android ARM64 profile编译exit0，1476输入零漂移；新库六个SQLCipher key/blob符号均存在。首轮46FAIL及返工证据保留，最终全量覆盖真实事务/恢复修正及旧fixture契约更新。见[交付报告](../../verification/2026-10-08-history-interaction-fix.md)。
- 下一条可执行步骤：需要正式交付时先核对未占用的新version/build并按固定APK重建/签名/分发流程准备成品，不能复用2204 URL或给用户安装profile中间包；可连接设备后再测真实键盘、连续快滑和A→B→A帧耗时。用户已回复暂时无法USB连接，手机帧测量延期；没有Mac/iOS runner，不宣称手机/iOS验证。

## 验收台账

| ID | 场景及预期 | 实现 | 测试/证据 | 发布/真机 |
| --- | --- | --- | --- | --- |
| ORDER | 自动/手动重试位置稳定、同txid；首次权威sync一次校正 | 4d086187 | RED2PASS/2FAIL→GREEN89PASS；有序双审/root新32中4项重试通过 | 候选，未发布 |
| STORAGE | 顺序分页/定位/写入不解码全房间ID；旧库后台迁移与恢复连续性 | 索引、SQLCipher增量blob迁移、事务内读写一致及独立RECOVERY fragment已实现 | 加密迁移1k/10k/100k/250k、ACK最大256、稀疏页、快照/回滚/恢复161与80页控制均GREEN；最终全量覆盖 | Windows原生与Android编译证据，不替代手机/iOS运行 |
| SOURCE | SDK与消息投影有界；普通刷新/键盘不随总历史扫描 | revision缓存、1000常驻/200可见、双向分页已实现 | 完整4500正文/ID/重开、pending独立保留；实际1k/10k/100k预算与最终全量5632PASS | 未测手机帧 |
| FLING | 同extent重基后连续帧锚点/惯性保持、竞态取消 | d9abd7ba，correctBy使惯性重建 | 初RED→32PASS；双向/extent/padding/held-drag10PASS；真实页面8px RED→G15 IME+ballistic2PASS | 候选，未手机profile |
| INTERACTION | 键盘、房间切换、收发与分页重叠可响应 | 实际页面回归完成 | 三N预算、输入selection、A→B→A迟到页、held-drag、真实ballistic、padding-only公开负/正控制均被最终全量覆盖；首轮错误推断保留撤回记录 | ADB无设备；用户暂时无法USB，手机帧测量延期 |
| GATES | 格式/分析/共享全量/相关原生与有序双审 | 源码提交并绑定证据 | format44零变；app/vendor0问题；Flutter5632PASS/9skip；Python354PASS/1skip；UI通过；SPEC→QUALITY接受，无未解决P0/P1/P2。verify.ps1缺.env未执行 | Android profile编译及六符号PASS；手机/iOS未执行 |

## 版本与证据

- 实际线上：Android0.4.35+2204，发布源3a620495，既有固定签名成品，事实复用原发布任务；本次尚无新包/版本设置改动。
- 候选父源：70dee48a（文档）/71355adb（语音候选代码），未发布。
- 本次源码：3c37b52960ab79b46566fb16d84fab280b34a7c2。Android原生编译中间包SHA a7d81ad71794c8fcb979705d4aaef440bcfa248069d70d8eb3c49a57827b5fae、95527985bytes，位于managed apps/mobile_flutter/build；仅profile编译证据，不是固定正式签名交付成品，未安装或发布。
- 证据根：docs/verification/artifacts/2026-10-08/history-interaction-fix。日志仅合成或非敏感工具信息。测试记录必须含真实exit、源码与锁hash、工具OS、通过/失败/跳过、未执行项。

## 阶段计时

| 阶段 | 开始+08 | 结束 | 类型/并行组 | 结果与下一步 |
| --- | --- | --- | --- | --- |
| 恢复/设计审计 | 首次可靠clock01:47:02，实际开始更早未知 | 进行中 | root主动；retry/storage/render并行 | 分支基线确认；精确契约形成中 |
| ORDER正式RED/GREEN | 02:01:27+08 | 02:02:16+08 | 工具执行，分段4.974/7.773秒 | 2意图FAIL→89PASS，后有序双审及root新门禁后提交4d086187 |
| FLING补充门禁 | 02:55:44+08 | 02:55:52+08 | 工具执行7.559秒 | 10PASS；03:05:48规格审查→03:06:22质量审查接受，提交d9abd7ba |
| SOURCE首轮语义RED | 02:57:58+08 | 02:58:04+08 | 工具执行5.607秒 | 原始读取2k/20k/200k与语音stop竞态4项FAIL，无编译错误 |
| SOURCE首片G1/SDK常驻RED | 03:15:21+08 | 03:15:32+08 | 工具执行10.345秒 | 38PASS/1常驻1100>1000意图FAIL；源码输入未变，SDK单元继续 |
| 首轮共享全量/返工 | 05:33:19+08 | 05:39:43+08 | 工具383.2032697秒 | 5585PASS/9skip/46FAIL；真实事务/恢复缺口与旧fixture暴露，保留日志，不计为通过 |
| 根因与fixture收尾 | 05:39:43+08之后 | 05:59:34+08 | 并行实现，U顺序门禁 | source51PASS、memory2PASS、storage65PASS/1分页fixtureFAIL→root16PASS，真实exit/输入以metadata为准 |
| 最终format/app/vendor | 05:59:53+08 | 06:01:00+08 | 工具串行 | format44零变、app21.6910622秒/vendor4.1227128秒均0问题 |
| 最终Python/UI | 06:00:42+08 | 06:01:48+08 | 与U门禁独立并行 | Python354PASS/1skip；UI34组件535页PASS |
| 最终共享全量 | 06:01:09+08 | 06:08:15+08 | 工具425.848787秒 | 5632PASS/9skip，exit0，1424输入零漂移 |
| Android原生编译 | 06:09:27.825+08 | 06:12:25.908+08 | 工具178.0830532秒 | 官方pub.dev强制锁+ARM64 profile编译exit0，1476输入零漂移 |
| 新原生库接口检查 | 06:13:03.469+08 | 06:13:03.549+08 | llvm-nm | key/blob open/read/write/close/bytes六符号PASS，绑定新APK SHA |

## 交接与回退

- 已证实根因：重试重设时间使pending先于ACK换位；整片段JSON和全SDK事件投影随历史增长；equal-extent correction未重建ballistic模拟。
- 存储恢复缺新head顺序另有真实公共路径RED；不要按时间排序拼接无连续证据历史。
- 生产与源码分开记录；没有生产写入、数据库/账号清除、卸载或密钥变更。
- U Flutter/Dart锁动态授予一名执行者，当前状态以progress ledger与代理ACK为准；禁止并发Flutter/生成流程。
- 共享文件已移交：SDK timeline.dart由implement_resident_sdk独占；应用capability/投影/分页消费者由implement_bounded_source独占；DB/API/worker/preflight由implement_indexed_history独占。稀疏版本页可为空但rawCount/hasMore继续，所有消费者按原始页预算前进。
- verify.ps1依赖root .env，当前缺失；相关移动门禁继续执行，缺失只阻断该聚合命令。
- 用户已回复暂时无法连接USB；该缺口只阻断手机帧耗时及真实设备行为反馈，不重跑已完成的等价源码门禁。
- 存储更改是增量顺序元数据；正文和旧迁移源保留。需要回退二进制时按storage证据的关闭客户端、旧格式导出/身份及数量校验路径，不能宣称旧二进制透明兼容新格式写入；未对生产库执行迁移/回退。
- 编译保留了现有12插件KGP未来迁移提示及Java过时/unchecked提示，锁定插件/Java源码未更改；不是零编译警告。缺Ruby/iOS、.env、手机设备的边界明确保留。

## Final closure — 2026-10-08T06:19:28.7725774+08:00

源码3c37b529；SPEC→QUALITY接受，独立38项证据审计无不一致。全量5632/9skip与Android178.0830532秒/六exports均通过，所有移动输入提交后不变。首个可靠clock01:47:02+08至本记录跨度04:32:26.7725774；实际开始更早未知，此值不是精确总工时，主动/工具/并行耗时不相加。首轮全量返工由真实事务/恢复及旧fixture问题导致，adverse日志保留。用户无法USB，手机/iOS/frame/聚合.env限制与无发布状态明确。
