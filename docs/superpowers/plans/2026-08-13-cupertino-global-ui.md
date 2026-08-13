# Cupertino 全局 UI 实施计划

1. 先增加登录页与主导航的 widget 测试，覆盖空值校验、错误态、Tab 切换。
2. 引入 CupertinoApp 和主题 tokens，保留现有登录业务回调及页面 API。
3. 改造登录页为 Cupertino 组件，加入 reduced-motion 兼容的进入动效。
4. 改造主导航为 CupertinoTabScaffold/CupertinoTabBar，接入现有三页。
5. 创建六合通品牌 SVG/PNG，配置 Android 启动背景和 launcher 资源。
6. 运行 analyze、test、APK 构建和两个雷电模拟器安装/UI smoke test。
7. 记录验证证据并提交主分支。
