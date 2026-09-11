# 2026-09-12 选择手柄/放大镜/emoji输入修复

## 恢复入口
- 用户明确反馈前轮r3仍有松手镜片残留、部分菜单缺失、手柄触摸困难和多动态emoji前缀输入错位，要求修复后Debug安装Mi6，用户自测。
- 计划：../../superpowers/plans/2026-09-12-selection-emoji-repair.md；用户所列交互为既定设计，继续执行无需逐步询问。
- 基线13d52ce5；工作树D:/pythonProject/outsource/StarChat/.worktrees/select12，branch codex/chat-selection-20260912；main存在用户文档/依赖/Gradle镜像策略改动，均保留。
- Astra根审查；实际创建gpt-5.6-terra执行者terra_emoji_repair与terra_selection_repair，工具显式接受model参数。前者独占输入控制器/Composer，后者独占选择会话/RoomPage，Flutter测试单槽先E1再S。
- 当前状态：定位与红测试；下一步确认输入与渲染坐标差异、选择Overlay事件链，测试证明后根因修复。
- 01:50+08开始建立任务；01:52读Mi6，serial cbd0156b，com.liuhetong.mobile 0.3.84-debug/2088，firstInstallTime2026-09-11 00:42:05，lastUpdateTime2026-09-12 01:37:59。

## 验收台账
| ID | 场景 | 必须通过 |
| --- | --- | --- |
| S1 | 初始长按 | 原完整菜单+文字选区，菜单可点，不重复Overlay |
| S2 | 拖动及松手/取消 | 小视觉大热区，镜片跟随指尖采样，up/cancel后一帧消失；部分菜单恢复且不遮选区 |
| S3 | 部分范围 | 复制/全选/引用/转发；后三种文本操作只取选区，复制emoji转名称；全选恢复原菜单；跨行/emoji/代码不截断 |
| S4 | 取消 | 空白、滚动、发送、切换会话/dispose后无菜单/镜片残留 |
| E1 | 多emoji前缀后输入 | 中文/英文/组合字素/换行/插入删除/光标选择均保持原UTF16坐标与IME composing，不凭空改正文 |
| U1 | HTML和注册表 | 对应状态/组件/token同步，自动契约通过，Figma退役 |
| D1 | DebugMi6 | 新版build、固定签名、正确主包名、重建语义/哈希校验、install-r数据保留；功能手感由用户验收 |

## 门禁边界
scripts/verify.ps1已读；隔离工作树无.env，完整脚本中的配置渲染依赖环境，不能复制生产秘密。按移动工作流在实际入口记录失败，复用未修改金融/API门禁；新Flutter相关测试必须修复，全量29钱包既有失败公开记录。无生产或Git推送授权扩大。
## 根审查发现的实际调用链（02:08+08）
- E1真实EditableText span基线把🥲🥲压为两个U+FFFC；当前控制器保留source UTF16，overlay依据RenderEditable选区盒绘制，已读实际diff和18项focused green日志。增加滚动/卸载/clear覆盖后再最终冻结。
- S单overlay方案通过方向审查，但首轮实现full菜单高度/箭头/镜片边界/短消息热区重叠尚不完整；交回Terra逐项修复。真实测试必须用生产EmojiText，不能Text替代WidgetSpan布局，不能仅查菜单存在。
- S3发现原有partial forward仅替换picker preview，真正发送仍interaction.forward(eventId,target)，实际转发完整原文；partial reply仅持有preview对象，发送只有eventId，接收显示再查原消息也会回到完整原文。为满足用户指定操作对象，授权最小公共Matrix客户端扩展，保留全选原路径、密钥及加密边界。
- S独占selection/RoomPage及必要Matrix interaction/lease/timeline适配；E接管HTML demo/registry及自身emoji补测，避免同文件并改。Flutter执行仍单槽。
- 当前未打包、未安装新版，Mi6仍2088。后续最终验证需包含真实selected payload/quote roundtrip及原路径回归。

## 加密封装审查（02:13+08）
根读取vendored Matrix encryption.dart实际代码发现m.relates_to在encryptGroupMessage移出payload并附在明文encrypted envelope（357/399）。因此拒绝首版将selected_quote放relation的实现；要求片段为content根级项目字段，与body一起进入密文，relation仅保留eventid。未构建/发送/安装包含该中间实现的APK。测试需断言传输envelope不出现选区，解密内容保留精确选区；禁止修改SDK加密算法。

## 收尾分工（02:17+08）
前两名Terra执行者已停止编辑。Astra实际审查退回了仅静态占位的HTML与不足的选区测试，创建两个显式gpt-5.6-terra收尾执行者：terra_demo_finish独占frontend/registry，terra_selection_finish独占selection/Matrix及相关测试。执行者同时最多两个；emoji控制器/装饰层已冻结。E1整组12测试含真实ViewportOffset滚动/clear/换controller通过；仍不据此宣称全部验收通过。
本机HTML演示server由root启动，PID17932，127.0.0.1:4187（只本地），正确路由?screen=chat-selection-active；审查后停止本任务server。

## 基线更新与原有失败证据
工作中main前进至1da11922：只含Android环境仓库顺序及两份审计记录。root审查diff后本地ff当前任务branch，保留全部进行中修复，未pull/push或改变root脏文件。最终构建基线为1da11922。
已读既有完整Flutter原始日志docs/verification/artifacts/2026-09-11/integrate-deploy-mi6/flutter-full-0.3.84-2088-final.log（2344pass/29fail、exit1），提取29失败身份至本任务baseline-wallet-failures.txt供最终比较；不能把历史数目当本次执行结果。main新core-feature-test报告F1断网同步问题属于另任务，当前不修改同步调度；双方多端真机与网络恢复效果仍需用户实际确认。
