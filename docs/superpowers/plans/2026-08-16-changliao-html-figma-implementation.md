# 畅聊 HTML Demo 与 Figma 导入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建完整覆盖 `UI_DESIGN.md` 页面与状态的畅聊 HTML 设计审查 Demo，并把验证后的画板导入一个具有 Variables、Styles、Components、Variants 和 Auto Layout 的 Figma 文件。

**Architecture:** Demo 使用无第三方运行时的 HTML、CSS、JavaScript ES Modules 与 Light DOM Web Components。结构化 Registry 是画廊、单页路由、测试、截图和 Figma Frame 对账的唯一页面清单；组件契约和集中式 Token 强制 DOM、类名及视觉一致性。Figma 先按模块捕获 HTML 像素参考，再在同一文件建立原生设计系统并按批次复核。

**Tech Stack:** Node.js 24 内置测试运行器、原生 Web Components、CSS Custom Properties、Google Chrome Headless、PowerShell 7、Figma MCP/HTML to Figma。

## Global Constraints

- 开始任何产品行为修改前阅读 `docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md`；本计划依据已批准的 `docs/superpowers/specs/2026-08-16-changliao-html-figma-design.md`。
- 所有 PowerShell 命令使用 `pwsh.exe`，设置 UTF-8 无 BOM；Python 进程设置 `PYTHONUTF8=1` 和 `PYTHONIOENCODING=utf-8`。
- 文件所有权仅限 `UI_DESIGN.md`、`design-demo/**`、本计划、设计规格和 `docs/verification/2026-08-16-changliao-html-figma-demo.md`。
- 不修改 Flutter、Matrix/E2EE、业务 API、账本、红包/钱包状态机、OpenAPI、迁移、包名、Matrix ID、资产代码和历史产品规格技术标识。
- 用户可见品牌统一为“畅聊”“畅聊号”“畅聊朋友圈”“畅聊彩币红包”；内部 `liuhetong`、`StarChat`、Matrix 标识和 `CAIBI` 保持不变。
- 所有正式移动画板宽度固定为 393px，标准高度至少 852px；长页自然增高；`1 CSS px = 1 Figma px`。
- 浅色覆盖全部页面和状态；深色覆盖完整 Foundations/Components 及登录、消息、聊天、通讯录、朋友圈、“我”、钱包。
- HTML 不使用 Shadow DOM、内联样式、页面 `<style>`、CSS-in-JS、`!important`、外链图片或第三方 UI 框架。
- 视觉字面量只能出现在 `design-demo/src/styles/tokens.css`；组件和页面只引用语义 Token。
- CAIBI 和 USDT 只使用定点字符串；禁止浮点资产计算、CAIBI/USDT 兑换、USDT 用户转账和 USDT 红包。
- 每个任务先写失败测试，确认失败原因，再做最小实现；每个可审核增量单独提交。

## File Map

### Repository documents

- Modify `UI_DESIGN.md`: 仅替换用户可见品牌文案。
- Create `docs/verification/2026-08-16-changliao-html-figma-demo.md`: Red/Green、浏览器、截图、Figma 批次和全仓验证证据。

### Demo entry and tooling

- Create `design-demo/package.json`: 零依赖脚本入口。
- Create `design-demo/index.html`: 画廊宿主与固定样式加载顺序。
- Create `design-demo/README.md`: 启动、测试、契约、导入说明。
- Create `design-demo/scripts/serve.mjs`: 仅服务 `design-demo` 的本地静态服务器。
- Create `design-demo/scripts/browser-smoke.mjs`: Chrome Headless 路由与渲染检查。
- Create `design-demo/scripts/screenshots.mjs`: 按 Registry 输出确定性截图。
- Create `design-demo/scripts/verify.mjs`: 串联所有 Demo 门禁。

### Catalog and runtime

- Create `design-demo/src/app.js`: URL 状态、筛选、主题、画廊和交互控制。
- Create `design-demo/src/catalog/contracts.js`: 页面、组件和枚举契约。
- Create `design-demo/src/catalog/fixtures.js`: 集中式虚构演示数据。
- Create `design-demo/src/catalog/screens.js`: 完整且稳定的 Screen Registry。
- Create `design-demo/src/icons/icons.js`: SVG 图标白名单与 `icon(name)`。

### Components

