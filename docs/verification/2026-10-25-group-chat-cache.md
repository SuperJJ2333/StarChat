# 群聊消息加载、引用缓存与 Codex worktree 维护

本轮交付源码及验证，不生成新 IPA、不发布、不合并或推送。分支 `codex/group-chat-cache-20261025` 基于 `20962711`，保留此前冷启动时间顺序/失败气泡窗口/提示移除修复。工作树：C:/Users/Administrator/.codex/worktrees/maintenance-completion/StarChat。

源码提交：`0e9a760b13c8b7c53a141c4be89b4bf3663ee24a`；本轮源码范围 `20962711..0e9a760b`，6个生产文件和2个测试文件，新增18项回归。2026-10-25 14:53 +08验收；文档另行提交，不混入主工作区既有改动。

## 已确认问题与修复

1. **分页边界更新被缓存忽略。** 最后一页为空或边界独立变化时，消息行和 SDK presentationRevision 可以不变；原复用条件会让本地失败气泡或账户发送队列停留在旧显示状态。控制器和 SDK 投影现在纳入双向边界，保留原时间戳、原发送身份及连续窗口。
2. **引用缓存失效链不完整。** 仅清房间私有缓存会漏掉进程缓存、退出房间后的更新、控制器旧副本及页面 loaded 状态。现在账号既有事件监听按账号/房间/事件精确失效，房间缓存使进行中查询结果失效并清投影，控制器遵从来源当前结果，页面只重查失效成功项。撤回支持两种目标格式；替换通知使目标失效后重新读取，未新增或改动 Matrix 编辑聚合语义。
3. **隐藏本地历史后仍能命中旧引用。** 同步缓存读取与异步解析都重新执行当前本地过滤；引用卡片不以旧状态覆盖过滤结果。
4. **热门引用按写入次序被淘汰。** 读取现在提升 LRU 次序，容量仍为 256；无需加大缓存，也不新增明文持久化。
5. **合并旧房间的引用衔接。** 移除控制器旧副本后，复审发现多来源逻辑会话的窗口外引用失去缓存入口。现在依原房间读取权威结果，并用既有 256 项有界路由提示跨快照保持来源；源失效后不从旧合并投影复活。
6. **旧式适配接口兼容。** 质量审查发现仅支持单事件查询的旧式 capability 被包装为窗口适配器时会丢失成功引用复用。虽不在当前生产链，本轮也用 RED 复现并修复：fallback 适配器接管原控制器128项预算，统一过滤隐藏目标，并拒绝销毁后的迟到结果；真实SDK来源的空结果仍保持权威。
7. **回执不应引发额外消息刷新。** 全量发现新增失效监听无条件通知导致两项既有性能回归；单独运行稳定复现。现在只在存在实际消息事件ID/撤回或替换目标时发出引用失效通知，不为没有消息身份的回执或正在输入事件增加刷新。

修改限定在 Matrix 展示适配、控制器、页面和内存缓存。钱包/认证/密钥协议、SDK持久化、依赖锁、发布版本及工件身份未变。消息窗口仍为初始40/最大200；不清用户聊天记录或缓存，不需要数据迁移。

## 验证与审查

原始证据根（Git 忽略）：D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-25/group-chat-cache/。

