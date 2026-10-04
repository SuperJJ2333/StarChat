# 搜索旧日期与上下文跟进

## 当前状态（恢复优先读本节）

2026-10-05T01:26:20.6483328+08:00：0.4.32+2201/e665已01:02保留数据安装模拟器，实际成品SHA0c74/UID10090/首次安装保持。最终全量5437PASS/9skip/0FAIL、analyze0、有序规格/质量及Android成品审查接受；iOS37217656064同源三job SUCCESS，含18/26保留密钥与历史新进程验证。启动同PID1669观察1263.7秒/匹配Java crash0。技术门禁闭合；真实账号D1/C1反馈待用户，无正式移动发布/IPA。最终平台证据复核接受（954faaf3…）；主分支4ca4e8fb已快进/推送；1372无关WIP逐文件SHA保持，原current-state正文完整保留。

下文为阶段历史，当时‘调查/未安装/CI运行’不表示当前状态。

## 恢复入口

- 目标/授权：用户在2200确认旧媒体缩略图与点击正常，继续要求修复十天前日期定位失败及关键词跳转只显示单条且不能上下滚动。沿原会话自主诊断/修复/debug交付授权，不增加正式移动发布。
- 计划：[补充计划](../../superpowers/plans/2026-10-04-search-date-context-followup.md)；前序[媒体任务](2026-10-04-search-media-grid-followup.md)。既有密钥恢复ADR保持，不能重置密钥/存储或减弱来源、撤回、隐藏与账号边界。
- 状态：调查；基线574ef30b4b55cc6cb0c2abfa68d1cc3361cd7865；移动源码与29236bd3同树；模拟器0.4.31+2200。
- 负责人/所有权：root拥有计划、任务、验收报告、版本与构建/平台；ios_recovery_identity_fix只读调查SDK/RoomPage/逻辑时间线，暂不编辑源码。工作树C:/Users/Administrator/.codex/worktrees/search-camera-history-20261003/StarChat；不碰primary1372既有WIP。
- 下一步：确认日期失败与单条context的实际调用链，补真实页面及持久SDK RED，然后按最小行为差异实现并有序规格/质量安全双审。

## 初始验收台账（历史，最终状态见下表）

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 设备反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| D1 | 设备本地索引十天前已知有消息日期，定位合法气泡 | 调查 | 待实际流程RED/GREEN | 2200未修复 | 用户报未找到 |
| C1 | 关键词旧命中展示前后上下文，可上下分页 | 调查 | 已读到local-hit单事件fragment无token；测试待补 | 2200未修复 | 用户报单条不可滚动 |
| B1 | 隐藏/撤回/闪照/来源/账号/取消与迟到结果保持隔离 | 待实现影响判断 | 复用不变输入并补变化范围负例 | 未交付 | 不扩本地日期索引权威或无界历史扫描 |
| I1 | iOS密钥连续性保持 | 前序2200通过 | run37209352829生产编译及iOS18/26 seed/new-process retained均SUCCESS；新源码需按影响补验 | 无正式IPA | 未替代iPhone真实覆盖升级 |

## 版本与证据

2200安装成品SHA035f3fb13333a221d940316df5005eb11767f14582f334e6612dc8e20f00cf84，保留UID/首次安装数据。前序媒体工作完成用户反馈，不把该包当新日期/context修复。新候选编号冻结前核号。

## 阶段计时

恢复调查记录时间：2026-10-04T23:31:42.1933295+08:00。首次用户问题到本轮记录间未采精确时长，不估算总耗时。

## 交接与回退

当前无本地Flutter/构建运行；前序iOS CI已完成。SDK local event命中直接构造仅一条且无上下分页token的fragment已确认；日期根因尚待完整索引/来源/显示链。不要把onDateLookup仅本地视为缺陷并改为远程日期扫描。先读调查artifact，再执行测试/实现。前序2200仍为已安装版本。
23:41:48+08 root读回两份有效RoomPage RED：page-date-red-clean.log（SHA5b75680767b9f68b95e758d16a8b5c38eb2c51373bd41f41eec7c3490adc0cf1）目标index为null，搜索route清理取消新定位；page-keyword-red-clean.log（SHA0aabe40215dbe36256cf756594722947e081d61e0f287493ec3c5c03431fcad2）预期older/anchor/newer，实际仅anchor且已渲染。两个当前日正向对照通过。日期基线取消发生在受控本地读取进入前；GREEN还需断言route关闭后进入该读取并释放后定位成功，不能写成已证明“读取中”取消。早期预取/test-zone/路由等待失败只为夹具诊断。