- Create `design-demo/src/components/base.js`: Light DOM 基类、属性校验和 Contract 导出辅助。
- Create `design-demo/src/components/chrome.js`: 状态栏、导航栏、TabBar、设备壳。
- Create `design-demo/src/components/actions.js`: Action Button、Composer、表单控件。
- Create `design-demo/src/components/identity.js`: Avatar、List Tile、Identity Header、Contact Index。
- Create `design-demo/src/components/chat.js`: Message、Voice、Attachment、Timestamp、Unread Badge。
- Create `design-demo/src/components/feedback.js`: Status Chip、Dialog、Action Sheet、Toast、Empty State、Network Capsule。
- Create `design-demo/src/components/finance.js`: Red Packet Card、Amount Summary、Transaction Row。
- Create `design-demo/src/components/moments.js`: Moment Tile、Image Grid、Reaction Panel、Visibility Icon。
- Create `design-demo/src/components/register.js`: 唯一自定义元素注册入口。

### Screens

- Create `design-demo/src/screens/shared.js`: 固定画板 Scaffold 和通用页面组合器。
- Create `design-demo/src/screens/auth.js`: 认证全状态。
- Create `design-demo/src/screens/messaging.js`: 消息、聊天、Composer 全状态。
- Create `design-demo/src/screens/calls.js`: 音视频呼叫全状态。
- Create `design-demo/src/screens/contacts.js`: 通讯录、好友资料和设置全状态。
- Create `design-demo/src/screens/moments.js`: 发现、朋友圈、发布和设置全状态。
- Create `design-demo/src/screens/profile.js`: “我”、资料、头像和设置全状态。
- Create `design-demo/src/screens/finance.js`: CAIBI、红包、USDT 钱包全状态。
- Create `design-demo/src/screens/feedback.js`: 全局反馈、字号和减少动态效果状态。

### Styles

- Create `design-demo/src/styles/reset.css`: 浏览器默认样式清理。
- Create `design-demo/src/styles/tokens.css`: 唯一视觉常量来源和 Light/Dark Token。
- Create `design-demo/src/styles/primitives.css`: 画板、设备、布局与无障碍原语。
- Create `design-demo/src/styles/components.css`: 全部组件视觉。
- Create `design-demo/src/styles/gallery.css`: 桌面审查画廊视觉。

### Tests

- Create `design-demo/tests/brand-contract.test.mjs`: 可见品牌边界。
- Create `design-demo/tests/token-contract.test.mjs`: 私有样式和 Token 边界。
- Create `design-demo/tests/component-contracts.test.mjs`: 组件标签、属性、状态和 DOM Signature。
- Create `design-demo/tests/screen-registry.test.mjs`: 页面覆盖、稳定 ID、尺寸和主题。
- Create `design-demo/tests/source-contract.test.mjs`: 类名、Shadow DOM、外链和资产安全规则。
- Create `design-demo/tests/browser-contract.html`: 在真实 DOM 中执行结构和无障碍断言。

---

### Task 1: 固化品牌边界并更新 UI_DESIGN

**Files:**
- Create: `design-demo/package.json`
- Create: `design-demo/tests/brand-contract.test.mjs`
- Modify: `UI_DESIGN.md`

**Interfaces:**
- Consumes: Node.js 24 `node:test`、仓库根路径。
- Produces: `npm test -- tests/brand-contract.test.mjs` 可执行入口；后续测试复用 `design-demo/package.json`。

- [ ] **Step 1: 创建最小 package.json 和失败的品牌测试**

```json
{
  "name": "changliao-design-demo",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "test": "node --test --test-reporter=spec"
  }
}
```

```js
import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("UI_DESIGN uses the approved visible brand", async () => {
  const markdown = await readFile(new URL("../../UI_DESIGN.md", import.meta.url), "utf8");
  assert.doesNotMatch(markdown, /六合通(?:号|朋友圈|彩币红包)?/u);
  assert.match(markdown, /# 畅聊 UI 设计规范/u);
  assert.match(markdown, /畅聊号/u);
  assert.match(markdown, /畅聊朋友圈/u);
  assert.match(markdown, /畅聊彩币红包/u);
});
```

- [ ] **Step 2: 运行测试并确认因旧品牌失败**

Run: `Set-Location design-demo; npm test -- tests/brand-contract.test.mjs`  
Expected: FAIL，报告 `UI_DESIGN.md` 仍含“六合通”。

- [ ] **Step 3: 仅替换 UI_DESIGN.md 用户可见品牌**

