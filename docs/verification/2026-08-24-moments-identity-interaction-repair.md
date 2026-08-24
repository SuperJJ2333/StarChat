# 朋友圈身份与互动修复验证记录

日期：2026-08-24  
实现提交：`fd1edb0`、`ff7ba63`  
身份显示规则：`remark → nickname → username`

## 结论

八项问题均已实现并通过定向自动化验证。后端已部署至公网 Docker，迁移头为 `0026_moment_cover_media`；公共域名 APK 已覆盖安装到当前可用模拟器。GitHub 推送仍被仓库权限阻断，详见“已知外部阻塞”。

## 三字段严格校源

| 语义 | 数据库存储 | API 字段 | Flutter 字段 | 展示用途 |
| --- | --- | --- | --- | --- |
| 登录/唯一账号标识 | `users.username` | `username` | `MomentAuthor.username` | 仅在无备注、无昵称时兜底 |
| 用户自己设置的昵称 | `users.nickname` | `nickname` | `MomentAuthor.nickname` | 无查看者备注时显示 |
| 当前查看者为好友设置的备注 | `contact_profiles.remark`，以 `owner_id + contact_id` 定位 | `remark` | `MomentAuthor.remark` | 最高优先级，且不得反写 nickname |
| 自定义头像源 | `users.avatar_object_key` | `avatar_url`（读取时签发） | `MomentAuthor.avatarUrl` | 与姓名字段完全独立 |
| 最终显示名 | 不持久化 | `display_name` | `MomentAuthor.displayName` | `remark or nickname or username` |

公网只读检查结果：8 个用户中 8 个具有 nickname，3 个具有自定义头像对象键；3 条联系人配置中 2 条具有 remark。实际数据库列确认包含 `users.username/nickname/avatar_object_key`、`contact_profiles.owner_id/contact_id/remark`。未输出真实账号资料、签名 URL 或令牌。

## 根因与规范化建议

本次头像问题的直接原因是旧 Moments 投影把 `avatar_url` 固定为 `None`，且 router 未注入头像存储服务；Flutter 的图片失败回调又只显示默认头像，没有可定位的日志。现在由 `avatar_object_key` 在读取时签发短期 URL，缓存键忽略临时签名查询参数，失败日志只记录来源、用户 ID、脱敏 scheme/host/path、异常类型和堆栈。

备注问题的直接原因是旧 Moments DTO 只返回一个被折叠的 nickname，前端却尝试读取不存在的 remark；部分中间实现还曾把 remark 赋给 nickname。现在三个源字段原样返回，服务端按当前查看者查询备注并额外计算 display_name，前端只消费 display_name 展示。

类似混淆反复出现的常见原因：

- DTO 使用 nickname 作为“万能显示名”，导致源字段语义丢失。
- 忽略 remark 是查看者相关数据，同一好友对不同查看者结果不同。
- 列表、详情、点赞者、评论者、通知各自拼装 DTO，映射规则发生漂移。
- 头像对象键、持久 URL、短期签名 URL 混用，或把签名 URL 当稳定缓存键。
- JSON 空值、空字符串和字段缺失处理不一致。
- 客户端/反向代理/图片缓存仍保存旧 DTO 或失败结果，部署后未重启容器、未覆盖安装 APK。
- 数据迁移、OpenAPI 和生成客户端不同步，旧代码继续按历史字段解释新响应。

后续规范：保留 username/nickname/remark/avatar_object_key 为唯一权威源；统一使用一个 viewer-aware identity projector；display_name 只作派生输出；头像只持久化对象键；所有 DTO 做契约测试；对签名 URL 缓存按稳定对象路径或明确版本号分桶；发布时同时验证迁移头、OpenAPI、容器重建、APK 哈希和缓存失效。

## 功能证据

- 单信息流：客户端仅请求 latest，页面无“推荐/最新”切换；模拟器 UI 也未出现该选项。
- 点赞：Flutter 使用可回滚乐观更新并禁止重复请求。模拟器真实会话中点击后，心形由实心立即变空心、数字 2→1，再次点击恢复。
- 评论：点击评论图标弹出输入框；空文本禁用，输入后发送按钮可用；成功结果立即加入本地列表，失败保留草稿和错误。
- 封面：点击 header 进入 InteractiveViewer，右下角显示“换封面”，点击后拉起 `com.android.documentsui` 相册。选图后先显示本地内存预览，再执行 begin→PUT→complete→setCover；成功持久化稳定对象键，失败保留预览和错误。
- 头像：模拟器朋友圈中自定义头像实际显示；本次运行 `AvatarLoadError=0`。失败时使用 `[AvatarLoadError]` 结构化日志，查询参数和签名被剥离。

## 测试先行证据

- 身份投影红测：初始缺少 username/remark/display_name，nickname 被备注覆盖；修复后 Moments API `7 passed`。
- 头像红测：初始模型字段与 sanitizedUrl 缺失；随后发现 `Uri.replace(query: null)` 未移除查询并修正；定向 Flutter 测试通过。
- 点赞/评论红测：初始缺稳定按钮 key、即时计数和评论入口；实现后成功、回滚、草稿保留场景通过。
- 封面后端红测：专用 cover routes 初始 404；实现后媒体与迁移测试 `8 passed`。
- 封面即时预览红测：旧回调不接受预览数据，测试编译失败；实现后定向 Flutter 交互测试 `25 passed`，`flutter analyze` 无问题。
- UI 合同红测：注册表初始 14 项且缺朋友圈新状态；修复后 `17 components, 326 screens`。
- 全量门禁：`scripts/verify.ps1` 曾因两条陈旧精确断言失败；将 Matrix 登录新增字段纳入契约、将 OpenAPI 核心路径检查改为子集并单独断言四条封面路径后，通过 `182 passed, 1 skipped`、Flutter boundary `21 passed`、迁移/OpenAPI/Compose PASS。

## 规格、质量与安全复核

- 规格合规：八项需求均有代码和测试对应；身份优先级严格为 remark→nickname→username。
- 数据边界：身份来自 Business API/PostgreSQL，未从 Matrix 消息或客户端显示状态派生。
- 写操作：点赞、评论、封面上传完成和封面设置均带幂等键；封面设置具有审计和 Outbox。
- 持久化：只保存 `cover_object_key`，不保存临时签名 URL；迁移为 expand-only。
- 日志：不记录消息正文、密码、Bearer Token、头像签名查询参数或响应正文。
- 运行日志：模拟器无 fatal/unhandled exception；公网 API/Worker 部署后无 ERROR/Traceback/Exception。

## UI/Figma 说明

本次使用版本化 UI 账本和组件注册表记录 Moments feed、互动和个人封面状态，并通过 drift check。当前环境没有可调用的已认证 Figma MCP，因此没有修改远端 Figma，也不作已修改声明。现有页面证据节点：<https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/%E7%95%85%E8%81%8A-%C2%B7-HTML-%E2%86%92-Figma-%E8%AE%BE%E8%AE%A1%E7%B3%BB%E7%BB%9F?node-id=19-4>。

## 已知外部阻塞

`git push origin main` 返回 GitHub 403：本机认证账号 `a1014826460-stack` 没有 `SuperJJ2333/StarChat` 写权限。因此代码已在本地 main 形成提交但尚未同步到 origin；需要仓库所有者授予权限或切换到有权限的凭据后重试 push。

