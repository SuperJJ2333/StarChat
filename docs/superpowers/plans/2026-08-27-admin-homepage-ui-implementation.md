# 六合通后台与首页 UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在现有 design-demo 中实现可运行的六合通后台管理 Dashboard 与响应式网站首页视觉原型，覆盖 9 个模块入口、关键数据视图和核心交互。

**Architecture:** 复用 design-demo 的 Vite 静态原型结构，以单页 React/TypeScript（若当前为静态 HTML 则保持其技术栈）建立设计 Token、应用壳层、Dashboard、模块列表和官网首页。数据使用本地 fixture，所有写操作以幂等键和审计字段模拟，确保后续可替换 OpenAPI 客户端。

**Tech Stack:** 现有 design-demo 技术栈、CSS variables、Lucide 图标（或现有图标方案）、响应式 CSS、现有测试工具。

---

### Task 1: 建立实现基线与失败测试
**Files:** `design-demo/tests/admin-homepage.spec.*`、`design-demo/src/*`（按现有结构）
- [ ] 写测试断言应用包含侧栏导航、9 个模块名称、首页 Hero 和公告区。
- [ ] 运行测试确认因缺少实现而失败。
- [ ] 记录命令与失败输出到 `docs/verification/artifacts/2026-08-27/admin-homepage-ui-design/`。

### Task 2: 设计 Token 与应用壳层
**Files:** `design-demo/src/styles/tokens.css`、`design-demo/src/App.*`、`design-demo/src/components/AppShell.*`
- [ ] 实现品牌色、语义色、字体、间距、断点 Token。
- [ ] 实现 248px 可收缩侧栏、顶栏、面包屑、全局搜索、通知和管理员菜单。
- [ ] 侧栏移动端变为汉堡抽屉，所有图标按钮提供 aria-label。

### Task 3: 后台概览与 9 个模块页面
**Files:** `design-demo/src/pages/admin/*`、`design-demo/src/data/adminFixtures.*`
- [ ] 实现 KPI 卡、注册趋势图、在线客服列表、待审核队列、审计事件。
- [ ] 实现发点钻、封禁、客服角色、用户统计、在线客户、原生广告、通知公告、点钻流水、USDT 提现页面的统一筛选/表格/抽屉状态。
- [ ] 敏感操作显示 TOTP/二次确认模拟、幂等键、原因码和审计链接；金额使用字符串格式化为 2/6 位小数。

### Task 4: 官网首页
**Files:** `design-demo/src/pages/home/*`, `design-demo/src/components/home/*`
- [ ] 实现深墨绿 Hero、产品能力卡、公开统计、公告中心、安全说明、下载 CTA、页脚。
- [ ] 提供 1440/1024/768/375 响应式布局与 reduced-motion。

### Task 5: 验证与文档
**Files:** `docs/verification/2026-08-27-admin-homepage-ui-implementation.md`
- [ ] 运行 lint/typecheck/unit/build（按项目可用脚本）。
- [ ] 执行页面结构断言与响应式 smoke test。
- [ ] 记录 BASELINE/MODIFIED/ROLLBACK 命令、输出、状态，并保留回滚脚本与修改副本。

