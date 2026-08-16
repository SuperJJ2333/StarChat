# 畅聊 HTML Demo 与 Figma 导入设计规格

**状态：** 已批准  
**日期：** 2026-08-16  
**适用仓库：** `StarChat`  
**产品展示名：** 畅聊  
**设计基线：** `UI_DESIGN.md`、`docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md`

## 1. 目标与边界

本任务把 `UI_DESIGN.md` 规定的移动端设计完整展开为可浏览、可测试、可导入 Figma 的 HTML Demo，并创建便于后续微调的 Figma Design 文件。

交付必须满足：

1. 所有页面、弹窗、设置、加载、空、权限、离线和异常状态均展开为浅色独立画板。
2. 登录、消息、聊天、通讯录、朋友圈、“我”和钱包提供深色代表画板；完整组件库和 Foundations 同时提供 Light/Dark。
3. 画板使用 iPhone 15 基准 `393×852px`，`1 CSS px = 1 Figma px`；长页保持 393px 并自然增高。
4. HTML 以“设计审查画廊 + 可点击原型”呈现，并支持模块、状态、主题筛选及单画板 URL。
5. Figma 中每个静态状态为独立 Frame，同时提供 Variables、Styles、Components、Variants 和 Auto Layout。
6. `UI_DESIGN.md`、HTML Demo 和 Figma 可见文本中的品牌名统一为“畅聊”，同步使用“畅聊号”“畅聊朋友圈”“畅聊彩币红包”。
7. 内部项目标识、包名、Matrix ID、资产代码、既有产品规格中的历史技术标识和现有资产文件名保持不变。

本任务不修改 Flutter 行为、Matrix/E2EE、业务 API、账本、红包或钱包状态机、OpenAPI、数据库迁移和内部包名。

## 2. 技术方案

采用原生 HTML、CSS、JavaScript ES Modules 与 Light DOM Web Components。页面由结构化注册表和集中式演示数据生成；不引入 React/Vue 等运行时，不使用 Shadow DOM。HTML 与 Figma 共用稳定的页面 ID、组件命名和状态枚举。

目录职责：

```text
design-demo/
├── index.html
├── package.json
├── README.md
├── scripts/
├── src/
│   ├── app.js
│   ├── catalog/
│   │   ├── screens.js
│   │   └── fixtures.js
│   ├── components/
│   ├── screens/
│   ├── icons/
│   └── styles/
│       ├── reset.css
│       ├── tokens.css
│       ├── primitives.css
│       ├── components.css
│       └── gallery.css
├── tests/
└── artifacts/screenshots/
```

## 3. 页面与状态范围

### 3.1 Figma 页面分组

```text
00 Cover & Index
01 Foundations — Light
02 Foundations — Dark
03 Components — Light
04 Components — Dark
05 Icons 图标库
09 登录与注册
10 Auth
20 Messages
21 Chat & Composer
22 Calls
30 Contacts
31 Friend Profile
40 Discovery
41 Moments
50 Me & Profile
60 CAIBI
61 Red Packet
62 USDT Wallet
70 Global Feedback
90 Dark Key Screens
99 HTML Capture Reference
```

`99 HTML Capture Reference` 是像素对齐参考，完成后隐藏并锁定，或经用户确认删除。

### 3.2 Auth

- Figma 必须提供独立的 `09 登录与注册` 快速审查页，默认登录与默认注册位于第一屏可见区域，不得仅混排在全状态网格中。
- 登录：默认、填写、提交中、字段缺失、凭证错误、网络错误。
- 注册：默认、邀请码缺失、字段错误、提交中、失败、完成。
- 邮箱验证：验证码、验证链接、倒计时、可重发、验证中、成功、错误、过期、重发失败。
- 键盘表单布局和减少动态效果状态。

### 3.3 Messages、Chat 与 Calls

- 消息列表：正常、同步中、空、离线、重连、同步失败；单聊、群聊、官方客服、静音、置顶、未读与 `99+`。
- 文本聊天：双方消息、连续消息、跨日时间戳、回复、撤回、发送中、已发送、失败、重试、空会话、历史加载及失败。
- 输入区：文本、附件、语音和键盘模式。
- 语音：录制、上滑取消、取消区、不足 1 秒、60 秒、本地试听、删除、发送。
- 附件：图片、文件、权限拒绝、不支持、超限、上传进度、失败、保留重试、完成。
- 红包卡片：可领取、已领取、已领完、已过期、已撤回。
- 音视频呼叫：呼叫中、来电、连接、弱网、结束、摄像头/麦克风状态、镜头切换、权限拒绝、忙线、无人接听、连接失败和网络中断。