actor开始最小handoff/context实现，仍独占Flutter。拟保留合法持久anchor离线回退，在线有界SDK context与真实前后token；取消、权限/来源/账号/隐藏/撤回不能借fallback绕过。GREEN/双审/新包尚待，2200安装仍未变。整库verify预检缺.env/local.env，未执行；PS7.6.5/Python3.11.11证据verify-preflight.json。primary1372内容未变、远端main仍ad728e6e；23:37只读生产Android2196/iOS2194、模拟器2200，暂定2201仍未冻结。

实现中新增真实分页RED：日期handoff已通过受控读取，关键词通过SDK上下文读取到初始前后邻居，但controller.openAnchor沿用旧live historyExhausted=true导致loadHistory提前返回，真实prev token未请求（page-green-2.log有效失败）。新增controller文件所有权/最小状态刷新在原C1计划内批准；向后加载已正常，双向完整GREEN与受影响controller门禁待完成。首次page-green fake-zone等待属于夹具诊断，不计产品GREEN。


actor澄清gesture-sdk-green.log名称不等于真实手势覆盖：32PASS当时仍为controller显式分页；仅可作为SDK/页面控制器证据。真正drag测试page-real-gesture.log已触发prev token请求，但older页气泡未进入可见窗口，仍FAIL，不得宣布完整C1通过。SDK31PASS包含offline/503 fallback，401/403/404/程序错误不fallback，异源/未解密context拒绝，late hide/recall、取消、3秒超时释放迟到subscription并重试enrich。新增持久late recall实际RED后实现采纳前重读当前local anchor，GREEN；实际滚动缺口继续调查，source/Flutter所有权未释放，尚未开始新包。


跨日继续：实际gesture剩余缺口定位到RoomPage earlier分支未先记录滚动方向，listener排队earlierwindow后ScrollUpdateNotification设置方向又清除队列，随后prefetch被仍运行listener请求去重；loaded older行/hasEarlierWindow=true/offset已到edge却不显示。later分支已有先设方向逻辑。最小对称补齐earlier方向记录在C1授权内；临时synthetic diagnostic将删除，清晰RED与反向/取消回归保留，不以数据已读取冒充气泡已显示。


受影响15suite门禁发现真实ballistic/newerqueued shift回归，源码freeze撤回；原六hash inputs/source-review.diff仅为撤回候选，不允许作为最终审查接受。独立reviewer未给接受结论并停止审查，等待修复后新冻结包。三adapter fake缺新消耗canRequestHistory getter另行补齐。actor保留真实held-forward/reverse-drag断言修复方向/队列规则；本轮未启动rootFlutter/新version/build/CI。

## 当前验证状态（2026-10-05 00:16 +08）

实现commit72c1188e，root配对版本/workflow76df11ea：0.4.32+2201。最终七文件handoff SHA025bb84e858bc771b5c0d2325dcdb6e9832ca8dde9ded5827fe7a815de56c720、inputs SHA4b95506305699b7e2d4a9c0e8f450c261e458f5f0eb08042d3ce7bffe2bb5aa0。最终53覆盖PASS/analyze0；先前172PASS/5FAIL保留，五项逐项在新覆盖中关闭，实际date/keyword/drag展示GREEN。最终滚动修复仅保留匹配方向queued shift，opposite/drag-start取消保持；此前earlier-listener方向赋值方案已移除，不能当最终行为。

source/Flutter所有权已释放，root全量session71474运行，独立规格审查进行中、质量审查未启动。1871移动输入manifest e7b113e380307e4b6953b782aafbb767169a0926091ad5717c8a44c6c3dee6b4绑定76df，标准Androiddriver preflight通过；未构建/安装2201，模拟器仍2200。最后只读版本核对00:11+08生产Android2196/iOS2194、无其他新CI候选。

