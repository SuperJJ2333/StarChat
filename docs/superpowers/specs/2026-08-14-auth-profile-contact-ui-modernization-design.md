# 六合通注册、个人资料、好友交互与 UI 现代化设计规格

**状态：** 已确认
**日期：** 2026-08-14
**适用范围：** Flutter Android/iOS、Business API、Business Worker、Synapse 集成、Mailpit/SMTP

## 1. 目标

本次改造交付以下完整能力：

1. 使用强制邀请码完成用户名、邮箱、密码注册；没有有效邀请码不能注册。
2. 提供 6 位邮箱验证码与验证链接双通道，并在邮箱验证后幂等创建 Matrix 账号。
3. 使用一次性 Matrix Login Token 代替向 Matrix 传递业务密码。
4. 以 Business API 为个人资料权威来源，支持昵称、六合通号、签名、脱敏邮箱和可编辑头像。
5. 修复通讯录泄露内部 UUID、好友页不能发起聊天、好友设置层级错误等问题。
6. 使用指定 SVG 生成双端 APP 图标，认证页面使用指定 `landing.png` 沉浸背景。
7. 全局采用现代白底图文按钮，并补齐“我”页面、退出登录和紧凑离线状态。

## 2. 已确认产品决策

- APP 图标唯一源文件：`apps/mobile_flutter/assets/branding/liuhetong_logo.svg`。
- 登录、注册、邮箱验证页背景：`apps/mobile_flutter/assets/landing.png`。
- 认证页面视觉方向：B，沉浸式背景。
- 注册必须填写并成功消耗邀请码；客户端预校验不能替代服务端原子校验。
- 头像支持相册选择、正方形裁剪、上传、修改和默认头像。
- 个人资料字段：头像、可编辑昵称、不可修改用户名（展示为“六合通号”）、个性签名、脱敏邮箱。
- Business API 是资料权威来源；昵称和头像通过 Outbox 同步到 Matrix。
- 好友主页提供发消息、语音通话、视频通话。
- 备注、标签、朋友圈权限、拉黑和删除好友置于右上角“更多”。
- 全局按钮使用现代白底图标加文字；不再使用大面积纯绿圆角按钮。
- 离线提示使用不推动页面布局的紧凑半透明状态胶囊。
- 邮件采用 Mailpit 开发适配器与可配置 SMTP 生产适配器。
- 邮箱验证同时支持 6 位验证码和验证链接。
- Matrix 登录采用一次性 Login Token。

## 3. 注册状态机与邀请码

```text
INVITATION_REQUIRED
  -> PENDING_EMAIL
  -> PENDING_MATRIX
  -> ACTIVE
```

### 3.1 邀请码

- 注册表单未填写邀请码时，客户端禁用提交并显示“请输入邀请码”。
- 输入完成后可调用 `/api/v1/invitations/validate` 显示预校验结果。
- `/api/v1/auth/register` 必须在创建用户的同一数据库事务中校验并消耗邀请码。
- 无效、过期、次数耗尽分别返回稳定错误码；任何客户端绕过都不能注册。
- 注册重试使用幂等键；同一请求不得重复消耗邀请码或重复创建用户。

### 3.2 注册提交

注册字段为：唯一用户名、唯一邮箱、至少 12 位密码、邀请码。注册响应返回不透明 `registration_session`，客户端不得依赖内部用户 UUID 查询状态。

### 3.3 邮箱验证

- 注册事务创建邮箱验证挑战并写入 Outbox。
- 邮件包含 6 位数字验证码和带签名的验证链接。
- 验证码有效期 10 分钟，最多尝试 5 次。
- 60 秒后允许重发；重发创建新挑战并立即废止旧验证码和旧链接。
- 验证码、验证 Token 仅保存哈希；日志、审计和 Outbox 不记录明文。
- 验证成功后用户进入 `PENDING_MATRIX`，并发布 Matrix 创建事件。
- APP 可通过不透明注册会话查询 `PENDING_EMAIL`、`PENDING_MATRIX`、`ACTIVE` 或失败状态。

## 4. 邮件与 Matrix 创建 Worker

### 4.1 邮件适配器

定义 `EmailSender` 公共接口：

```python
class EmailSender(Protocol):
    def send_email_verification(
        self, *, recipient: str, code: str, link: str
    ) -> None: ...
```

- 本地/测试使用 Mailpit SMTP，Web UI 只用于开发查看邮件。
- 生产使用显式配置的 SMTP 主机、端口、TLS、用户名、密码和发件人。
- SMTP 密码只从环境或 Secret Manager 读取。
- `business-worker` 注册 `identity.email` 与 `identity.matrix` Outbox handler；失败按原事件重试，不创建第二个用户。

