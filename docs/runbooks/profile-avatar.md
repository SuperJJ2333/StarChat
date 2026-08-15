# 个人资料头像存储运行手册

## 存储边界

- 头像原文件只写入 `BUSINESS_AVATAR_STORAGE_ROOT` 指向的私有目录；该目录不得由反向代理直接公开。
- Compose 默认把宿主机 `./data/business-media` 挂载到容器 `/data/private-media`。
- API 响应不返回对象键，只返回由 `BUSINESS_AVATAR_URL_SIGNING_SECRET` 签发、有效期固定为 300 秒的读取 URL。
- 生产环境必须设置独立的高熵签名密钥；轮换密钥会立即使旧 URL 失效，但不会删除头像对象。

## 配置

```dotenv
BUSINESS_AVATAR_STORAGE_ROOT=/data/private-media
BUSINESS_AVATAR_URL_SIGNING_SECRET=<独立高熵密钥>
BUSINESS_AVATAR_PUBLIC_BASE_URL=https://api.example.com
```

## 备份与恢复

数据库中的 `users.avatar_object_key` 与私有对象目录必须作为同一恢复点备份。恢复后抽查：

1. `GET /api/v1/profile/me` 不包含对象键；
2. 返回的头像 URL 带 `expires_in=300`；
3. URL 超时或篡改后返回 404；
4. 删除头像后对象和数据库引用均不可再读。

上传会话保存在 `avatar_uploads` 表中。清理任务只能删除已过期且非 `COMPLETED` 的对象，不得删除仍被 `users.avatar_object_key` 引用的对象。