root初次pubget继承镜像host造成临时lock解析变化，在任何测试/构建前发现；只还原root造成的lock改动，设PUB_HOSTED_URL=https://pub.dev并pubget --enforce-lockfile成功，exact lock ac0966cb…恢复、无Gitdiff，生成配置重新解析固定依赖。保留pub-get-final.log为诊断；pub-get-enforced-final.log才是最终输入依据，不引入依赖升级。freeze初次driver副本旧版本断言失败仅为preparation诊断，helper已配对2201，create/verify均成功。

下一步：完成全量及有序规格/质量审查，通过后Android标准重建/验包/保留数据安装与同源iOS18/26验证；无正式发布/IPA。

2026-10-05T00:32:25.3243085+08:00：fixture-only e6659cf6移除已关闭资源后的即刻recursive delete，保留三注释及所有断言/关闭；focused旧媒体10场景PASS1:44/analyze0。core handoff原SHA025bb84恢复精确prefix，inputs4b955不变；独立fixture supplement d76a116…及070ce5d…另存，原接受证据不覆盖改写。原72+76规格/domain ACCEPT/source-spec-review4d6933…；补充夹具规格后质量审查进行中。root第二全量session6728运行，1871输入candidate-b d2206802c3cca303ac3026d8f8406c0f4e2e9383c1f70aa21422d5fcfd99f8b8绑定e6659cf6；candidate-a/e7b保留历史，不再用于构建。模拟器仍2200。


2026-10-05T00:51:05.8592443+08:00 最终本地门禁：e6659cf6第三全量00:39:38.589–00:48:09.802+08，5437PASS/9skip/0FAIL/exit0；concurrency2，不改原1秒deadline/100ms异步检查/20x100ms图片断言。此前两次完整失败及三文件38PASS保留，不能把历史失败改写为通过，也不声称并发是唯一原因；production lib tree76/e665完全一致c2d3381e…。actorfinalanalyze0复用固定输入（root仅版本字面量变化通过3contract）；原lockac096保持。原规格4d6933、夹具补充规格800c1447、整批静态质量a719d00e有序接受，无新增P0–P2。

1871候选b/d220输入绑定e665远端读回一致，Androiddriver执行中session79905；源码→标准重建/对齐/固定签名/独立验包/安装尚待。iOS run37217656064绑定同源e665正在验证，00:49两模拟器hostpaths运行/fullproductioncompile运行，无失败；尚未通过seed/newprocess连续性。source/shared验证全部放行后按原授权继续交付，尚无正式移动发布。

## 最终技术验收台账

| ID | 技术证据 | 当前交付与缺口 |
| --- | --- | --- |
| D1 | 实际页面受控持久读取定位GREEN | 2201已安装；真实账号十天前日期反馈待用户 |
| C1 | SDK上下文/真实双向drag与气泡展示GREEN | 2201已安装；真实账号上下文/滑动反馈待用户 |
| B1 | 来源/隐藏/撤回/账号/取消/迟到负例通过，最终全量5437PASS/9skip | 独立质量安全接受 |
| I1 | 同源37217656064三job SUCCESS，iOS18/26 seed与新进程保留历史通过 | 无正式IPA；不替代物理iPhone覆盖升级 |

最终平台/安装审查SHA256：954faaf398953c2d1ede39b705d42ebe49a9eec88d8e993c37c29d7ba0242942。主分支集成下一步：验证1372无关WIP与路径不重叠，只暂存current-state，快进main后恢复其原始用户正文，再读回远端与归档清单。

2026-10-05T01:40:53.613555+08:00 主分支快进4ca4e8fb，远端读回一致。移动Git树accfd229a1d8db257cc31177bb6f5c8b6b0da27f与实际门禁/构建e665完全一致，收尾文档提交无需重跑不变门禁。1372无关WIP逐文件SHA保持，候选路径交集空、index空；只暂存current-state并完整恢复原用户正文，独占stash精确OID已删除。公开证据/成品显式allowlist复制至primary并逐文件SHA核对；main-integration.json/public-evidence-archive.json记录身份。下一执行步：等待用户D1/C1反馈；异常则读取对应设备2201复现，未收到反馈不得宣称真实账号通过。