### 4.2 Matrix 创建

- Matrix localpart 使用不可修改用户名的规范化值。
- Worker 通过 Synapse 管理接口幂等 `ensure_user`。
- Matrix 内部凭证由服务端专用密钥确定性派生，不向用户或 Flutter 暴露。
- 创建成功后原子写入 `matrix_user_id` 并激活业务账号。
- 超时只查询或重试同一 MXID。

## 5. 一次性 Matrix 登录令牌

业务密码只能发送到 Business API。双域登录改为：

1. Flutter 调用 Business `/auth/login`。
2. Business 登录成功后，Flutter 调用受认证的 `/auth/matrix-login-token`。
3. Business API 通过 Synapse 管理接口为当前用户签发短期单次 Token。
4. Flutter 使用 Matrix `m.login.token` 登录。
5. Matrix 初次同步成功后进入主页。

规则：

- 已恢复持久 Matrix 会话时不申请新 Token。
- Token 不进入普通存储、日志、错误文本或分析事件。
- Token 获取网络失败保留 Business 会话并允许重试。
- Matrix 明确拒绝 Token 时撤销本次 Business 会话，避免半登录。
- 不改变 SQLCipher、E2EE、SAS、交叉签名和加密备份边界。

## 6. 个人资料与头像

### 6.1 数据模型

Business 用户资料新增：

- `nickname`：1–64 字符，可编辑且不要求唯一；默认等于用户名。
- `signature`：最多 140 字符，可为空。
- `avatar_object_key`：私有对象引用，可为空。
- `profile_updated_at`：资料更新时间。

用户名不可修改。邮箱仅本人和授权管理员可见，客户端展示脱敏值。

### 6.2 API

- `GET /api/v1/profile/me`：读取本人资料。
- `PATCH /api/v1/profile/me`：修改昵称和签名，需要幂等键。
- `POST /api/v1/profile/avatar/uploads`：创建头像上传会话。
- `PUT /api/v1/profile/avatar/uploads/{upload_id}/content`：上传内容。
- `POST /api/v1/profile/avatar/uploads/{upload_id}/complete`：校验并设置头像。
- `DELETE /api/v1/profile/avatar`：恢复默认头像。

头像接受 JPEG、PNG、WebP；裁剪为正方形，客户端输出不超过 1024×1024，压缩后不超过 5 MiB。服务端重新校验真实 MIME、尺寸和大小。默认头像使用昵称首字符与稳定浅色背景，不暴露邮箱。

### 6.3 Matrix 同步

Business 资料提交与 `identity.profile.changed` Outbox 同事务完成。Worker 将昵称和头像同步到 Matrix；同步失败重试但不回滚 Business 资料。通讯录、好友搜索、朋友圈和“我”页面始终以 Business API 为准。

## 7. 通讯录与好友主页

### 7.1 好友列表

`GET /friends` 返回 `user_id`、`username`、`nickname`、`remark`、`avatar_url`、`matrix_user_id`、`moments_permission` 和标签。展示名优先级固定为：备注名 > 昵称 > 用户名。内部 UUID 仅用于 API 调用，禁止渲染。

好友申请列表返回申请人用户名、昵称和头像，不显示 `requester_id`。

### 7.2 好友主页

好友主页显示头像、展示名、六合通号、签名和朋友圈预览。主操作使用白底图文按钮：

- 发消息：通过稳定 MXID 复用已有 Direct Chat；不存在时创建强制 E2EE 房间，禁止重复创建。
- 语音通话：从该 E2EE Direct Chat 发起一对一加密通话。
- 视频通话：从同一房间发起一对一加密视频通话。

### 7.3 更多设置

右上角 `ellipsis` 进入好友设置页：备注名、标签、朋友圈权限、加入黑名单、删除好友。朋友圈权限选项保持 `DEFAULT`、`HIDE_MINE`、`HIDE_THEIRS`、`MUTUAL_HIDE`；保存后返回好友主页并立即刷新展示名。

## 8. “我”页面

页面顶部使用 `UserIdentityHeader` 展示可点击头像、昵称、六合通号和签名。点击进入资料编辑页；头像点击打开相册选择、裁剪、预览、上传、移除菜单。

功能组依次为：朋友圈、彩币、红包、钱包、设置。设置页显式展示“退出登录”，二次确认后清除 Business 与 Matrix 本地会话材料并返回登录页。

## 9. 品牌资源与认证页面

### 9.1 APP 图标

`liuhetong_logo.svg` 是唯一图标源。构建任务从该文件生成：

