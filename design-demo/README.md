# 畅聊 HTML 设计审查 Demo

本目录把 `UI_DESIGN.md` 的移动端规格展开为可审查、可点击、可批量导入 Figma 的静态 HTML。所有画板以 iPhone 15 的 `393px` 宽度为基准，`1 CSS px = 1 Figma px`；超长页面由屏幕注册表声明自然高度。

## 本地运行

环境要求：Node.js 24+，以及本机 Chrome 或 Edge（浏览器测试与截图使用）。项目没有第三方运行时依赖。

```powershell
cd design-demo
npm run serve
```

默认地址为 `http://127.0.0.1:4173/`。

常用审查链接：

- 全部画板：`/`
- 登录模块：`/?module=auth`
- 钱包异常：`/?module=wallet&state=error`
- 深色代表页面：`/?theme=dark`
- 独立画板：`/?screen=wallet-withdrawal-unknown-result`
- 无审查外壳的捕获路由：`/?screen=wallet-withdrawal-unknown-result&capture=1`

## 硬性结构规则

1. 画板根节点固定为 `article.ui-screen`，且包含稳定的 `data-screen-id/module/page/state/theme`。
2. `article.ui-screen` 的唯一直接子节点是 `div.ui-device`；设备内部按 `header.c-status-bar`、`main.ui-device__viewport`、`footer.c-home-indicator` 排列。
3. 页面类使用 `p-*`，组件类使用 `c-*`，审查外壳使用 `ui-*`；禁止私有样式、Shadow DOM、内联样式和 `!important`。
4. 所有颜色、尺寸、字阶、圆角、阴影和动效均来自 `src/styles/tokens.css`，浅色与深色共享相同语义键。
5. 组件由 `src/catalog/contracts.js` 声明严格 DOM 签名，画板由 `src/catalog/screens.js` 以唯一 ID 注册。
6. 用户可见品牌统一为“畅聊”“畅聊号”“畅聊朋友圈”“畅聊彩币红包”；内部技术标识与资产代码保持不变。

## 验证与截图

```powershell
npm test
npm run test:browser
npm run screenshots
npm run verify
```

`npm run screenshots` 会为注册表中的每个状态生成一张精确尺寸 PNG，写入 `artifacts/screenshots/`。已存在且 PNG 签名、宽度、高度均匹配的文件会安全复用；不匹配的文件会重新生成。

## HTML → Figma 交付数据流

1. `src/catalog/screens.js` 是画板清单的唯一事实来源。
2. `?screen=<id>&capture=1` 输出没有画廊控制条的单一画板 DOM。
3. `artifacts/screenshots/<id>.png` 为逐状态视觉基准与位图兜底。
4. Figma 中每个注册 ID 对应一个独立 Frame，Frame 名称保持与 `screen.id` 一致。
5. Foundations、组件目录、9 个深色代表画板及全部浅色状态分别进入对应 Figma Page；原型连线使用 HTML 的 `data-action` 路由映射作为依据。

## 目录

- `src/styles/`：Reset、Token、Primitive、Component、Gallery 五层样式。
- `src/components/`：严格 Light DOM Web Components。
- `src/screens/`：按产品模块拆分的页面渲染器。
- `src/catalog/`：组件契约、虚拟数据、完整画板注册表。
- `tests/`：品牌、Token、源码、组件、注册表与浏览器契约测试。
- `scripts/`：静态服务器、浏览器烟测、确定性截图和验证汇总。
- `artifacts/screenshots/`：HTML → Figma 的 325 张独立画板视觉基准。