| 检查 | 结果及覆盖 |
| --- | --- |
| 初始有效 RED | red-cache-expanded：7 FAIL / 1 PASS，exit1；双向本地/账户 pending、两种撤回、LRU |
| 生命周期补充 RED | red-reply-lifecycle：8 PASS / 4 FAIL；退出重进、控制器副本、隐藏过滤、替换失效 |
| 实际引用卡片 RED | red-quote-ui-final-fixture：3 FAIL/exit1，旧正文仍在 widget tree；没有 teardown 超时 |
| 多来源 RED | red-retained-reply：1 FAIL/exit1，成功解析后 cold 引用仍为 null |
| 定向及兼容补验 | green-final-focused：80 PASS/exit0；red-legacy-wrapper：2 FAIL/exit1；green-legacy-wrapper：114 PASS/exit0，含本轮15核心回归+3真实页面回归，以及适配器、历史合并和性能整文件；最后增量为后续121项 |
| 较早相邻回归 | adjacent-cache：626 PASS/exit0；属于较早候选，不冒充最终源码全量 |
| 回执刷新 RED→GREEN | failed-full：6408 PASS / 9 SKIP / 2 FAIL；red-receipt-refresh：5 PASS / 2同因FAIL；green-receipt-refresh：121 PASS/exit0，9整文件，保留原性能断言 |
| 规格审查 | spec-review.md 初审 BLOCKED 原件保留；spec-review-final.md、spec-review-addendum.md、spec-review-receipt-refresh.md 均 PASS，最后增量身份覆盖此前旧SHA |
| 质量/安全审查 | quality-review.md PASS/1个非生产P3观察；主动闭合后 quality-review-addendum.md、quality-review-receipt-refresh.md PASS，无剩余P0–P2阻断，绑定最终增量SHA |
| 完整 Flutter / analyze | full.log：**6410 PASS / 9诊断开关SKIP / 0 FAIL，exit0**；full-analyze.log：No issues found，exit0；14:41:57–14:52:54，测试637.401秒 |
| Python 环境前置 | scripts/verify.ps1 -PreflightOnly，exit0，锁/依赖、真实 stdin、配置导入均通过 |
| 最终移动边界 | mobile-receipt-final.log：404 PASS / 1 Ruby条件SKIP，exit0，40.97秒 |
| 最终 UI 契约 | ui-receipt-final.log：34 components / 540 screens PASS，exit0 |
| 诊断开启变体 | diagnostics-receipt-final.log：9 PASS / 1 SKIP，exit0；该跳过项为默认关闭分支，由默认全量覆盖 |
| 格式 | dart format --output=none --set-exit-if-changed：8 files / 0 changed，exit0 |

5万条历史、1000 sender pool、入群通知、窗口投影和滚动相关合成回归通过；这是宿主算法/组件覆盖，不是实际千人并发服务器压测或 iPhone 帧率测试。不宣称已经提升多少毫秒或真实用户端已修复。

默认全量跳过的9项在诊断开启变体中全部通过；变体自身跳过的默认关闭分支在默认全量中执行。移动门禁剩余1项Ruby条件跳过，仍需补验。`delivery-validation.json`确认8文件当前SHA与相应最终审查、完整运行输入全部匹配；full-receipt.json 的 source_stable=true、drift=[]。完整输入清单 full-inputs.json 的SHA256为 `da4667d292ae2719e35e1499385060aeec32caebe0135f96f2f5d2432c6b9cb2`，绑定工作区原始字节（不等同于Git可能规范化换行后的blob哈希）。依赖配置/锁未改，主树HEAD及516条状态逐项一致。

最初的 Fake 缺少现有接口、格式 lint、页面夹具缓存隔离/清理时机错误均保留原日志；补齐夹具后取得对应真实行为 RED，不降低产品规则或断言。

补验诊断变体时曾把测试路径漏写 group_ 前缀，加载失败记录保留在 diagnostics-missing-target*；改为仓库真实路径后运行通过。该执行入口错误不算产品行为失败。

首次最终全量在14:24启动，14:25确认上述旧式兼容问题后仅终止本任务PID树并保留 cancelled-full*、full-cancellation.json；没有在运行中修改源码，也不把取消结果称为通过。既有归属不明的PID187384保留。

第二次全量14:28:42–14:38:28完整结束为失败，记录在 failed-full*，源码稳定、analyze通过；两项回执通知失败经独立复现和最小修复后重新验证。失败原件保留，不把一次通过的最终运行描述为整个过程没有失败。

CodeGraph 实际查询了主树引用加载链，返回71个符号/4个文件及 implements/calls 关系，包括 controller→lookupMessage、SDK/逻辑会话/适配器的接口实现。原始 codegraph-main-reference.txt 保留其3文件待同步警告；主树索引用于依赖参考，候选无.codegraph、不擅自新增索引。最终修复以候选当前源码及运行测试核对；图结构关系不冒充运行时调用跟踪。

环境为 Windows、Python3.12.10、Flutter3.44.9/Dart3.12.2。沿用已核验 Olm/SQLCipher 原生 DLL，短盘符 V: 仅由本任务创建和按目标核对清理；完整运行输入清单绑定源文件与锁。本机短信有效期通过进程变量15满足既有规则，未改 .env 或校验。未变服务/infra/脚本/相关后端测试经 impact-reuse.json 比较 da86cf77 无差异，复用 [2026-10-23 完整维护门禁](2026-10-23-maintenance-environment.md)，本轮不重复约49分钟后端聚合门禁。

