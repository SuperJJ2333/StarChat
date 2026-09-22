# 聊天可靠性、历史性能与自动诊断实施计划

> For agentic workers: 使用 subagent-driven-development；先规格复审，再质量安全复审。用户已在调查报告后明确授权修复以上问题及无负担自动服务器日志；不重复索取相同授权。

**Goal:** 修复已证实发送错误分类、历史锚定/来源查找、搜索与日期缺陷，提供有界、无聊天内容的自动异常上报。
**Architecture:** 保留Matrix/E2EE和现有业务鉴权；索引来源查找不全量重算，分页保持屏幕锚点；搜索按有界可取消批次增量扫描并支持继续，不靠无限填满50匹配。诊断独立于业务关键路径，闭合枚举+计数/耗时+随机操作ID，不允许任意字符串或正文；认证接口校验、限流后写结构化服务日志。
**Tech Stack:** Flutter/Dart及vendor Matrix、FastAPI/Pydantic、现有RateLimiter/日志设施。

## 基线与边界
- 独立工作树`.worktrees/chat-reliability-diagnostics`，分支codex/chat-reliability-diagnostics-20260921，基线3d968997（已含并行任务2152生命周期修复）。不复制主树钱包/身份未提交改动。
- 不改E2EE协议/密钥恢复/财务/身份权限模型，不记录正文、搜索词、房间/消息标识、token、异常任意文本、堆栈内数据。未知错误仅记封闭unknown类型。
- 先使代码、测试和服务器接收链可验证；生产上线仅部署本任务增量并保留运行态其他修复，遵守runbook。新版安装及双端真实故障最终验收独立标记；不声称单测解决已缺失现场日志的全部发送事故。

## T1 逻辑时间线与滚动（代理A）
Files: logical_conversation_timeline.dart、timeline_scroll_anchor.dart、room_timeline_viewport.dart、matrix_room_timeline_adapter.dart及对应测试；不编辑room_page。
- [x] 先以N条sourceRoomId不触发N次全量snapshot、冷查/新增source/撤回一致性写失败测试。
- [x] 最小索引查找/增量合并实现，保持多来源和事件身份正确。
- [x] 逐帧锚点与手势打断红测；改为无可见多帧寻址的稳定窗口转换，提供root所需room_page接线接口；不得通过禁用快滑或遮盖消息掩盖。
- [x] 相关200行窗口、变高消息、定位、来源测试通过，量化计数。

## T2 发送与日期（代理B）
Files: vendor matrix src/room.dart、matrix_e2ee_client.dart、room_timeline_controller.dart及专项测试；不编辑logical/room_page。
- [x] MatrixException服务端拒绝保留原错误；真实网络异常仍可同txid自动重试；队列释放/重试/超时正确，先红后绿。
- [x] 月探测超时保持unknown/error，只有明确无事件才空；旧结果不能覆盖新代次；整体查询预算/取消与索引读写有限。
- [x] 埋点与root定义诊断接口对接；不改变成员/加密验证，不依赖peer presence。

## T3 诊断通道（代理C）
Files: 新core/chat_diagnostics.dart及测试、business_api_client.dart新增方法及测试、server api/client_diagnostics.py与main注册、server测试、OpenAPI。root拥有main.dart/app_home.dart接线。
- [x] 红测：白名单/长度/类型/上限；无任意异常正文；未认证401；未知字段拒绝；限流；上传失败不递归诊断。
- [x] 本地上限100事件，批次最多20，异常同类型聚合、每分钟最多20项、最多每60秒一次，失败指数退避最高15分钟；单次5秒上限，单一在途；退出账号清理/代次隔离。正常成功默认不采集，只慢操作/异常；客户端会话随机UUID不含身份。
- [x] 仅使用独立低优先HTTP请求，不经过业务刷新/登出副作用链；服务器认证并限流，不写业务数据库。结构化日志有既有轮转上限；版本/platform/阶段/errorCode/elapsed/count/requestId等严格契约。
- [x] 测试红绿、OpenAPI同步；给root明确公共方法/枚举和启动/停止约定。

## T4 搜索/页面接线（root）
Files: room_page.dart、chat_search_page.dart、chat_search_query_controller.dart、新bounded_history_search.dart、main.dart/app_home.dart与相应测试。
- [x] 关键词无匹配不得无界读取/重复全量处理；每批最多3页/2秒（网络单步有限），处理增量，明确继续加载、不误报全历史无结果；旧搜索取消/新查询generation防串。
- [x] 打开日历取消后台搜索/防抖；日期失败可重试，不锁死导航。
- [x] 接入A滚动接口，源查找只做已有索引，刷新不阻塞交互；用阶段耗时/计数上报慢搜索/历史加载/锚点异常。
- [x] 应用自动启动/停止有界诊断；关联发送前校验、Matrix发送、分页、搜索、日期和框架异常，阶段只用白名单，保留原错误处理。

## T5 集成、验收和交付
- [x] 独立工作树依赖/SDK/磁盘预检；无.env先构建隔离测试配置，禁止复制生产秘密。
- [ ] 单项red→green证据，Flutter analyze/全量、后端专项、verify.ps1及必要native门禁；仅变更相关输入后复测。
- [x] 先规格再质量安全审查；日志真实客户端→接收端合同联测和隐私/负载验证。
- [ ] 按runbook只读生产基线，选择安全增量上线诊断接收端并验证；移动包构建/安装需按已授权渠道和当前版本占用核定，不冒用原2145已上传包。
- [x] 文档/任务/证据/下一执行步骤同步；未完成真机或Apple等待明确记录。


### T5实际结束状态
源码与两文件接收端已交付，Flutter3740/0、analyze0、verify exit0。接收器生产读回完成。没有本次新移动包/真机证据，涉及打包/安装的条目不标记为完成；后续须整合已有iOS重启/权限分支，不能退回未含修复的主线包。见任务台账。
