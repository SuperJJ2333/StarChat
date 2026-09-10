# 后台可读性与交互优化实施计划

按用户七项明确要求执行；用户已允许本次暂缓 Figma，同步以真实页面截图和功能测试验收。使用 subagent-driven-development，先失败测试，再实现，先规格复核再质量安全复核。此次请求为优化实现，不自动延续上一任务的钱包生产发布范围。

## 设计

复用用户 LOGO.png 原图作为管理台与标签页标识，不生成替代图。侧栏保留现有导航层级，右边缘拖动调整 200–360px，边缘图标收起/展开，键盘方向键亦可调整；移动端保持抽屉、遮罩与 Escape。

运营概览顺序改为指标、注册趋势、点钻总量、默认显示的发行与回收记录。凭证用可滚动模态卡片，具关闭、Escape、焦点管理及加载/错误状态；金额字符串保持精确，不引入浮点资产计算。

后台统一格式化绝对时间为 Asia/Shanghai 的 YYYY-MM-DD HH:mm:ss；空值显示“—”，时间范围输入按北京时间解析。按日聚合趋势仍明确是自然日人数，不伪装成某个用户的注册时刻。

用户列表改为明确字段。已有 analytics 实际返回用户明细，旧“主渠道/验证率”表头没有相应数据，因此改成“注册时间/畅聊号/用户名/邮箱验证/账号状态”。security 顶部单行表单使用中文类型、原因、时长选择，随后显示支持服务端搜索/分页的用户列表。用户选择后提交其内部 ID，不能把昵称猜作唯一用户。宽屏单行，小屏提供横向容纳或合理换行，不挤破页面。

其他模块按真实数据键显式映射，避免 Object.values 错位、UUID 当畅聊号、英文状态及原始时间。仅增加只读字段/分页参数，保留原权限、金融事实、封禁规则、审计与幂等接口。

## 文件归属与任务

- 根协调者：frontend/src/admin-dashboard.js、新 admin-formatters.js、新 admin-sidebar.js、新 admin-proof-dialog.js；styles/admin-modern.css、admin.html、标识文件、相关浏览器与格式测试；计划与验证文档。
- 后端代理：api/admin.py、admin_report_contracts.py、新 modules/admin/user_reports.py、ledger/supply_reports.py 只读 actor 展示关联；新增测试。增加模块搜索/分页及 actor_username/actor_display_name，不变更 ledger 写入或 RBAC。
- 列表代理：frontend/src/admin-home.js、admin-api.js、admin-presenters.js、新 admin-user-panel.js、新 styles/admin-users.css 及相关测试。消费根协调者的 formatBeijingTime/reasonLabel/statusLabel；后台接口分页需和后端协商。
- 时间复核代理：admin-chain-panel.js、admin-manual-wallet-panel.js、wallet-incident-workflow.js 及其测试。仅调整显示与时间输入，保留财务命令及恢复流程。

## 验收

各任务 red/green；真实浏览器覆盖 LOGO、侧栏拖动/键盘/收起、默认记录、弹窗关闭/焦点、分页/搜索竞态、表单选项与真实请求字段、时间转换、加载/空态/失败。用户搜索涵盖用户名/畅聊号/邮箱，验证未授权访问被拒绝。运行前端测试、后端相关测试、OpenAPI/契约更新与 scripts/verify.ps1。记录 Figma 经用户批准暂缓；不伪造 Figma URL 或账本。

## 生产发布追加授权（2026-09-10）

用户明确要求按 app-release-deployment.md 部署本次后台优化。限定 4 个 API 只读报表文件和 17 个静态文件；候选 API 从当前钱包修复镜像派生。冻结实际 API 配置，Worker 和其他容器不重建。SHA256 上传校验、静态备份与漂移检查、数据库备份及独立断网恢复、候选/回退 create-only 比对和导入验证通过后再切换。切换后检查实际模块哈希、JSON健康/401、公网静态哈希、登录页渲染及无关容器一致；失败使用本次冻结配置回退，不恢复生产数据库。