### 3.4 Contacts 与 Friend Profile

- 通讯录、拼音分组、A–Z 索引、索引浮层、新朋友、好友请求各状态、群聊、标签、公众号/官方客服、搜索、空和错误。
- 好友主页、朋友圈预览、消息/语音/视频入口、创建中与失败。
- 更多、备注、标签、朋友圈权限、黑名单、删除好友及其确认、成功和失败状态。

### 3.5 Discovery 与 Moments

- 发现首页、朋友圈无/有新内容、推荐/最新、加载和网络异常。
- 朋友圈时间线：正常、加载、空、刷新失败、分页失败、封面、纯文字、1/2/4/5–9 图。
- 操作菜单、点赞/评论、五种可见范围。
- 上传中、审核中、已发布、部分可见、已下架、发布失败。
- 发布页：纯文字、1–9 图、位置、提醒谁看、可见范围、禁用、上传中、图片失败、重试、离开确认和底部面板。
- 动态详情、评论、回复、删除确认、搜索与筛选、无结果、无权限过滤、互动通知和朋友圈完整设置。

### 3.6 Me、Profile 与 Settings

- “我”首页、本人资料、编辑资料、畅聊号、签名、脱敏邮箱。
- 头像相册、权限、裁剪、预览、上传、失败、恢复默认和加载失败回退。
- 设置、账号与隐私入口、退出确认、退出中和退出失败。

### 3.7 CAIBI、Red Packet 与 Wallet

- 彩币首页、两位小数余额、记录筛选、转账、手续费、确认、处理、成功、收款人不存在、格式错误、余额不足、重复提交和未知结果。
- 四种红包创建方式、金额/份数/祝福语、校验、确认、处理、失败、成功、领取五态、重复领取、并发领完、未知结果、领取明细和退回说明。
- USDT 六位小数余额、记录筛选、充值地址、复制、分配失败、低额人工处理、充值状态。
- 提现金额/地址/费用/确认、地址错误、金额不足、余额不足、审核、二次审批、托管处理、广播、确认、失败退款和结果未知查询原订单。
- 地址默认省略，详情允许复制完整地址；禁止 CAIBI/USDT 兑换、USDT 用户转账和 USDT 红包。

### 3.8 Global Feedback 与深色代表页

- Dialog、Toast、Empty State、加载、骨架、禁用、权限、断网、重连、服务不可用、超时、减少动态效果和字号缩放。
- 深色独立画板：登录、消息列表、混合聊天、通讯录、朋友圈、“我”、USDT 钱包及完整组件/反馈状态。

## 4. 命名、组件和 DOM 硬规则

### 4.1 样式隔离

CSS 固定顺序为 `reset.css`、`tokens.css`、`primitives.css`、`components.css`、`gallery.css`。不导入旧原型私有样式，不使用 Shadow DOM、内联 `style`、页面 `<style>`、CSS-in-JS、`!important` 或外部 UI 框架默认样式。除 `tokens.css` 外不得声明视觉字面量。

### 4.2 类名

只允许：

- `ui-*`：画板与审查系统。
- `l-*`：无视觉语义布局。
- `c-*`：可复用组件。
- `p-*`：页面组合。
- `u-*`：有限辅助类。
- `is-*`：临时交互状态。

组件使用 `c-{block}__{element}`、`c-{block}--{variant}`。Element 只允许一层。选择器最多两级，主题例外为 `[data-theme="dark"] .c-*`。禁止随机、表现型、位置型和私有类名。

### 4.3 Token

Token 仅在 `tokens.css` 定义，前缀为 `--color-*`、`--type-*`、`--space-*`、`--radius-*`、`--size-*`、`--motion-*`、`--shadow-*` 和 `--z-*`。组件只能引用语义 Token。除 `0`、`100%`、`currentColor`、`inherit`、`1fr` 和必要变量引用外，不允许私有视觉常量。

