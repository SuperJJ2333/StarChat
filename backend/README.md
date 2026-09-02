# 管理系统后端（backend）

FastAPI 管理与业务 API 位于本目录。前端静态资源位于仓库根目录 `frontend/`。

```powershell
$env:PYTHONUTF8='1'
$env:PYTHONIOENCODING='utf-8'
Set-Location backend
py -3.12 -m uvicorn app.main:create_default_app --factory --host 127.0.0.1 --port 8082
```

管理端 API 使用 `/api/v1` 前缀；管理员角色直接执行管理写操作，服务端仍保留 RBAC、幂等键、审计与 Outbox。