## worktree 结果及归档修复

已 fetch 最新 origin。仅盘点本仓库 C:/Users/Administrator/.codex/worktrees 下 **31 棵**注册工作树，排除其余27个 D盘/其他路径。安全可删除工作树 **0**；本轮删除工作树 **0**、删除已合入且无人检出的旧维护分支引用 **2**、强制操作 **0**。树未删除的原因是不满足前提，并非删除命令失败：

- 盘点时9棵有 tracked/untracked 改动，其中包括正在实施本轮修改的候选树。
- 23 棵有未合入 origin/main 且不在任何 remote refs 的提交；这两类重叠，不能相加当总数。
- 唯一 Git 条件通过的 interactive-cache-startup 仍承载证据/配置/数据，且关联6个未归档任务。
- 当前维护树保留本轮及前轮未推送工作；PID187384 的既有 flutter_tester 持有句柄，创建于12:54:42，归属未确认，未擅自关闭。

完整逐项路径、分支、HEAD、脏状态、remote可达性及原因见[盘点清单](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-25/group-chat-cache/worktree-inventory.md)与[机器回执](D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-25/group-chat-cache/worktree-inventory.json)。原主工作区 main@b89f0c43 的509项既有删除及其他改动保持；盘点统计是执行时快照，本候选源码与文档在交付时独立提交。

另外两条本聊天前期维护分支，经删除前重新核对 SHA、没有 worktree 检出、已为 origin/main 和本候选祖先、remote不可达提交=0，使用普通 `git branch -d` 均退出0：

| 删除的本地分支引用 | 保留的提交（仍由 main/远端/候选引用） |
| --- | --- |
| codex/maintenance-completion-20261023 | b729766fbfec6cfcaf977832f16a3ec7aad7ccd6 |
| codex/maintenance-environment-20261023 | b89f0c43786d12ef031d1b76cc55281c8e5d4283 |

branch-cleanup-before.json / branch-cleanup-result.json 保存前置判断与结果；需要恢复别名时执行 `git branch <原分支名> <表内提交>`。未删除提交、文件或其他发布/待验收分支，不改写历史；没有运行会触及其他路径的 prune。

**已修复独立备份缺失。** 历史报告记录的 D:/StarChat-maintenance-backups/2026-10-22-worktrees 在初次检查不存在；C盘原件仍在。本轮恢复28文件（9 ZIP、9逐文件manifest、9链接记录及1原ACL记录），共9,892,541,569 bytes。逐文件校验“旧2026-10-23回执SHA=复制前源SHA=目标SHA=复制后源SHA”；目录禁继承，仅当前用户和SYSTEM有访问权。备份内 backup-receipt.json 与本轮 archive-restore.json 双记录，C盘原件保留，备份不进 Git。

interactive-cache-startup 当前忽略常规文件共91,683,262,384 bytes；恢复的9份旧归档不等于当前整树已保全，其余81,790,720,815 bytes尚未在树外证明完整备份，因此不能清理承载树。下一步先由原任务验收未合并分支，并为其余证据/数据制定容量足够的受限归档，再核对SHA、任务占用与句柄，重查Git状态后使用 git worktree remove；不使用 --force 或删除目录绕过检查。

## 交付限制与下一步

- 所有改动仍是源码候选；现有0.4.65+2234 IPA不包含这些后续修复。
- 未做新的Android/iOS打包、物理设备群聊或保数据升级验收；前次iOS原生Outbox两项 MEDIA_STORAGE_UNAVAILABLE 按旧报告保留。Ruby hook 需在具备Ruby/macOS环境补验。
- 后续打包前沿用本候选新build身份，重点真机验证冷启动→连续上滑跨日期→失败气泡→返回最新，以及窗口外引用撤回/隐藏/更新、旧房间合并历史、多人消息突发时的阅读锚点。
- 没有从“分支较旧”推导可删除；不能安全清理的工作树及未推送提交已逐项保留。回退本轮代码使用普通 revert。
