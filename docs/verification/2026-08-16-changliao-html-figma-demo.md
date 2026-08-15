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
| 浏览器渲染 | 捕获路由仍带审查页返回按钮 | `capture=1` 只输出单一画板且无外层控件 |
| 验证汇总 | `screenshots.mjs` 尚不存在 | 每个 Screen ID 均生成尺寸匹配的 PNG |

## 自动化结果

### HTML Demo 单元与契约测试

命令：`npm test`

- 12/12 通过。
- 覆盖品牌、内部技术标识保留、Token 对称、样式层顺序、禁止 Shadow DOM/内联样式/私有样式、组件契约、画板注册表、财务精度字符串与禁止能力。

### 浏览器烟雾测试

命令：`npm run test:browser`

- 通过。
- 验证设计画廊、模块筛选、错误状态筛选、浅/深独立页面、点击路由基础、无渲染错误及无用户可见旧品牌文本。

### 全量浏览器渲染契约

页面：`tests/browser-contract.html`

- 325 个画板全部构建成功。
- 页面标记：`data-test-result="passed"`、`data-screen-count="325"`。

### 确定性截图

命令：`npm run screenshots`

- 生成 325/325 张 PNG。
- 每张图片验证 PNG 签名、393px 宽度及注册表声明高度。
- 总体积约 7.48 MiB。
- 登录背景位图已检查并替换为用户可见“畅聊”。

### 仓库基线验证

命令：`pwsh -NoProfile -File scripts/verify.ps1`

- HTML Demo 开发前基线通过。
- HTML Demo 与 325 张截图生成完成后的全仓验证通过：Repository/Deployment/Template/Render/Migrations/OpenAPI/Docker 均通过；Matrix Bot 9 项、Business API/Worker 161 项（1 项跳过）、Flutter 边界 9 项通过。

## 人工视觉抽查

- `auth-login-default.png`：浅色登录、品牌位图与表单层级正确。
- `moments-timeline-default.png`：朋友圈长内容保持 393px 固定宽度并自然增高。
- `wallet-home-default-dark.png`：深色 Token 切换、USDT 六位小数与钱包层级正确。

## 待完成交付

- Figma Foundations 与浅/深变量集合。
- 组件目录与变体映射。
- 325 个独立 Figma Frame。
- 关键流程原型连线与最终 Figma 链接/节点证据。
