# 畅聊 Figma 严格映射、主题控制与 Profile 设计规格

日期：2026-08-17

## 1. 目标与权威来源

本规格以 Figma 文件 `zpzwTbnj1hqx80tyRygX78` 为移动端视觉与状态权威来源。Flutter 必须将 `10 Auth`、`20 Messages & Chat`、`30 Calls`、`40 Contacts & Friend`、`50 Discovery & Moments`、`60 Profile`、`70 Finance`、`80 Feedback`、`90 Dark Reference` 及 `05 Icons 图标库` 映射为真实可达、可测试的页面与状态，不以临时占位页、字符图标或与 Figma 无关的通用控件替代。

本轮重点修复：

1. 消息页右上角“更多”的主题控制与本地持久化。
2. `60 Profile` 全状态的 Flutter 对齐。
3. 全 APP 页面、入口、真实图标、浅色/深色 Token、加载/错误/空状态的合规审计与缺口修复。
4. `50 Discovery & Moments` 的 `discovery-home` 和 Profile 首页底部导航固定在屏幕最底部，并使用真实图标。

## 2. Figma 节点基线

- 消息首页：`messages-inbox-default`（`30:2`）。
- 右上角更多面板：`messages-new-conversation-sheet`（`30:60`）。
- Profile 首页浅色：`profile-home-default`（`29:2169`）。
- Profile 首页深色：`profile-home-default-dark`（`29:2263`）。
- Profile 设置：`profile-settings-default`（`29:2357`）。
- `60 Profile` 页面：`19:5`，包含 17 个 393×852 状态画板。

所有页面以 iPhone 15、393×852、1 CSS px = 1 Figma px 为基准。系统状态栏由操作系统提供；Flutter 应实现状态栏以下的导航、内容与底部导航区域，不重复绘制伪状态栏。

## 3. 主题控制器

### 3.1 模式

主题值为枚举：

- `system`：跟随系统。
- `light`：强制浅色。
- `dark`：强制深色。

默认值为 `system`。未知、缺失或损坏的持久化值必须安全回退为 `system`。

### 3.2 数据流

`ThemePreferenceStore` 只负责读取与保存非敏感主题值；`ThemeController` 负责当前偏好、解析后的 `Brightness` 和通知 Widget 树刷新；`LiuhetongApp` 只消费控制器，不直接操作持久化。应用启动先读取主题，避免先显示浅色再跳变。选择模式后立即更新 UI，并将值写入本地；保存失败时恢复旧值并显示可重试错误，不允许 UI 与持久化状态永久分叉。

主题是非敏感设置，使用平台偏好存储，不写入 `flutter_secure_storage`，不与账号 Token、Matrix 数据库或恢复密钥混存。退出登录不清除主题偏好。

### 3.3 “更多”交互

点击消息首页右上角 `messages-more` 不再触发同步，而是打开与 `30:60` 一致的底部面板。面板保持以下顺序：

1. 发起群聊
2. 添加朋友
3. 扫一扫
4. 外观
5. 取消

点击“外观”打开二级底部面板，显示“跟随系统、浅色模式、深色模式”，当前模式带品牌绿色真实勾选图标。三项均为至少 44px 触控目标。切换成功后关闭二级面板；返回后一级面板不残留重复实例。

## 4. Profile 严格映射

### 4.1 “我”首页

`profile-home-default` 的结构固定为：页面标题“我” → 12px 外边距身份卡 → 12px 间距后的连续功能列表 → 固定底部主导航。

身份卡为 369×126，内边距 16/24，头像 72×72、12px 圆角；显示昵称、`畅聊号：{username}`、个性签名。点击整张身份卡进入资料详情，不在首页内联编辑。

列表顺序固定：朋友圈、彩币、红包、钱包、设置。每行高度 57，左侧 40×40 图标槽、16px 标题、右侧真实 chevron。入口必须可达；没有业务数据时显示对应 Figma 空/错误状态，不用无动作按钮。

首页禁止出现当前实现中的昵称输入框、签名输入框、保存资料大按钮、头像上传大按钮、恢复默认大按钮和退出登录大按钮。

### 4.2 资料与头像

资料详情、编辑及头像流程按 `60 Profile` 画板映射：

- `profile-details-default` / `profile-details-edit`
- `profile-avatar-picker` / `crop` / `preview` / `uploading`
- `profile-avatar-upload-failed`
- `profile-avatar-permission-denied`
- `profile-avatar-fallback`
- `profile-avatar-restore-confirm`