精确替换标题、品牌描述、红包 Footer、朋友圈、账号、Logo 说明中的用户可见文案；不替换文件名 `liuhetong_logo.svg`。

- [ ] **Step 4: 运行聚焦测试**

Run: `Set-Location design-demo; npm test -- tests/brand-contract.test.mjs`  
Expected: PASS。

- [ ] **Step 5: 提交品牌文档边界**

```powershell
git add -- UI_DESIGN.md design-demo/package.json design-demo/tests/brand-contract.test.mjs
git commit -m "docs(ui): rename visible mobile brand to changliao"
```

### Task 2: 建立零依赖 Demo Shell、Token 和静态服务

**Files:**
- Create: `design-demo/index.html`
- Create: `design-demo/src/styles/reset.css`
- Create: `design-demo/src/styles/tokens.css`
- Create: `design-demo/src/styles/primitives.css`
- Create: `design-demo/src/styles/components.css`
- Create: `design-demo/src/styles/gallery.css`
- Create: `design-demo/scripts/serve.mjs`
- Create: `design-demo/tests/token-contract.test.mjs`
- Create: `design-demo/tests/source-contract.test.mjs`
- Modify: `design-demo/package.json`

**Interfaces:**
- Consumes: 固定 CSS 加载顺序和 393×852 设备规格。
- Produces: `npm run serve`，以及 `--color-*`、`--type-*`、`--space-*`、`--radius-*`、`--size-*`、`--motion-*`、`--shadow-*`、`--z-*` Token。

- [ ] **Step 1: 写 Token 与源码策略失败测试**

测试递归扫描 `src/**/*.{css,js}`，断言非 `tokens.css` 文件没有十六进制/RGB/HSL 色值、`style=`、`!important`、`attachShadow`、`http(s)` 图片；断言 Light/Dark Token 键集合相同。

- [ ] **Step 2: 确认测试因文件缺失失败**

Run: `Set-Location design-demo; npm test -- tests/token-contract.test.mjs tests/source-contract.test.mjs`  
Expected: FAIL，报告 `tokens.css` 或 `index.html` 不存在。

- [ ] **Step 3: 创建固定 HTML/CSS Shell**

`index.html` 只包含一个 `#app`、五个固定 CSS Link 和 `src/app.js` Module Script。`tokens.css` 定义设计规格全部 Light/Dark 色彩、字体、间距、圆角、尺寸、动效、阴影和层级；其他 CSS 初始只引用变量。

- [ ] **Step 4: 创建限制根目录的静态服务器**

`serve.mjs` 使用 `node:http`、`fileURLToPath`、`path.resolve`，拒绝越过 `design-demo` 根的路径；无扩展名和 `/` 返回 `index.html`；端口读取 `PORT`，默认 `4173`。

- [ ] **Step 5: 扩展 package scripts 并运行测试**

```json
{
  "scripts": {
    "serve": "node scripts/serve.mjs",
    "test": "node --test --test-reporter=spec"
  }
}
```

Run: `Set-Location design-demo; npm test -- tests/token-contract.test.mjs tests/source-contract.test.mjs`  
Expected: PASS。

- [ ] **Step 6: 提交 Foundation**

```powershell
git add -- design-demo
git commit -m "feat(ui-demo): add tokenized html foundation"
```

### Task 3: 建立 Web Component 契约与核心 UI 组件

**Files:**
- Create: `design-demo/src/catalog/contracts.js`
- Create: `design-demo/src/icons/icons.js`
- Create: `design-demo/src/components/base.js`
- Create: `design-demo/src/components/chrome.js`
- Create: `design-demo/src/components/actions.js`
- Create: `design-demo/src/components/identity.js`
- Create: `design-demo/src/components/chat.js`
- Create: `design-demo/src/components/feedback.js`
- Create: `design-demo/src/components/finance.js`
- Create: `design-demo/src/components/moments.js`
- Create: `design-demo/src/components/register.js`
- Create: `design-demo/tests/component-contracts.test.mjs`
- Modify: `design-demo/src/styles/components.css`

**Interfaces:**
- Consumes: `defineContract({tagName, rootClass, allowedAttributes, allowedStates, requiredSlots, domSignature})`。
- Produces: `componentContracts: readonly ComponentContract[]`、`registerComponents(): void`、`icon(name): string`。

- [ ] **Step 1: 写失败的组件契约测试**

测试要求 `componentContracts` 包含批准的 17 个 Figma 映射组件，标签均为 `app-*`、根类均为 `c-*`、标签和根类唯一，状态为白名单，Signature 深度不超过 4。