- Android legacy mipmap 与 adaptive icon foreground/background。
- iOS `AppIcon.appiconset` 全部必需尺寸。

生成产物必须自动检查尺寸、透明度与 Android/iOS 清单引用。不得继续手工维护互相不一致的图标。

### 9.2 沉浸认证页面

登录、注册和邮箱验证页复用 `ImmersiveAuthScaffold`：

- `landing.png` 全屏 `cover`，焦点保持在上部品牌主体。
- 下半区使用半透明白色输入控件与清晰文字，不放置厚重卡片。
- 键盘出现时表单从当前呈现位置平滑上移，背景保持稳定。
- 登录页提供注册入口；注册页提供登录入口；验证页提供重发、修改邮箱和状态查询。
- 减少动态效果时仅使用 200ms 以内淡入，不执行位移动画。

## 10. 全局按钮系统

- 主操作：白底、1dp 中性边框、轻阴影、绿色图标、深色文字。
- 次操作：透明背景、图标加文字。
- 危险操作：白底、红色图标、红色文字。
- 导航操作：44×44 点击区内的单一图标。
- 禁止新增大面积纯绿填充按钮；微信绿只用于图标、选中态、徽标和成功反馈。
- 按下即缩放至 0.98，松开使用临界阻尼恢复；动画可中断，减少动态效果时仅改变透明度/颜色。

此规范全局适用于登录、注册、好友、朋友圈、彩币、红包、钱包和设置页面。

## 11. 离线状态

现有顶部矩形是 `offlineAuthenticated` 横幅。改为悬浮在导航栏下方的 `NetworkStatusCapsule`：网络图标、简短文案、半透明材质，不改变页面主体约束或 TabBar 位置。联网恢复后自动淡出；点击可触发立即重试。开发 Release 直接使用可配置 Business API 地址，不依赖临时主机代理。

## 12. 组件边界

- `ImmersiveAuthScaffold`：背景、键盘避让、安全区和减少动态效果。
- `ModernActionButton`：主、次、危险样式。
- `UserAvatar`：默认、网络、上传和错误状态。
- `UserIdentityHeader`：头像与身份摘要。
- `NetworkStatusCapsule`：离线与重连反馈。
- `ContactActionPanel`：消息、语音、视频。
- `ProfileListRow`：统一白底图文行。
- `AsyncContentState`：加载、空状态、错误与重试。

复杂页面拆分为 Page、Controller、View Model 和可复用组件；不得继续将全部状态与网络操作压缩为一行 Widget 代码。

## 13. 错误与安全

- 所有错误按稳定错误码映射为字段级或页面级中文提示。
- 邮件失败不得重复消耗邀请码；Matrix 创建未知结果只查询原身份。
- 头像上传支持取消和稳定 upload id 重试。
- 离线保留缓存资料与双域会话，不显示账号失效。
- 服务端不得记录密码、验证码、邮箱验证 Token、Matrix Login Token、SMTP 密码、上传凭证或消息正文。
- 头像公开读取 URL 不得暴露对象存储内部路径或长期写权限。
- E2EE 房间和通话不能因好友快捷入口而降级。

## 14. 测试与验收

必须测试先行并覆盖：

1. 空、无效、过期、次数耗尽的邀请码均不能注册。
2. 注册幂等重放不重复消耗邀请码。
3. 6 位验证码、验证链接、5 次限制、10 分钟过期、60 秒重发和旧挑战失效。
4. Mailpit 契约、SMTP TLS 配置与日志脱敏。
5. Email/Matrix Outbox handler 注册、重试和幂等。
6. Matrix Login Token 单次使用、身份绑定、过期和客户端 `m.login.token` 登录。
7. 头像格式、大小、裁剪、上传、默认头像和 Matrix 同步。
8. 通讯录不渲染 UUID，备注名优先级正确。
9. 好友主页创建/复用 E2EE 私聊，并提供语音/视频入口。
10. 更多页保存备注、标签、朋友圈权限、拉黑和删除。
11. “我”页面显示资料、设置和退出登录。
12. 离线胶囊不改变页面主体布局。
13. Android/iOS 图标资源来自指定 SVG，认证页均使用指定背景图。
14. 两台模拟器完成注册、邮箱验证、登录、加好友、私聊、强制停止与会话恢复。

## 15. 明确不做

- 不允许无邀请码公开注册。
- 不允许使用邮箱验证码绕过 Matrix 创建状态。
- 不保存或同步用户业务密码到 Matrix。
- 不把内部 UUID 当作面向用户的六合通号。
- 不在本次重写多人群聊或朋友圈业务规则。
- 不改变账本、红包、钱包、审批与 E2EE 权威边界。
