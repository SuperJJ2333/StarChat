# 2026-08-29 登录邮箱化与转账完善及深色模式修复计划

## 需求

1. 支持邮箱登录（后端目前只匹配畅聊号）；邮箱格式校验正确、错误提示清晰。
2. 聊天「更多」面板转账入口完善：进入转账页可选择收款人（指定特定用户）、输入金额、确认转账，交互参照微信。
3. 红包/转账金额输入规则：最多两位小数、必须大于 0，非法输入给出明确提示。
4. 删除「我」页面的「红包」入口与页面，清理引用。
5. 重设计「点钻」「钱包」页面：微信风格，遵循 `UI_DESIGN.md`（Token 化用色、字号/间距/圆角、主按钮规范），深浅色自适应。
6. 深色模式：跟随系统自动切换；非固定页面背景/导航栏/文字正确适配；切换无残留。私聊/群聊页与四个主导航根页维持 `UI_DESIGN.md` 2.1 的固定色值约束。

## 方案要点

- 后端 `/auth/login`：`username` 字段升级为「账号标识」——含 `@` 时按 `email_normalized` 匹配，否则按 `username_normalized`；错误文案改为「账号或密码错误」。请求 schema 不变（向后兼容，OpenAPI 无需变更）。
- 登录页：含 `@` 输入做邮箱正则校验（`请输入正确的邮箱地址`），空输入提示更新。
- 金额：新增共享校验 `parseAmount`（正则 `^(0|[1-9]\d*)(\.\d{1,2})?$` 且 >0）+ `TwoDecimalAmountFormatter` 输入过滤；红包总额、转账金额、点钻转出接入，错误文案：「金额最多支持两位小数」「金额必须大于0」。
- 转账页：`转账给` 行可点开收款人选择器（通讯录，排除自己）；单聊预选当前好友；群聊必须选择；转账前弹确认对话框（收款人/金额/手续费）；「更多」面板转账入口对单聊与群聊均可见。
- 「我」页：移除红包入口；删除 `redpacket_page.dart` 与 `app_home` 跳转。
- 点钻/钱包页：按 Token 重写（页面底色自适应、卡片 `elevatedSurface`、余额 `display 28sp`、列表单元 ≥56dp、主按钮 ModernActionButton），移除硬编码颜色与红包提示瓦片。
- 深色模式：`LiuhetongApp` 增加 `WidgetsBindingObserver.didChangePlatformBrightness` 触发重建；`WeChatTheme.barBackgroundColor` → `surfacePrimary` 亮暗对（#F7F7F7/#191919）；`navTitleTextStyle` 亮暗对；`WeChatPageScaffold` 默认背景改为主题 `scaffoldBackgroundColor`；固定色页面（chat/tab 根页）已显式传色不受影响，其导航标题补固定深色样式保证可读；`app_home` 非固定子页移除写死的 `chatNavigationBackground`。

## 验证

- 后端 pytest（登录邮箱用例）；`flutter analyze/test`；`scripts/verify.ps1`；OpenAPI 无 schema 变化（登录字段不变）。
- 版本 `0.3.0+3`；构建 APK 装双模拟器；后端 identity 变更部署服务器并冒烟。
- design-demo（=frontend）：同步「我」页移除红包入口（屏幕总数不变）。
