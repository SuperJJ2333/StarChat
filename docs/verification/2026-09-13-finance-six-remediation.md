# 账单、群成员选择器与拍一拍修复验收

2026-09-13。基线 `c5cd589c`，工作分支 `codex/finance-six-remediation-20260913`。Astra 负责实际 diff、调用链和验证复核；执行代理创建时明确指定 `gpt-5.6-terra`。主工作区已有修改未覆盖。本报告是源码与自动化验收，不代表生产或 Mi 6 已更新。

## 问题、根因与实现

| ID | 根因 | 修改与验收 |
| --- | --- | --- |
| F1 | 金额只在自身内容宽度内右对齐，未固定整行尾部边界 | ledger_pages.dart 使用固定尾列与缩放适配；金额保持精确字符串，长短标题、大字体对齐测试通过 |
| F2 | 部分入口未透传身份仓库，异步资料更新未刷新，名称插值错误；非好友缺昵称投影 | app_home、finance_message_entry、转账详情贯通身份仓库；列表和详情监听更新，备注→昵称→账号；API 批量追加公开昵称与账号，不输出私有备注 |
| F3 | 详情停留在 demo，Flutter 未完整对应 | 实装分类图标、金额、状态、对方身份、时间、说明、本金/手续费、红包类型、复制账单 ID、全部账单入口；身份/金额仍来自权威 API |
| F4/F5 | 两套选择器，非好友 MXC 被交给 HTTP 头像；Matrix ID 误作业务用户 ID | 共用 GroupMemberPicker/GroupMemberAvatar；业务头像优先、MXC 使用 MatrixUserAvatar；仅本群成员，提交前解析并核对业务 ID，失败不提交，支持重试 |
| F6 | 红包人数输入与群成员边界需要持续保留 | 默认空输入；保留群人数上限、密码与幂等提交逻辑，红包定向回归通过 |
| N1/N2 | 限频状态与页面生命周期绑定，目标维度及失败释放不可靠 | 进程内共享滚动窗口，按发送用户+房间预留令牌，任意目标共用三次配额；失败仅释放自身令牌；第四次显示非阻塞 toast，重进页面不重置 |

服务端只增加授权账单的公开身份读取投影；不修改账本余额、财务状态机、分配规则、支付权限或 E2EE 协议。公开身份读取不生成签名头像 URL，避免账单读取依赖媒体存储配置。

## 验证结果

证据目录：`artifacts/2026-09-13/finance-six-remediation/`。日志保留失败与重跑，不以定向成功代替全仓通过。

| 命令/门禁 | 实际结果 | 日志 |
| --- | --- | --- |
| Flutter 账单、转账详情、两选择器、红包、限频、聊天页集成及身份依赖测试 | 54 passed，exit 0 | flutter-focused-final.log |
| flutter analyze --no-pub | No issues found，exit 0 | flutter-analyze-final.log |
| pytest tests/mobile -q | 70 passed，exit 0；修正新增 UI registry 的过期计数断言 | mobile-final.log |
| pytest 账单 API + OpenAPI 合约 | 11 passed，exit 0 | backend-final-focused.log |
| UI contract | 30 components / 368 screens，PASS | ui/ui-contract-green.txt |
| 完整 Flutter suite | 2482 passed / 30 failed，exit 1 | flutter-full-final.log |
| 缓存专项复核 | 原长路径 10 passed / 1 failed；同源码短路径 11 passed | moment-cache-rerun.log、moment-cache-short-path.log |
| 前端完整测试 | 160 passed / 11 failed | ui/frontend-full-baseline.txt |
| c5cd589c 前端 unit 基线重放 | 158 passed / 同名 11 failed | frontend-c5-unit-baseline.log |
| scripts/verify.ps1 | infra 141、getui 28、matrix bot 9 passed；业务 1853 passed / 52 skipped / OpenAPI 1 failed | verify-baseline.log |
| 其他后续门禁 | API import/AST 214、Alembic 单 head/离线渲染、Compose 配置通过 | import-ast.log、alembic-heads.log、alembic-offline.log、compose.log |

全量 Flutter 中 29 项失败位于未修改的 wallet 模块（已核对该模块和测试相对 HEAD 无差异），仍属于未清零的回归风险；没有把钱包相关用户未提交修复混入本任务。第 30 项是 Windows 深工作树路径导致目录枚举失败：临时 Q: 映射同一工作树后未改源码通过全部 11 项。前端同名 11 项失败在 c5 基线复现。verify 执行时 OpenAPI 尚未收口，后续权威导出及合约测试已通过，但没有宣称整条 verify 在最终候选上全绿。

## 主代理审查与证据边界

实际审查发现并交回修正：未透传身份、未消费服务端名称字段、Stateless 页面错误引用 widget、详情主视觉不一致、HTML 选择器头像缺失、UI 注册表测试旧计数。主代理自行重跑最终 54 项 Flutter、70 项 mobile、11 项 API/合约并检查差异。

HEAD 已引用但遗漏的 support identity 依赖从主工作区按已审查范围补齐，源文件哈希见 `nudge-integration/verification.md`。未覆盖主目录文件，也没有隐式合并其余钱包/后台任务。

HTML 通过本地 catalog 浏览检查全部账单尾列、账单详情及统一选择器；这不是 Flutter 真机像素或手势验收。RoomPage 集成使用真实发送入口和受控 Matrix Room 测试替身，验证三次进入发送通道、第四次换目标仍被拦截及页面重建；不声称进行了真实加密网络端到端发送。

## 用户真机验收用例与未覆盖项

1. 全部账单混合长短姓名、正负金额和大字体：金额右边界一致；修改好友备注后，列表与详情同步更新；非好友显示公开昵称或账号。
2. 点击转账/红包流水：字段、时间、金额与服务端一致；复制账单 ID 正确，全部账单导航可返回。
3. 群转账/专属红包：同一群成员样式一致，好友 HTTP 与非好友 MXC 头像正常；空群/解析失败不提交，重试可恢复，不能选群外好友。
4. A 在一个房间拍 B 三次，再拍 C：只有前三次提醒，第四次 toast；重进房间仍受限；最早一条满 60 秒后恢复一个名额；其他房间不受影响。

尚未进行 Mi 6 视觉、键盘弹出避让、弱网头像真机体验或真实资金操作。限频是本进程滚动窗口，杀进程和多设备不共享配额；不等价于服务端防绕过限制。本轮未构建/安装 APK、未 push、未部署或迁移生产数据库。下一步为与主工作区其余任务集成审查及正式打包/发布流程，不能把当前设备旧包当作本次成果。
