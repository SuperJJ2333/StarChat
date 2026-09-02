# 前端静态 Demo（frontend）

管理系统前端、登录页、畅聊 Landing 宣传页与可审查的移动端 UI 原型均位于本目录。文本文件统一使用 UTF-8。

```powershell
Set-Location frontend
npm run serve
```

- 静态总览：`http://127.0.0.1:4173/demo.html`
- 管理台与登录页：`http://127.0.0.1:4173/admin.html`
- Landing：`http://127.0.0.1:4173/home.html`
- 移动端 UI 画板：`http://127.0.0.1:4173/`

运行静态测试：`npm test`。

后端管理 API 位于仓库根目录的 `backend/`，前端通过 `?apiBase=<API 基地址>` 连接它；不传该参数时使用同源 `/api/v1`。
