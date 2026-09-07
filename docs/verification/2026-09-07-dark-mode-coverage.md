# 深色模式覆盖修复 — 2026-09-07

## 修复与原因

根因是公共导航和主页面被旧规范固定为浅色，以及自绘 Container/TextStyle 未解析 CupertinoDynamicColor。主题选择和持久化原先已实现，本次修复颜色消费路径。

- 导航 #191919、页面 #111111、卡片/输入 #232323、正文 #F5F5F5、分隔线 #2C2C2C。
- 修复消息/通讯录/发现/我四个主入口以及聊天信息、搜索、好友资料/标签、朋友圈时间线/发布/可见范围、群页面、统计/红包、通知诊断等使用固定浅色的页面。
- 修复共享联系人行、朋友圈卡片、消息/通话/附件气泡、网络提示、认证错误提示、转发/搜索面板。
- 已有主题支持的登录/钱包等继续使用其主题分支。钱包业务、推送、iOS 同期改动不包含在本次提交。
- Android 头像裁剪器使用打开时主题快照；在原生选择器 await 前读取，避免退出页面后访问失效 context。原生系统相册自身的主题仍由系统/插件控制。
- 照片、GIF、视频、二维码以及绿色发送气泡保留自身颜色。二维码保留白底黑码；发送气泡保持黑字，接收气泡深底亮字。

## 自动化与审查

- Flutter 全量：1319 PASS；flutter analyze：No issues found。
- HTML：38 PASS；移动边界：65 PASS；UI contract drift：PASS。
- 保留真实 RED/GREEN：公共导航/标题、通讯录文字、朋友圈卡片、通话气泡、网络提示、发布/可见范围页面与认证错误提示。
- 补充邀请栏、未选中好友标签、发布页导航层级与头像生命周期回归。最后人工代码审阅发现发送文件卡片继承绿色气泡黑字、落到自身深色背景；以真实 outgoing attachment widget 写 RED 后给卡片独立主题字色，纳入最终回归。
- 规格审查发现群邀请白条、好友标签黑字、发布页导航层级问题，已修复；随后质量审查发现裁剪器 await 后读取已卸载 context，已改为之前读取。当前调用路径未发现二次解析反色。
- `pwsh -NoProfile -File scripts/verify.ps1`：Verification PASS。包含后端 1133 PASS / 31 SKIP、移动边界 65 PASS、迁移、OpenAPI 与 Compose 检查；1 条既有 Starlette 弃用警告。

## UI / Figma 证据与限制

- HTML 通讯录与朋友圈 dark 预览截图已经生成并目视检查（仅假数据设计预览，不冒充 Flutter 或手机截图）。
- Flutter 真实 widget 测试验证浅→深→浅时导航、背景和文字重绘；ThemeController 原有测试验证显式模式持久化、跟随系统解析与保存失败回退。
- 未声称 Android/iOS 每个路由均已真人逐页验收；未构建或替换线上 APK。
- Figma 远程同步 Deferred：当前未提供可调用连接。已更新本地登记，remoteNodesModified=false，未声称远程设计完成。
- 既有节点：[Foundations](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78?node-id=18-4)、[Contacts](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78?node-id=19-3)、[Moments](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78?node-id=19-4)。

## 真人验收步骤

1. 在设置依次切换浅色→深色→浅色，无需重启；主导航栏/背景/列表字色应立即切换。
2. 深色进入消息、通讯录、发现、我及朋友圈；无浅色导航、白色列表大片残留或黑底黑字。
3. 打开好友资料/标签、查找记录/成员、群资料、朋友圈发表/权限、邀请提示、红包表单和通知诊断；检查输入、空态、错误态及返回动画。
4. 查看收发文字/通话/文件气泡：接收深底亮字，发送绿色黑字；图片原色及二维码可读。
5. 选择跟随系统，切换系统主题；重新启动确认偏好保留。原生相册/裁剪器需 Android/iOS 设备分别验收。

证据目录：`docs/verification/artifacts/2026-09-07/dark-mode/`。包含逐页扫描、RED/GREEN日志、独立检查结果与HTML截图。