### 4.4 画板 DOM

```html
<article class="ui-screen" data-screen-id="..." data-module="..." data-page="..." data-state="..." data-theme="light" aria-label="...">
  <div class="ui-device">
    <header class="c-status-bar"></header>
    <main class="ui-device__viewport">
      <section class="p-module-page"></section>
    </main>
    <footer class="c-home-indicator" aria-hidden="true"></footer>
  </div>
</article>
```

根结构和子节点顺序不可变；一个画板只有一个设备。页面不得插入无语义包装。弹窗和底部面板也必须登记为独立画板。

### 4.5 组件 DOM

列表单元固定为 Leading、Body（Title/Subtitle）、Trailing；头像固定为 Image、Fallback、Badge；消息固定为 Avatar、Content、Row、Bubble、Delivery。Incoming/Outgoing 共用 DOM，以属性和 CSS Order 改变方向。红包固定为 Body 和 Footer，Footer 文案为“畅聊彩币红包”。

按钮固定包含 Icon、Label、Progress，Variant 仅为 Primary、Secondary、Danger、Navigation。状态标签必须同时包含图标和文字。Dialog 和 Action Sheet 必须位于 Overlay 中并包含 Scrim。Toast 必须使用 Live Region。

Web Component 标签统一以 `app-` 开头；每个组件导出 `componentContract`，声明标签、根类、属性、状态、插槽和 DOM Signature。相同组件不同状态保持同一 Signature。

### 4.6 DOM 约束

- `.ui-screen` 到可见文本最大深度 8，组件内部最大深度 4。
- 禁止无类名布局 `div` 和无职责单子节点包装。
- 标题按 `h1`、`h2`、`h3`；交互使用语义元素。
- 图标来自统一 SVG 注册表，使用 `currentColor`，禁止 Emoji 和 Unicode 伪图标。
- 图标库不少于 48 个可编辑图标，统一采用 `24×24` 网格、`1.8px` 圆角描边；必须包含消息、通讯录、发现、我、语音通话、视频通话、麦克风、相机、搜索、设置、钱包和红包。
- Figma `05 Icons 图标库` 中每个图标必须为真实 Component，并提供主导航与语音通话控件的实例化预览。

## 5. 视觉系统

### 5.1 设备

画板 `393×852px`；顶部安全区 59、导航栏 44、TabBar 49、底部安全区 34、Home Indicator `134×5`。聊天页固定视口，长页自然增高。

### 5.2 色彩

浅色和深色分别使用 `UI_DESIGN.md` 的品牌、背景、Surface、文字、分隔线、危险、警告和消息气泡 Token。`socialLink` 仅用于社交用户名、位置和可点击社交文本。主题必须具有完全相同的 Token 键。

### 5.3 字体

HTML 字体栈为系统字体、PingFang SC、Noto Sans CJK SC、Microsoft YaHei、sans-serif。Figma 必须先检测可用中文字体，不默认使用 Inter。正文使用设计文档的 Display、Title 1/2、Body、Callout、Subhead、Caption、Badge 规格；认证品牌名使用登记后的 `34/700/42/-1` Token。资产数字启用等宽数字。

### 5.4 间距、圆角和尺寸

间距使用 `4/8/12/16/24/32`；圆角使用 `4/8/10/12/14/999`。导航、TabBar、列表、头像、按钮、Composer、触摸区、Dialog、红包、语音条和索引尺寸严格使用 `UI_DESIGN.md` 规格。

### 5.5 资源

认证使用仓库现有 `landing.png`，Logo 和图标沿用现有本地资产文件；可见品牌改为“畅聊”，不重命名底层文件。头像、朋友圈和聊天图片使用本地虚构演示资源，不使用外链或真实用户数据。

## 6. 交互与演示数据

组件状态统一为 Idle、Hover、Pressed、Focus Visible、Disabled、Loading、Success、Warning、Error。移动正式画板不展开 Hover。按压、页面、Dialog、消息、红包和上传动效使用 `UI_DESIGN.md` 时长；减少动态效果时取消位移、缩放和波形，仅保留不超过 100ms 的淡入淡出。

