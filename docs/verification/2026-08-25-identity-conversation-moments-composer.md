# 2026-08-25 身份、会话与朋友圈发表页验证

## 范围

验证规格 `docs/superpowers/specs/2026-08-25-identity-conversation-moments-composer-design.md` 对应的共享身份缓存、好友备注实时刷新、消息列表显示、群聊命名、朋友圈当前账号身份以及微信式发表/可见范围流程。

## 测试先行证据

- 身份缓存红灯：新增测试最初因 `addListener`、`applyUpdatedContact`、`refresh`、`ChatIdentityCacheError` 与 `ContactDetails.toSummary` 不存在而编译失败；实现后定向测试通过。
- 通讯录红灯：`ContactsPage` 最初不接受共享缓存；实现订阅后联系人备注无需重建 App 即更新。
- 会话展示红灯：`conversation_presentation.dart` 不存在，群导航仍显示自定义名称；实现后标题、副标题、撤回和系统事件规则测试通过。
- 朋友圈身份红灯：`MomentsPage` 不接受共享身份缓存；实现后当前用户 nickname/头像映射测试通过。
- 发表页红灯：三个新页面文件及选择模型不存在；实现后发表、可见范围、标签/朋友选择与失败保留测试通过。

## 新鲜验证结果

| Command | Result |
| --- | --- |
| `flutter analyze --no-pub`（`apps/mobile_flutter`） | PASS，`No issues found` |
| `flutter test --no-pub --reporter compact`（`apps/mobile_flutter`） | PASS，281 tests |
| `pytest tests/mobile -q` | PASS，21 tests |
| `pwsh -NoProfile -File scripts/verify.ps1` | PASS |
| Matrix Bot suite（由 `verify.ps1`） | PASS，9 tests |
| Business API + Worker（由 `verify.ps1`） | PASS，182 passed、1 skipped |
| Flutter/HTML/Figma contract（由 `verify.ps1`） | PASS，17 components、326 screens |
| Alembic offline upgrade / OpenAPI drift / Docker Compose render | PASS |

全量 Flutter 首次运行暴露一个既有 Matrix 登录令牌测试夹具缺少服务端必填 `matrix_user_id`；生产 FastAPI `MatrixLoginTokenResponse` 与 Flutter 解析均要求该字段。补齐夹具并增加返回值断言后，定向测试及 281 项全量测试通过。

仓库门禁首次运行拦截新可见范围页使用 `CupertinoButton.filled`；按移动端架构边界改为共享 `ModernActionButton` 后，21 项边界测试及完整 `verify.ps1` 通过。

## 规格符合性审查

- 当前账号封面身份仅来自 Business Profile；不使用好友备注或 Matrix 展示名。
- 好友显示按上下文执行：联系人/私聊 `remark → nickname`，用户名仅作为异常数据防御回退；发送者正常路径不把 username 当 nickname。
- 群列表包含当前登录用户在内的已加入成员并以 `、` 连接；聊天导航固定 `群聊(人数)`；群信息空显式名称显示“未命名”。
- 群副标题在未读大于零时使用 `[N条]名字：内容`，零未读省略前缀；撤回无冒号；角标仍由原独立字段渲染。
- 朋友圈发表页只保留“谁可以看 / 添加链接”；公开/私密与定向/排除之间有独立间隔；定向/排除为二级页面，不是父页单选项。
- 标签/朋友页包含双列切换、搜索、多选、计数与完成；选择仅在完成后回传，系统 Back 自然丢弃页面内未提交集合。
- 发表、草稿、身份刷新和标签/朋友加载失败均保留上一成功状态或用户输入，并提供可重试错误；日志不包含令牌、消息正文或 URL 查询参数。

## 质量与安全审查

- Business API 仍是 profile/contact/moments 的身份权威；Matrix 只用于加密通信成员及明确的展示回退。
- 本次未修改账本、红包、钱包、认证策略、Matrix 密钥或加密边界。
- 共享缓存只持久化非敏感身份元数据；错误日志仅含操作名、匿名账户指纹、异常类型与堆栈。
- 发布接口沿用既有幂等键生成逻辑；新增传递的标签 ID 与链接字段已由当前 FastAPI `CreateMoment` 契约支持。
- Figma 本会话无读写工具。已在 `docs/figma/chatflow-ui-delivery-registry.json` 与 parity ledger 记录既有 Moments 节点 `29:5798`、批准的浏览器对照稿和真实阻塞状态；未伪造远端更新或新节点。

## 发布阶段

公网健康、APK SHA-256、模拟器序列/安装/启动与 UI 截图证据在 Task 8 完成后追加。
