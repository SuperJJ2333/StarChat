# 服务端四功能配套字段/接口部署记录（2026-09-12）

范围：仅业务 API 两个文件的最小镜像覆盖，发布 `last_seen_at`（好友在线
状态）与 `GET /invitations/history`（邀请历史）。

## 候选与门禁

- 基线镜像（部署前运行中）：`sha256:a397ecd9…`（integrate-finance-20260911）。
- 部署前核对：容器内 `friendship/service.py`、`api/identity.py` 与仓库
  HEAD~1 版本语义一致（差异仅为换行），与本地新版本的 diff 恰为两处目标
  改动（friendship +9 行 / identity +53 行）。
- 覆盖文件统一 LF 后上传（`/opt/starchat/releases/profile4feat-20260912/overlay/`），
  SHA256 双端一致：
  - friendship_service.py `96da34bdc194…a9ac813`
  - identity.py `d993ced1721c…ec1f4dd`
- 派生镜像 `starchat-business-api:profile4feat-20260912`
  （`sha256:b7ea31f01df0…c235730`，FROM a397ecd9，仅 COPY 两文件、清
  __pycache__、0644）；无网络导入冒烟 IMPORT_OK。
- compose：以容器实际挂载的 integrate-finance release.json 运行时为基，
  仅换 image 生成 release/rollback 两份
  （`/opt/starchat/releases/profile4feat-20260912/business-api-{release,rollback}.json`）。
  回退 = 换回 a397ecd9 同一 compose。

## 切换与验证

`up -d --wait` 切换成功，HEALTH=healthy。公网验证：

- `GET /api/v1/health/ready` → 200
- `GET /api/v1/friends`（未带 token）→ 401（路由存活，新序列化在鉴权后）
- `GET /api/v1/invitations/history`（未带 token）→ 401 `AUTH_REQUIRED`
  （新路由上线）
- 容器内两文件 SHA256 与上传件一致；17 个 starchat 容器数不变。

## Mi 6 端到端（0.3.84-debug/2088，生产 API）

截图（`docs/verification/artifacts/2026-09-12/chat-ux-5fix-mi6/4feat-*.png`）：

1. 好友资料页（小彭/wdy1998）：`昵称：小彭` 位于畅聊号上方；状态栏
   `21小时前在线`（真实 last_seen 数据），不再固定“刚刚在线”。
2. 个人信息页：邀请码区显示全称 `7TFZPBQ2`、剩余可用次数 `8`、一键复制。
3. 邀请码页：`邀请历史` 分组渲染真实记录（如 `2026-09-10 20:30 /
   未设置昵称 / 畅聊号：dj123`），倒序排列，列表样式与页面一致。

回退命令（如需）：
`docker compose --project-directory /opt/starchat --env-file /opt/starchat/.env -p starchat -f /opt/starchat/releases/profile4feat-20260912/business-api-rollback.json up -d --no-deps --no-build --pull never --wait business-api`

## 2089 覆盖事件与 2090 合并修复（2026-09-12 03:2x）

现象：用户发现 Mi 6 变为 0.3.85-debug/2089 且缺少四项功能。根因：并行
会话从 `codex/chat-selection-20260912`（基于 `1da11922`，含聊天选择
r1–r3 但不含 `1f957444`）构建 2089 并于 02:42 覆盖安装。

处置：审查该分支两笔提交（选择/emoji 偏移修复 48fe7475 + 文档），与
`1f957444` 文件集不相交，`--no-ff` 合并进 main（`0d89cbff`，零冲突，
122 项相关测试全绿）；从合并后 main 构建 `0.3.85-debug/2090`
（final.apk SHA256 `e151da7a…383da14`，27,305 类零变更、固定签名），
03:23 覆盖安装 Mi 6。实机复核：好友资料页“昵称：小彭”+“21小时前在线”
在位（merged2090-friend.png），个人信息页邀请码区（全称/剩余 8/一键
复制）在位（merged2090-invite.png）。已删除已合并分支与 select12 工作树。
