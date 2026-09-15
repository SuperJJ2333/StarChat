# 2026-09-15 下载页/首页 iOS 版本标签更新为 0.3.92/2120

## 现象

用户反馈“官方还是显示 iOS 0.3.81/2085”。App 内更新弹窗链路（manifest + app_ios_* 设置）
已是 0.3.92/2120；未更新的是**官网静态页面**的硬编码版本标签：
`frontend/download.html`（版本行 + 电脑端 IPA 链接）与 `frontend/src/admin-home.js`
（首页 iOS 按钮标签×2 + 下载说明）——此前 2117 发布只换了 manifest 与设置，静态标签漏更。

## 修复（commit 本记录）

- download.html：版本行 `0.3.92（2120）· 60 MB`；电脑端 IPA 链接改为
  `ChatFlow-0.3.92-2120-enterprise-e8e63a58.ipa`；download-redirect 缓存参数 v=2120。
- admin-home.js：首页 iOS 按钮标签、aria-label、下载说明三处 → 0.3.92（2120）。
- 回归测试 `home-ios-download.test.mjs` 期望同步更新到 0.3.92（2120）；frontend 全量
  209 项中该用例通过（其余失败为此前已存在的无关用例，与本改动无关）。

## 同步与验证

- 服务器侧：先备份 `download.html.bak-20260915` 与 `src/admin-home.js.bak-20260915`，
  再经跳板上传覆盖；服务器文件 sha256 与本地一致。
- 公网验证：`/download` 显示 `0.3.92（2120）` 与 `e8e63a58` IPA 链接；
  `/src/admin-home.js` 服务内容含 3 处 `0.3.92（2120）`；
  `manifest.plist` 仍指向 2120（未受影响）。

## 待办

- 把“发布时同步更新下载页/首页标签”加入 release checklist（避免再漏）。