- [ ] **Step 2: 确认测试因契约模块缺失失败**

Run: `Set-Location design-demo; npm test -- tests/component-contracts.test.mjs`  
Expected: FAIL，`ERR_MODULE_NOT_FOUND`。

- [ ] **Step 3: 实现基类、图标白名单和 Chrome/Actions/Identity**

Light DOM 基类在 `connectedCallback` 中校验属性并调用确定性 `render()`；不得使用 `innerHTML` 接收演示数据。图标函数仅接受登记名称并返回固定本地 SVG 字符串。实现状态栏、导航、TabBar、按钮、列表、头像、Identity Header 和 Contact Index。

- [ ] **Step 4: 实现 Chat/Feedback/Finance/Moments 组件**

实现消息同构 DOM、语音、附件、Composer、状态标签、Dialog、Action Sheet、Toast、Empty State、Network Capsule、红包、金额摘要、交易行、Moment Tile、Image Grid、Reactions 和 Visibility Icon。

- [ ] **Step 5: 注册全部元素并完善组件 CSS**

`register.js` 是唯一调用 `customElements.define` 的模块；重复加载先检查 `customElements.get`。组件 CSS 只使用 Token，并保持选择器不超过批准复杂度。

- [ ] **Step 6: 运行契约和策略测试**

Run: `Set-Location design-demo; npm test -- tests/component-contracts.test.mjs tests/token-contract.test.mjs tests/source-contract.test.mjs`  
Expected: PASS。

- [ ] **Step 7: 提交组件库**

```powershell
git add -- design-demo/src design-demo/tests
git commit -m "feat(ui-demo): add strict light-dom component library"
```

### Task 4: 建立完整 Screen Registry 与安全演示数据

**Files:**
- Create: `design-demo/src/catalog/fixtures.js`
- Create: `design-demo/src/catalog/screens.js`
- Create: `design-demo/src/screens/shared.js`
- Create: `design-demo/tests/screen-registry.test.mjs`

**Interfaces:**
- Consumes: `ScreenDefinition` 字段 `id,module,page,state,theme,title,component,height,tags`。
- Produces: `screens: readonly ScreenDefinition[]`、`getScreen(id): ScreenDefinition`、`createDeviceScreen(definition, content): HTMLElement`。

- [ ] **Step 1: 写失败的页面覆盖测试**

测试显式保存设计规格中的模块/状态清单；断言 ID 唯一、Light 全量、Dark 七个代表页面、393px 宽度、标准高度 `>=852`、标签完整、每个 Dialog/Toast/Action Sheet/异常状态可单独寻址。

- [ ] **Step 2: 确认测试因 Registry 缺失失败**

Run: `Set-Location design-demo; npm test -- tests/screen-registry.test.mjs`  
Expected: FAIL，`ERR_MODULE_NOT_FOUND`。

- [ ] **Step 3: 实现虚构 Fixtures**

Fixtures 使用虚构联系人“林晓”“周然”“畅聊客服 008”、群组“周末徒步群”；CAIBI 示例为字符串 `"1288.50"`，USDT 为 `"320.125000"`，地址使用 `TTest...8Demo`。禁止真实 ID、邮箱、Token、密钥和地址。

- [ ] **Step 4: 实现显式 Registry 与 Scaffold**

每个状态写成稳定对象；`createDeviceScreen` 固定生成 `article.ui-screen > div.ui-device > header.c-status-bar + main.ui-device__viewport + footer.c-home-indicator`，并设置全部 `data-*` 和 `aria-label`。

- [ ] **Step 5: 运行 Registry、资产和品牌测试**

Run: `Set-Location design-demo; npm test -- tests/screen-registry.test.mjs tests/brand-contract.test.mjs tests/source-contract.test.mjs`  
Expected: PASS。

- [ ] **Step 6: 提交 Registry**

```powershell
git add -- design-demo/src/catalog design-demo/src/screens/shared.js design-demo/tests/screen-registry.test.mjs
git commit -m "feat(ui-demo): register complete mobile screen inventory"
```

### Task 5: 实现 Auth、Messages、Chat 与 Calls 画板

**Files:**
- Create: `design-demo/src/screens/auth.js`
- Create: `design-demo/src/screens/messaging.js`
- Create: `design-demo/src/screens/calls.js`
- Modify: `design-demo/src/catalog/screens.js`
- Modify: `design-demo/src/styles/components.css`
- Create: `design-demo/tests/browser-contract.html`

