# 朋友圈身份与互动修复设计

**状态：** 已批准
**日期：** 2026-08-24
**范围：** Flutter 朋友圈、FastAPI Moments 身份投影与媒体接口、公网 Docker 发布、Android 模拟器验证。

## 目标

修复朋友圈好友头像、好友备注、点赞、评论和封面交互，移除“推荐/最新”切换并保留单一按时间排序的信息流。身份资料必须从业务域权威数据投影，客户端不得把默认头像、缓存值或 Matrix 资料当作用户事实。

本规格增补并收紧 `2026-08-24-wechat-moments-completion-design.md`。两者冲突时，以本规格关于朋友圈身份字段、单一信息流和封面交互的规定为准。

## 名称语义

朋友圈的显示优先级固定为：

1. 当前查看者在 `ContactProfile.remark` 中为好友设置的非空备注；
2. 好友可修改的公开展示名 `User.nickname`；
3. 好友不可变的账号标识 `User.username`。

三个字段保持各自语义：`remark` 属于当前查看者，`nickname` 属于被展示用户的公开资料，`username` 是被展示用户的稳定账号标识。服务端响应分别保留字段来源，禁止把备注写回或伪装成 `nickname`：

```json
{
  "user_id": "user-id",
  "username": "immutable-account-handle",
  "nickname": "product-username",
  "remark": "viewer-owned-remark-or-null",
  "display_name": "remark-or-nickname-or-username",
  "avatar_url": "signed-url-or-null"
}
```

`display_name` 只由服务端根据当前认证查看者计算。朋友圈作者、点赞者、评论者、回复对象和互动通知均复用同一投影函数。

## 头像链路与错误诊断

头像事实来源为 `User.avatar_object_key`。Moments 应用服务通过注入的私有对象存储生成短期受控读取 URL；没有对象键时才返回 `avatar_url: null`。客户端不得使用备注、昵称、Matrix ID 或本地默认图推导头像地址。

`UserAvatar` 继续保留稳定默认头像和最后成功图片缓存，但网络图片失败时必须输出结构化诊断日志：组件来源、用户 ID、脱敏后的 URL scheme/host/path、异常类型、异常文本和堆栈。日志不得包含 URL 查询参数、签名、Bearer Token 或响应正文。朋友圈传入 `diagnosticSource: moments-feed`，以便区分其他页面。

短期签名 URL 不得直接作为长期头像版本。缓存键以用户 ID、稳定对象版本和尺寸为依据；若接口暂时不能提供独立版本，则 URL 日志与缓存键都必须移除签名查询参数，避免签名刷新造成无意义的缓存分裂。

## 单一信息流与身份刷新

Flutter 朋友圈移除“推荐”和“最新”的可见切换，仅请求按 `created_at,id` 倒序的单一信息流。后端旧 `mode` 查询参数暂时保留兼容，但新客户端不暴露，也不依赖推荐排序。好友备注或头像更新后，刷新/重新进入朋友圈必须取得新的权威投影；客户端不得用旧联系人缓存覆盖 feed 响应。

## 点赞与评论

点赞采用可回滚的乐观更新：点击后立即切换图标高亮、`viewer_has_liked`、`like_count` 和当前查看者在点赞者列表中的投影，然后调用带幂等键的 like/unlike API。成功时用服务端权威结果或后台刷新收敛；失败时恢复点击前快照并显示明确错误。连续点击期间禁用重复请求，避免乱序覆盖。

评论图标打开可编辑评论入口。提交按钮在空文本时禁用；提交中显示状态。成功后立即插入服务端返回的评论 DTO 并清空输入，失败时保留草稿和输入焦点，显示服务端错误。评论返回的作者和回复对象同样采用 `remark → nickname → username` 的 `display_name`。

## 封面交互与持久化

点击封面进入全屏查看页，图片支持缩放和拖动；右下角显示“换封面”图标。点击图标调用系统相册选择器。选中图片后先在查看页和信息流头部显示本地预览，再走专用 `MOMENT_COVER` 上传、内容写入、完成和 `PUT /cover` 持久化流程。

上传成功后使用服务端返回的新封面 URL 替换预览并刷新权威状态。失败时保留旧持久化封面、保留待重试图片并显示具体错误。取消选择不改变当前封面。封面不能继续复用普通动态图片用途，也不能只把临时签名 URL写入偏好表。

## API 与兼容性

Moments feed/detail/personal/notification/comment DTO 增加身份字段，不删除现有 `nickname` 和 `avatar_url`，属于兼容性扩展。后端负责查看者相关的备注投影，Flutter 不额外拉取联系人列表做客户端 join。

封面使用独立 begin/complete/set 端点和媒体用途校验。所有写请求继续携带 `Idempotency-Key`、稳定原因码、审计记录和 Outbox 事件。此次变更不读取或写入 Matrix 身份资料。

## 测试与验收

后端红/绿测试至少覆盖：

- 有备注时 `remark` 与 `display_name` 使用查看者自己的联系人资料；
- 无备注时 `display_name` 回退 `nickname`，无可用昵称时继续回退 `username`；
- 不同查看者对同一作者可得到不同备注，且 `nickname`、`username`、`avatar_url` 来源不变；
- 有头像对象键时返回有效受控 URL，无对象键时返回 null；
- feed、detail、评论、点赞者和通知使用一致投影；
- 点赞、取消点赞、评论和封面写入保持幂等与权限校验。

Flutter 红/绿测试至少覆盖：

- 全部朋友圈名称使用 `display_name`；
- 自定义头像 URL进入统一头像组件，失败日志脱敏且包含具体错误；
- 页面不存在“推荐”“最新”切换；
- 点赞图标与数字即时变化，失败回滚；
- 评论入口可打开、提交、即时显示，失败保留文本；
- 封面全屏、右下“换封面”、相册取消、上传成功即时更新、失败回滚与重试。

完成定向测试、OpenAPI 检查、Flutter analyze/test、UI 合同检查和仓库验证。由于当前环境没有可调用的 Figma MCP，实施时先复用既有 Moments 节点 `19:4` 和版本化导出账本；若仍无认证写入能力，在验证记录中明确工具限制，不虚构 Figma 写入证据。

公网发布前记录本地与服务器文件哈希，重建并强制重建 `business-api`/`business-worker`，确认 ready health 为 HTTP 200。公共域名 APK只构建一次并安装到 `emulator-5554`、`emulator-5556`，回读两台设备 APK 哈希并证明一致。

## 公网三字段审计结论的交付格式

最终验证记录分别列出：数据库事实来源、API 投影规则、Flutter 展示字段、缓存键与失效规则。根因分析必须覆盖字段名复用、查看者上下文遗漏、DTO 不一致、对象存储未注入、签名 URL 缓存分裂、旧 APK/旧容器、缓存未失效、空值与格式不一致，以及错误回调吞异常。规范建议必须给出字段字典、单一投影函数、契约测试、缓存版本、脱敏日志和发布哈希校验。