审查画廊提供搜索、模块/状态/主题/页面长度筛选、单画板视图、设备外框开关、复制 ID、关键流程跳转及弹窗/Toast/Action Sheet 触发。所有可触发状态仍须登记为独立画板。

演示数据集中于 `fixtures.js`，必须明显虚构。CAIBI 与 USDT 使用定点字符串，不进行 JavaScript 浮点资产计算；不使用真实 Token、密钥、邮箱、邀请码、Matrix ID 或钱包地址。

## 7. HTML 到 Figma 数据流

### 7.1 HTML 捕获

`UI_DESIGN.md → Token/Contract → Registry/Fixtures → Web Components → Tests → Local Server → Browser Verification → HTML to Figma Capture`。

按模块分批导入同一个新 Figma Design 文件“畅聊 App UI — HTML Import”，保留稳定 `data-screen-id` 和命名。含图片页面必须先通过 HTML 捕获把图片带入文件。捕获结果放入 `99 HTML Capture Reference`。

### 7.2 Figma 原生系统化

在同一文件创建 Light/Dark Variables、Spacing/Radius/Size Variables、Text/Effect Styles、组件 Variant 和页面 Auto Layout。正式页面使用原生组件实例，并与 HTML 捕获并排复核。

组件映射固定为 Actions/Button、Lists/Tile、Identity/Avatar、Identity/Header、Chat/Message Bubble、Chat/Voice Bubble、Chat/Attachment、Chat/Composer、Finance/Red Packet Card、Feedback/Status Chip、Overlay/Dialog、Overlay/Action Sheet、Feedback/Toast、Feedback/Empty State、Feedback/Network Capsule、Moments/Tile 和 Moments/Image Grid。

Figma Variant 使用英文机器属性：Theme、State、Kind、Direction、Status；画板标题和说明使用中文。

### 7.3 批次与验证

导入按 Cover/Foundations、Components Light、Components Dark、Auth、Messages/Chat、Calls、Contacts/Friend、Discovery/Moments、Me/Profile、Finance、Feedback、Dark Key Screens 分批执行。每批检查 Frame 数、名称、393px 宽度、文本裁切、图片、Auto Layout、Overlay、组件关联和顶级节点位置。

## 8. 测试与验证

实现遵循 Red/Green。测试覆盖 DOM、类名、Token、品牌、页面注册、组件、浏览器、无障碍、动效和视觉截图。

强制检查包括：

- 根 DOM、组件 Signature、深度和包装节点。
- 允许的类名前缀与 BEM。
- Token 唯一来源、Light/Dark 键一致、无内联/私有样式。
- 可见旧品牌清零。
- 浅色全量、深色关键页和独立异常画板覆盖。
- 每页唯一标题、图片 Alt、Dialog 关联、Toast Live Region、44×44 点击区、字号 1.4 不裁切和状态不只依赖颜色。
- 真实 Chromium 中画廊、筛选、路由、交互、资源、控制台和减少动态效果。
- `393×852`、长页和桌面画廊视口截图。

Figma 导入后检查 Variables、Styles、Components、Variants、Auto Layout、Frame 尺寸、页面数量、资源、裁切、重叠、Placeholder、旧品牌及 HTML/Figma 数量对账。

验证证据写入 `docs/verification/2026-08-16-changliao-html-figma-demo.md`，记录 Red/Green、所有门禁、截图索引、Figma 文件标识、批次结果和全仓验证输出。

## 9. 完成标准

只有同时满足以下条件才能完成：

1. `UI_DESIGN.md` 可见品牌统一为“畅聊”。
2. HTML Demo 完整覆盖批准的页面、弹窗、设置和异常状态。
3. 浅色全量与深色关键页完整，393px 宽度一致。
4. 画廊筛选、搜索、路由和关键交互有效。
5. 组件、类名、DOM 和 Token 契约全部通过。
6. 无旧私有样式、内联样式、页面私有视觉常量和旧品牌可见文本。
7. 契约、组件、浏览器、无障碍和视觉验证通过。
8. HTML 与 Figma Frame 数量一致。
9. Figma 具有可编辑 Variables、Styles、Components、Variants 和 Auto Layout。
10. 无缺图、裁切、重叠、Placeholder 或错误字体替换。
11. 验证证据和全仓验证结果已记录。
12. Figma 文件标识或链接已交付。