**Interfaces:**
- Consumes: `renderAuthScreen(definition, fixtures)`、`renderMessagingScreen(...)`、`renderCallScreen(...)` 注册回调。
- Produces: 所有认证、消息、聊天、语音、附件、红包消息和呼叫状态的可渲染页面。

- [ ] **Step 1: 在浏览器契约页加入失败断言**

浏览器断言认证/消息/聊天/通话代表 ID 均渲染唯一 `h1`，页面根结构固定，消息 Incoming/Outgoing Signature 相同，Dialog 标题关联，按钮点击区 `>=44×44`。

- [ ] **Step 2: 用 Chrome Headless 确认测试失败**

Run: `node scripts/serve.mjs`，另一个终端执行 Chrome `--headless --dump-dom http://127.0.0.1:4173/tests/browser-contract.html`。  
Expected: DOM 包含 `data-test-result="failed"`，报告未实现 Renderer。

- [ ] **Step 3: 实现 Auth 全状态**

实现沉浸背景、畅聊品牌、登录/注册/验证表单、字段错误、Loading、成功、过期、重发和键盘布局。所有 Error 使用字段关联或表单错误，不展示技术异常。

- [ ] **Step 4: 实现 Messages、Chat 和 Composer 全状态**

实现会话列表、Network Capsule、文本/回复/撤回、Delivery、语音录制与试听、附件权限/超限/进度/失败、红包五态和详情入口。

- [ ] **Step 5: 实现 Calls 全状态**

实现音频/视频呼叫中、来电、连接、弱网、结束、相机/麦克风/镜头、权限、忙线、无人接听、失败和断网。

- [ ] **Step 6: 运行浏览器与 Node 契约**

Run: `Set-Location design-demo; npm test`，再运行 Browser Contract。  
Expected: Node PASS，浏览器 DOM 包含 `data-test-result="passed"`。

- [ ] **Step 7: 提交通信与认证画板**

```powershell
git add -- design-demo
git commit -m "feat(ui-demo): render auth chat and call states"
```

### Task 6: 实现 Contacts、Discovery 与 Moments 画板

**Files:**
- Create: `design-demo/src/screens/contacts.js`
- Create: `design-demo/src/screens/moments.js`
- Modify: `design-demo/src/catalog/screens.js`
- Modify: `design-demo/tests/browser-contract.html`
- Modify: `design-demo/src/styles/components.css`

**Interfaces:**
- Consumes: Contact/Moment Components 和集中 Fixtures。
- Produces: 通讯录、好友、发现、朋友圈、发布、搜索、通知和设置全状态。

- [ ] **Step 1: 加入失败的 Contacts/Moments 浏览器断言**

断言 A–Z 索引、64px 索引浮层、好友请求三态、好友更多项、1/2/4/9 图布局、操作菜单、五种可见性、发布失败重试、离开确认和朋友圈设置均可独立渲染。

- [ ] **Step 2: 确认断言因 Renderer 缺失失败**

Run Browser Contract。  
Expected: `data-test-result="failed"` 并列出缺失 screen ID。

- [ ] **Step 3: 实现 Contacts 与 Friend Profile**

实现通讯录分组、索引、好友请求、群聊/标签/客服、搜索、空/错误、好友主页、创建会话状态、备注/标签/权限/黑名单/删除确认与反馈。

- [ ] **Step 4: 实现 Discovery 与 Moments**

实现发现入口、新内容红点、时间线、媒体网格、互动、可见性、内容治理状态、发布、详情、评论、搜索/筛选、通知和设置。

- [ ] **Step 5: 运行全部契约**

Run: `Set-Location design-demo; npm test`，再运行 Browser Contract。  
Expected: PASS。

- [ ] **Step 6: 提交社交画板**

```powershell
git add -- design-demo
git commit -m "feat(ui-demo): render contacts and moments states"
```

### Task 7: 实现 Profile、CAIBI、Red Packet、Wallet 与 Global Feedback

**Files:**
- Create: `design-demo/src/screens/profile.js`
- Create: `design-demo/src/screens/finance.js`
- Create: `design-demo/src/screens/feedback.js`
- Modify: `design-demo/src/catalog/screens.js`
- Modify: `design-demo/tests/browser-contract.html`
- Modify: `design-demo/src/styles/components.css`

