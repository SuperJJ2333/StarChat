# 后台可读性与交互优化验收 — 2026-09-10

按 `docs/superpowers/plans/2026-09-10-admin-readability.md` 和用户七项要求实现。用户明确允许先完成后台优化、暂缓 Figma 同步。没有生产操作，没有声称同步远程 Figma。浏览器截图中的账号、交易与金额均为合成验收数据。

## 交付

原 LOGO 的字节副本用于侧栏、登录页及 favicon。侧栏支持边缘拖动、200–360px 限制、键盘调宽、偏好保存、边缘收起/展开与手机抽屉。概览调整为趋势在总量之前，发行记录默认展示，凭证改为原生模态卡片。记录的操作人关联畅聊号，原因中文化，金额保持精确字符串。

安全页顶部表单采用中文原因和时长菜单；用户通过列表选择，提交仍使用内部 ID。用户与注册明细均支持用户名/畅聊号/邮箱查询、服务端稳定游标分页，显示实际注册时间、畅聊号、昵称、邮箱验证与账号状态。其他模块按显式字段映射，绝对时间及时间筛选统一北京时间；自然日统计保留日期语义。

## 测试证据

- 初始格式测试因缺少公共格式模块失败；浏览器默认记录测试因原页面未自动展示记录失败。原始输出：`artifacts/2026-09-10/admin-readability/format-red.txt`、`browser-red.txt`。
- 后端代理新增查询与 actor 关联测试先 red 后 green；根任务最终复测该文件 **21 passed**，见 `backend-final.txt`。权限、字面量搜索、游标筛选绑定、边界与安全投影有断言。
- 前端最终 **129 passed / 0 failed / 0 skipped**，见 `frontend-tests.txt`。包含格式、API兼容、表单重复提交、请求失败与搜索/分页竞态。
- Chrome 实际渲染和交互脚本 `verify_browser.py` 通过：1440×1100、390×844；浏览器时区 America/Los_Angeles。验证原标识加载、概览顺序、默认记录、非中国时区下的北京时间、拖动/键盘/收起、原生弹窗及 Escape 焦点返回、手机抽屉、无页面横向溢出、用户查询与翻页、失败时保留列表及表单、注册列语义。使用真实页面模块配合合成 API，不是生产端到端测试。
- 全仓 `pwsh -NoProfile -File scripts/verify.ps1` **Verification: PASS**，见 `full-verify.txt`：infra 118、Getui 28、Matrix bot 9、API/worker 1492、mobile 67 passed；OpenAPI、迁移、UI契约、AST及部署策略通过。该全仓运行后仅有审查收尾修复，相关前后端与浏览器已再次验证。
- 全仓 API/worker 中 36 项按原有条件跳过（未配置隔离 PostgreSQL/特定跨进程环境），不作为已执行的容器证明。原有第三方 Starlette/httpx 与 Pydantic Config 弃用警告仍记录在全仓日志，本次未变更这些依赖。
- OpenAPI 重新导出，UI契约验证通过（17 components / 330 screens）。旧前端注册表测试仍断言已退役 Figma ledger，已与现有 `verify_ui_contract.py` 的真实契约对齐；未虚构同步记录。登录测试由“第一张图片是验证码”改为按验证码类定位，以保留其真正断言。

## 顺序审查及修复

先规格审查，再质量/安全审查。规格审查要求自然日表格不补虚构午夜，已修复。质量审查发现并修复：用户分页/搜索失败提交状态错位；凭证筛选失败混用旧游标；ESM 会话导入 URL 不一致；极端游标时区转换 OverflowError。后者新增六项边界测试，修复前四项实际返回500失败，修复后返回422。没有修改金融状态转换、账本写入、鉴权规则或幂等边界。

原有链上 offset 列表存在请求失败后页状态变更问题，独立审查已记录；本次该模块仅更改时间显示和解析，不声称修复这一既存分页行为。

## 视觉材料

- `artifacts/2026-09-10/admin-readability/overview-desktop.png`
- `artifacts/2026-09-10/admin-readability/overview-mobile.png`
- `artifacts/2026-09-10/admin-readability/proof-desktop.png`
- `artifacts/2026-09-10/admin-readability/users-desktop.png`
- `artifacts/2026-09-10/admin-readability/users-mobile.png`

根任务已查看弹窗、桌面用户页及手机用户页截图；桌面表单同排，手机表单纵排，表格在容器内横向滚动。临时 `users/chrome-profile` 的清理命令被自动审批检查拒绝，理由只有“blocked by policy”；未绕过，目录保留于本验收目录，勿作为发布内容。

追加记录：用户随后明确授权生产部署，已完成。上线证据见 `2026-09-10-admin-readability-production.md`；上文“本地实现”描述为部署前验收范围。