头像仍只在设备端选择与裁剪，上传前不向业务 API 发送未裁剪原图；权限拒绝提供“取消/系统设置”；失败可重试；恢复默认必须确认。现有 ProfileController 的业务接口保持不变，展示层拆成可测试页面和状态组件。

### 4.3 设置

设置页按 `29:2357` 实现：账号与隐私、消息通知、减少动态效果、关于畅聊、退出登录。行高、12px 页面外边距、40px 图标槽和 48px 退出按钮遵循 Figma。退出具有默认、确认、加载、失败状态。主题入口位于消息页“更多”面板；设置页仍展示其既有 Figma 项，不擅自替换“减少动态效果”。

## 5. Discovery 与底部导航

`50 Discovery & Moments` 的 `discovery-home` 必须使用 `Column`/约束布局：主内容占据剩余高度，底部主导航为独立固定区域，不能随内容滚动、浮在内容中段或被 SafeArea 推离底部。Profile 首页采用同一主导航实现。

四项顺序固定为：消息、通讯录、发现、我。图标必须来自 `05 Icons 图标库` 对应语义的真实矢量/Flutter IconData：消息气泡、联系人、发现/指南针、个人。禁止使用 `●`、`◇`、`▣`、`i`、文本字符或占位矩形模拟图标。选中项使用品牌绿，未选中项使用二级文本色；图标和文案都响应点击，触控区至少 44px。

底部导航由 `AppHome` 单一持有，子页面不得再绘制第二套导航。页面滚动时导航保持不动，键盘弹出时按系统 inset 处理而不覆盖关键操作。

## 6. 全 APP 合规审计规则

建立可执行的 Figma UI 合同清单，每个顶层画板记录：Figma node、Flutter route/widget、入口、浅/深色、加载、空、错误、弹窗/面板、真实图标和测试。审计顺序为 Auth、Messages、Calls、Contacts、Discovery、Profile、Finance、Feedback、Dark Reference。

发现缺口时按以下优先级修复：

1. 页面不可达、按钮无动作、数据流错误。
2. 安全/金融边界错误。
3. 缺少加载、错误、空状态或弹窗。
4. DOM/Widget 嵌套、固定导航和滚动区域错误。
5. 图标、Token、间距、字号和圆角差异。

Figma 中用于示意的字符图标不得直接复制到生产代码；应从 `05 Icons 图标库` 或项目 `ChangliaoIcons` 选择语义与轮廓匹配的真实图标。无法匹配时下载并提交 Figma 导出的原始 SVG，不手绘路径。

## 7. 浅色、深色与可访问性

所有页面支持同一套 Token 自动切换。`90 Dark Reference` 与各页面的 dark 代表画板决定深色背景、表面、分割线和文字色；不得直接读取 `MediaQuery.platformBrightnessOf` 绕过用户强制主题。所有页面统一从 `CupertinoTheme.of(context).brightness` 获取已解析主题。

触控目标至少 44×44；正文与背景满足可读对比；加载时禁用重复提交；错误可重试；系统减少动态效果仍独立于主题偏好。

## 8. 测试与完成标准

- ThemeController 单元测试覆盖默认、三模式、损坏值、保存失败、重启恢复和退出登录保留。
- Widget 测试覆盖右上角更多、外观二级面板、即时切换和持久化恢复。
- Profile 测试覆盖首页结构、五入口、资料编辑、头像全部状态、设置退出全部状态和深色代表页。
- AppHome 测试覆盖 Discovery/Profile 底部导航固定在视口最底部、无重复导航、真实图标和四项跳转。
- 静态合同禁止 Profile 首页旧大按钮和字符图标，要求 Figma node/widget 映射完整。
- 运行 `dart format`、`flutter analyze`、`flutter test`、移动端静态合同、`scripts/verify.ps1`。
- 雷电模拟器分别验证 system/light/dark 重启保持、Discovery/Profile 导航位置、Profile 主要流程和无 `FATAL EXCEPTION`。
- 验证证据写入 `docs/verification/`；无占位符、硬编码秘密、忽略警告或未解释失败。

## 9. 边界

本轮不改变 Business/Matrix 身份权威、E2EE、恢复密钥、账本、钱包、红包状态机或 OpenAPI。主题偏好仅是本地 UI 设置；Profile 仍通过公开 ProfileGateway 与业务 API 交互。任何财务写操作继续使用既有幂等与 Decimal 边界，Matrix 消息不决定财务状态。