**Interfaces:**
- Consumes: Finance/Feedback Components、定点字符串 Fixtures。
- Produces: 资料、头像、设置、CAIBI、红包、Wallet、Global Feedback 和深色关键画板。

- [ ] **Step 1: 加入失败的资料与金融浏览器断言**

断言畅聊号、头像全状态、退出确认、CAIBI 两位、USDT 六位、红包 Footer、提现未知结果查询原订单、禁止兑换/USDT 转账/USDT 红包、反馈组件和深色关键 ID。

- [ ] **Step 2: 确认测试因页面缺失失败**

Run Browser Contract。  
Expected: `data-test-result="failed"`。

- [ ] **Step 3: 实现 Profile 与 Settings**

实现“我”、资料编辑、头像权限/裁剪/预览/上传/失败/恢复默认、邮箱脱敏、设置和退出状态。

- [ ] **Step 4: 实现 CAIBI 与 Red Packet**

实现余额、记录筛选、转账手续费/确认/处理/错误/未知状态、四种红包创建、校验、领取五态及并发/重复/未知反馈。

- [ ] **Step 5: 实现 USDT Wallet 和 Global Feedback**

实现充值/提现全部状态、地址省略/详情复制、费用、审批、托管、广播、确认、失败退款、未知查询；实现 Dialog、Toast、Empty、权限、离线、服务错误、字号和减少动态效果画板。

- [ ] **Step 6: 实现深色关键画板**

同一 Renderer 通过 `data-theme="dark"` 切换 Token，不复制私有 DOM；登记登录、消息、混合聊天、通讯录、朋友圈、“我”和钱包。

- [ ] **Step 7: 运行全部契约**

Run: `Set-Location design-demo; npm test`，再运行 Browser Contract。  
Expected: PASS。

- [ ] **Step 8: 提交资料与金融画板**

```powershell
git add -- design-demo
git commit -m "feat(ui-demo): render profile finance and feedback states"
```

### Task 8: 实现设计审查画廊、路由和关键交互

**Files:**
- Create: `design-demo/src/app.js`
- Modify: `design-demo/index.html`
- Modify: `design-demo/src/styles/gallery.css`
- Create: `design-demo/scripts/browser-smoke.mjs`
- Modify: `design-demo/package.json`

**Interfaces:**
- Consumes: `screens`、`getScreen`、全部 Renderer。
- Produces: `/?screen=...`、`/?module=...&state=...&theme=...` 路由，筛选、搜索、主题、设备框和交互控制。

- [ ] **Step 1: 写失败的 Headless Browser Smoke**

`browser-smoke.mjs` 启动临时服务器，调用本机 Chrome Headless `--dump-dom`，断言画廊统计、Auth/Wallet 单路由、模块筛选、Dark 路由、零 `data-render-error` 和零旧品牌。

- [ ] **Step 2: 确认 Smoke 因 app.js 缺失行为失败**

Run: `Set-Location design-demo; node scripts/browser-smoke.mjs`  
Expected: FAIL，报告缺失 Gallery 或 Screen Root。

- [ ] **Step 3: 实现画廊与 URL State**

实现 Header、计数、搜索、Module/State/Theme/Length/Errors 筛选、Screen Grid、单画板、设备框开关和复制 ID。URL 是唯一可分享状态，浏览器前进/后退恢复筛选。

- [ ] **Step 4: 实现关键原型交互**

使用 `data-action` 事件委托实现登录→消息、消息→聊天、通讯录→好友、发现→朋友圈、“我”→金融入口，以及 Dialog/Toast/Action Sheet 触发。不得把静态状态从 Registry 移除。

- [ ] **Step 5: 运行 Smoke 与全部测试**

```json
{
  "scripts": {
    "serve": "node scripts/serve.mjs",
    "test": "node --test --test-reporter=spec",
    "test:browser": "node scripts/browser-smoke.mjs",
    "verify": "node scripts/verify.mjs"
  }
}
```

Run: `Set-Location design-demo; npm test; npm run test:browser`  
Expected: PASS。

- [ ] **Step 6: 提交审查画廊**

```powershell
git add -- design-demo
git commit -m "feat(ui-demo): add review gallery and prototype routing"
```

### Task 9: 截图、完整门禁、README 与验证证据

**Files:**
- Create: `design-demo/scripts/screenshots.mjs`
- Create: `design-demo/scripts/verify.mjs`
- Create: `design-demo/README.md`
- Create: `docs/verification/2026-08-16-changliao-html-figma-demo.md`
- Modify: `design-demo/package.json`
- Create: `design-demo/artifacts/screenshots/.gitkeep`

