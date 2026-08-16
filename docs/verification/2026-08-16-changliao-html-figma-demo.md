# 畅聊 HTML → Figma Demo 验证证据

日期：2026-08-16  
分支：`feature/changliao-html-figma`  
规格：`docs/superpowers/specs/2026-08-16-changliao-html-figma-design.md`  
计划：`docs/superpowers/plans/2026-08-16-changliao-html-figma-implementation.md`

## 范围

- 仅修改设计规格、HTML Demo、设计资源、验证证据与 Figma 交付物。
- 未修改 Flutter、Matrix、业务 API、账本、钱包状态机或部署契约。
- 用户可见品牌更新为“畅聊”；内部代码标识、包名、Matrix ID、资产代码及历史技术标识保持不变。

## 测试先行证据

| 阶段 | 失败原因 | 通过条件 |
| --- | --- | --- |
| 品牌契约 | `UI_DESIGN.md` 仍包含用户可见“六合通” | 文档展示名统一，内部资源名保留 |
| Token 契约 | Demo 尚无完整语义 Token | 浅/深主题语义键集合完全一致 |
| 组件契约 | 组件映射与 DOM 签名不存在 | 27 个组件使用唯一名称与严格 Light DOM 签名 |
| 画板注册表 | 页面/状态清单不存在 | 325 个唯一 Screen ID、393px 固定宽度、完整模块与状态覆盖 |
| 图标契约补充 | 仅有 25 个 Unicode 占位字形，导航与通话显示为圆点 | 58 个本地可编辑 SVG 图标、关键业务图标与 Figma Component 全部存在 |
| 认证可发现性补充 | 登录/注册状态存在但混排在 Auth 网格中 | Figma 提供独立 `09 登录与注册` 页及 4 个可编辑代表画板 |
| 浏览器渲染 | 捕获路由仍带审查页返回按钮 | `capture=1` 只输出单一画板且无外层控件 |
| 验证汇总 | `screenshots.mjs` 尚不存在 | 每个 Screen ID 均生成尺寸匹配的 PNG |

## 自动化结果

### HTML Demo 单元与契约测试

命令：`npm test`

- 13/13 通过。
- 覆盖品牌、内部技术标识保留、Token 对称、样式层顺序、禁止 Shadow DOM/内联样式/私有样式、组件契约、画板注册表、财务精度字符串与禁止能力。

### 浏览器烟雾测试

命令：`npm run test:browser`

- 通过。
- 验证设计画廊、模块筛选、错误状态筛选、浅/深独立页面、点击路由基础、无渲染错误及无用户可见旧品牌文本。

### 全量浏览器渲染契约

页面：`tests/browser-contract.html`

- 326 个画板全部构建成功。
- 页面标记：`data-test-result="passed"`、`data-screen-count="326"`。
- 登录、注册、主导航四个真实 SVG 图标及语音通话图标均有浏览器断言。

### 确定性截图

命令：`npm run screenshots`

- 生成 326/326 张 PNG。
- 每张图片验证 PNG 签名、393px 宽度及注册表声明高度。
- 总体积约 7.48 MiB。
- 登录背景位图已检查并替换为用户可见“畅聊”。

### 仓库基线验证

命令：`pwsh -NoProfile -File scripts/verify.ps1`

- HTML Demo 开发前基线通过。
- HTML Demo 与 326 张截图生成完成后的全仓验证通过：Repository/Deployment/Template/Render/Migrations/OpenAPI/Docker 均通过；Matrix Bot 9 项、Business API/Worker 161 项（1 项跳过）、Flutter 边界 9 项通过。
- 最终复验：`npm --prefix design-demo run verify` 退出码 0（13/13 契约测试、Browser smoke PASS、326/326 截图）；`pwsh -NoProfile -File scripts/verify.ps1` 退出码 0。

## 人工视觉抽查

- `auth-login-default.png`：浅色登录、品牌位图与表单层级正确。
- `foundation-icons-catalog.png`：58 个图标使用统一 24×24 网格和圆角描边，消息、通讯录、发现、我及通话图标清晰可辨。
- `moments-timeline-default.png`：朋友圈长内容保持 393px 固定宽度并自然增高。
- `wallet-home-default-dark.png`：深色 Token 切换、USDT 六位小数与钱包层级正确。

## Figma 交付验证

文件：[畅聊 HTML → Figma 移动端设计系统](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78)

### Foundations

