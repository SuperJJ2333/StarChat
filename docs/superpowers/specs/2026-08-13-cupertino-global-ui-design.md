# 六合通 Cupertino 全局界面设计规格

**状态：已批准**  
**日期：2026-08-13**  
**范围：** Flutter Android/iOS 客户端全局 Cupertino 视觉、登录页、主导航、品牌图标与启动图。

## 设计原则

- Android 和 iOS 使用同一套 Cupertino 视觉，不按平台分裂界面。
- 现有业务 API、Matrix E2EE、钱包、Token、恢复密钥和审计边界不变。
- 使用 `CupertinoApp`、`CupertinoPageScaffold`、`CupertinoNavigationBar`、`CupertinoTabScaffold`、`CupertinoTabBar`、`CupertinoTextField`、`CupertinoButton`、`CupertinoFormSection` 等组件。
- 使用 Apple Design 的响应优先、可中断、克制动效、层次和无障碍原则。

## 信息架构

登录页是未认证入口；登录成功后进入 Cupertino Tab 主导航：彩币、红包、钱包。页面通过已有 `BusinessApiClient` 查询业务状态，Matrix 登录/同步由现有组合层处理。

## 登录页

- 品牌图标、六合通标题和简短安全说明。
- Cupertino 输入框，用户名/密码、密码显隐、键盘避让。
- 按下即时反馈、加载状态、错误提示和空值校验。
- 登录按钮采用无障碍最小点击区域。
- 使用淡入/上移的克制进入动效；支持 `MediaQuery.disableAnimations`。

## 主导航

- `CupertinoTabScaffold` + `CupertinoTabBar`。
- 半透明底部栏、系统安全区、选中状态和轻量 tab 过渡。
- 页面标题使用 Cupertino 导航栏。
- 不改变业务页面的数据和 API 调用。

## 品牌资产

- 创建六合通蓝紫渐变几何图标 SVG/PNG 资源。
- Android launcher 与 Flutter 启动页使用统一品牌色。
- 不使用受版权保护的 Apple 图标；系统 Cupertino 图标仅用于控件语义。

## 验收

- Flutter analyze/test 通过。
- 两个雷电模拟器可安装并显示 Cupertino 登录页。
- 登录页空值校验、错误状态和主导航 Tab 可测试。
- 不记录或上传密码、Token、恢复密钥和消息正文。