**Interfaces:**
- Consumes: Screen Registry、Chrome Headless、所有测试脚本。
- Produces: 每个正式画板的 PNG、Demo 完整验证命令和 HTML 阶段证据。

- [ ] **Step 1: 写失败的验证聚合器**

`verify.mjs` 顺序运行 Node Tests、Browser Smoke、Registry/截图数量检查；任一步骤非零立即失败。初始因 `screenshots.mjs` 缺失失败。

- [ ] **Step 2: 确认聚合器失败**

Run: `Set-Location design-demo; node scripts/verify.mjs`  
Expected: FAIL，报告 Screenshot 阶段缺失。

- [ ] **Step 3: 实现确定性截图**

`screenshots.mjs` 启动服务器，对每个 Registry ID 调用 Chrome Headless `--window-size=393,{height}` 和 `--screenshot=artifacts/screenshots/{id}@393x{height}.png`；先清理本目录旧 PNG，再断言输出数量等于 Registry 数量。

- [ ] **Step 4: 完成 README 和验证证据初稿**

README 写明启动、测试、筛选路由、类名/DOM/Token 硬规则、资产边界和 Figma 批次。验证文档记录每个 Red/Green 命令、HTML Screen 数量、浏览器结果和截图索引。

- [ ] **Step 5: 运行 Demo 完整门禁**

Run: `Set-Location design-demo; npm run verify`  
Expected: PASS，截图数量与 Registry 一致。

- [ ] **Step 6: 运行仓库完整验证并记录输出**

Run: `pwsh -NoProfile -File scripts/verify.ps1`  
Expected: PASS；若存在与本任务无关的既有失败，原样记录命令、退出码和失败阶段。

- [ ] **Step 7: 提交 HTML Demo 与证据**

```powershell
git add -- design-demo docs/verification/2026-08-16-changliao-html-figma-demo.md
git commit -m "test(ui-demo): verify complete changliao screen gallery"
```

### Task 10: 创建 Figma 文件并分批导入 HTML

**Files:**
- Modify: `docs/verification/2026-08-16-changliao-html-figma-demo.md`

**Interfaces:**
- Consumes: 已通过 `npm run verify` 的本地 URL、Screen Registry、截图和稳定 ID。
- Produces: Figma 文件“畅聊 App UI — HTML Import”、`fileKey`、`99 HTML Capture Reference` 模块批次。

- [ ] **Step 1: 加载 Figma 创建与写入技能并创建空白 Design 文件**

严格先加载 `figma-create-new-file`，创建名为“畅聊 App UI — HTML Import”的 Design 文件并记录 `fileKey`；随后加载 `figma-use`、`figma-generate-design` 和所需 Gotchas。

- [ ] **Step 2: 只读检查空文件和可用字体**

通过只读 Figma 调用列出 Pages、顶级节点、Variables、Components 和可用字体；记录空文件无既有 Design System，因此不搜索或猜测现有组件 Key。

- [ ] **Step 3: 启动稳定本地服务并按模块执行 HTML Capture**

以固定端口启动 `npm run serve`，按 Auth、Messages/Chat、Calls、Contacts/Friend、Discovery/Moments、Me/Profile、Finance、Feedback、Dark 逐批捕获到同一个 `fileKey`。含 `landing.png` 和演示图片的批次必须通过 HTML Capture 带入图像。

- [ ] **Step 4: 每批核对 Capture**

每批读取元数据并截图，记录 Frame 数、名称、393px 宽度、资源、文本裁切和顶级位置；错误批次修复 HTML 后重新运行门禁，不在错误捕获上继续。

- [ ] **Step 5: 提交 Figma Capture 证据**

在验证文档记录 `fileKey`、文件链接、批次、HTML 数量、Capture Frame 数量和修正结果。

### Task 11: 建立 Figma Variables、Styles、Components 与正式页面

**Files:**
- Modify: `docs/verification/2026-08-16-changliao-html-figma-demo.md`

**Interfaces:**
- Consumes: 同一 Figma 文件的 HTML Capture、组件映射、Token 和图像 Hash。
- Produces: 00–90 正式 Pages、Light/Dark Variables、Text/Effect Styles、Components/Variants、Auto Layout 页面实例。

- [ ] **Step 1: 创建 00–04 Foundations 和 Components 骨架**