- 2 个 Variable Collection：`01 Primitives`、`02 Semantic Colors`。
- 150 个 Variable：134 个原始 Token、16 个 Light/Dark 语义色。
- 所有 Variable 均有 Web code syntax；语义色两个 Mode 均使用 Alias；无断裂 Alias、无错误 `ALL_SCOPES`。
- 9 个 Noto Sans SC Text Style、1 个 Overlay Effect Style。

### Component Library

- 27/27 个真实 Figma Component，名称与 HTML custom element 合同完全一致。
- `05 Icons 图标库` 额外提供 58/58 个真实 SVG Icon Component；与 27 个 DOM Component 合计 85 个 Component。
- 图标页提供主导航实例预览（消息、通讯录、发现、我）和语音通话实例预览（麦克风、挂断、扬声器）。
- 每个组件暴露 `Label` 与 `Show anatomy` 属性。
- 组件背景、间距、Padding、圆角均绑定 Variable；无缺失绑定。
- 最小组件尺寸 440×150，满足 44px 最小触控目标检查。
- DOM 说明统一为 `root > anatomy > content`，并明确禁止私有样式覆盖。

### Frames 与 HTML Capture

- HTML → Figma 初始可编辑导入：334 个 Frame 实例，去重后为 325 个唯一 Screen ID。
- 9 个重复实例为 Dark Reference 专页副本；Dark 唯一状态 9/9。
- 补充的 `foundation-icons-catalog` 使用 Figma 原生 Component Instance 建成 393×1440 Frame；正式 Figma 注册表因此为 335 个实例、326 个唯一 Screen ID，保持 `missing=[]`、`unexpected=[]`、`exactMatch=true`。
- 正式移动端 Frame 宽度均为 393px，超长页面保留自然高度。
- 正式页数量：Auth 24、Messages & Chat 59、Calls 20、Contacts & Friend 40、Discovery & Moments 62、Profile 17、Finance 75、Feedback 28、Dark Reference 9。
- 对转换耗时较长的 174 个画板，同时保留 393px 精确截图 Frame；对应可编辑 DOM 已通过拆分模块 Capture 完整导入。

### Prototype 与视觉 QA

- 6 条独立 Flow Starting Point：Auth、Messages & Chat、Contacts & Friend、Discovery & Moments、Profile、Finance。
- 26 条同页可点击 Prototype 链接，覆盖登录、消息→聊天、通讯录→好友、发现→朋友圈、个人资料、彩币及钱包流程。
- 代表页 Figma 导出已人工检查：登录、消息、通讯录异常、彩币转账、Dark 登录。
- QA 图片保存在 `design-demo/artifacts/figma-qa/`。
- 新增 QA：`auth-supplement.png`、`icons-library.png`、`navigation-icons.png`、`call-icons.png`。
- `09 登录与注册` 提供登录默认、登录已填写、注册默认、注册错误 4 个可编辑 393×852 代表画板。

## 规格符合性审查

- `UI_DESIGN.md`、HTML Demo 与 Figma 画板的用户可见品牌均为“畅聊”系列名称；内部技术标识保持原样。
- 326 个唯一 Screen ID 全部存在，Light 全状态与 9 个 Dark 代表状态范围符合已批准规格。
- 所有正式移动端 Frame 为 393px 宽，基准高度 852px；长页面按注册表自然增高。
- 27 个 DOM 组件名、58 个 SVG Icon Component、严格 DOM 合同、Token 分层、主题切换与画廊筛选符合四节正式设计规格。
- HTML 设计审查画廊可筛选、可单屏捕获；Figma 正式模块页与可编辑 HTML Capture 均已提供。

## 质量与安全审查

- 未改动 Matrix、业务 API、账本、红包分配、钱包状态机、认证/RBAC/TOTP、迁移或 OpenAPI。
- 未引入凭证、Token、真实钱包地址、密钥、运行数据库或敏感日志。
- 临时远程 Capture Script 已清理；HTML 仍无 Shadow DOM、内联样式或私有样式逃逸。
- 彩币两位与 USDT 六位精度仍以字符串固定表达；未加入兑换、USDT P2P 或 USDT 红包能力。
- HTML Demo 和仓库全量验证均通过，无忽略警告或临时旁路。

## 完成结论

- HTML Demo、326 张全量截图、Figma Foundations、85 个组件、326 个唯一画板、独立登录/注册审查页、Dark 关键页与可点击原型均已交付。
- 临时 Figma Capture 脚本已从 `design-demo/index.html` 清理。
- Figma 状态台账：`design-demo/artifacts/figma-state.json`。