使用增量 `use_figma` 调用创建 Pages、Color Variables Light/Dark Modes、Spacing/Radius/Size Variables、Text Styles 和 Effect Styles；每次最多 10 个逻辑操作并返回全部节点/变量 ID。

- [ ] **Step 2: 创建组件及 Variant**

按固定映射创建 Actions、Lists、Identity、Chat、Finance、Feedback、Overlay、Moments 组件；Variant 属性使用 Theme、State、Kind、Direction、Status。每组完成后元数据和截图验证。

- [ ] **Step 3: 按页面批次建立正式 Auto Layout Frame**

创建 10–90 Pages，使用组件实例和变量绑定组合页面；从 HTML Capture 复制必要图片 Hash。顶级节点放置到非重叠位置，画板宽度固定 393，长页高度匹配 HTML。

- [ ] **Step 4: 逐批对齐 HTML Capture**

并排截图检查间距、字体、尺寸、气泡方向、红包 `236×96`、安全区、Overlay 和深色 Token；只做目标修正，不重建正确节点。

- [ ] **Step 5: 完成 Figma 数量与结构对账**

断言正式 Frame 数等于 Registry 对应数量；检查 Variables、Styles、Component Instances、Auto Layout、无裁切、无重叠、无 Placeholder/Shimmer、无旧品牌可见文本。

- [ ] **Step 6: 隐藏并锁定 Capture Reference**

将 `99 HTML Capture Reference` 隐藏并锁定，保留为像素审查来源；不删除正式页面所引用的图像资源。

### Task 12: 最终规格符合性、质量和交付

**Files:**
- Modify: `docs/verification/2026-08-16-changliao-html-figma-demo.md`

**Interfaces:**
- Consumes: HTML/Figma 完整交付物和验证结果。
- Produces: 最终可复核证据、Figma 链接和干净工作区。

- [ ] **Step 1: 规格符合性审查**

逐条对照设计规格第 3–9 节，将每条要求映射到 Screen ID、测试或 Figma Page；修复任何缺口。

- [ ] **Step 2: 质量与安全审查**

扫描旧品牌、私有样式、外链、真实凭据/地址、消息正文日志、浮点资产、兑换/USDT 转账/红包入口、缺失 ARIA、裁切和未绑定组件。

- [ ] **Step 3: 最终运行 Demo 和仓库验证**

Run: `Set-Location design-demo; npm run verify`  
Run: `Set-Location ..; pwsh -NoProfile -File scripts/verify.ps1`  
Expected: 两者 PASS，或仓库既有失败已在证据中完整记录。

- [ ] **Step 4: 最终记录与提交**

验证文档写入最终 Screen/Frame 数、Figma 文件标识与链接、导入批次、结构/视觉复核、命令和退出码。

```powershell
git add -- docs/verification/2026-08-16-changliao-html-figma-demo.md
git commit -m "docs(verification): record changliao html figma acceptance"
git status --short
```

- [ ] **Step 5: 交付**

向用户提供 HTML Demo 启动命令、Figma 文件链接、Screen/Frame 数量、验证摘要和任何已明确记录的环境差异。

### Task 13: 修复认证页可发现性并建立完整图标系统

**Files:** `design-demo/src/icons/icons.js`、认证/组件样式、画板注册表、测试、Figma 状态台账和验证证据。

- [x] **Step 1: 复现缺口并确认根因**

确认 Auth 的 24 个状态完整保留在原有 `10 Auth` 页面；确认图标实现使用 Unicode 占位字形，导致导航与通话控件显示为圆点或字符。

- [x] **Step 2: 先写失败测试**

增加真实 SVG 图标数量、关键业务图标、可编辑几何、登录/注册完整表单、主导航四图标、语音通话图标及 `foundation-icons-catalog` 画板契约。

- [x] **Step 3: 实现 HTML SVG 图标注册表与图标画板**

使用 58 个本地 SVG 描边定义替换全部 Unicode 占位字形；保持 Light DOM、`currentColor`、稳定 `data-icon` 和原有组件 DOM 层级，并增加 393×1440 图标库画板。

- [x] **Step 4: 创建 Figma 图标库与认证快速审查页**

创建 `05 Icons 图标库`、58 个真实 Component、主导航/语音通话实例预览；认证画板统一保留在原有 `10 Auth` 页面，不建立重复页面。

- [x] **Step 5: 完整验证、记录证据并提交**
