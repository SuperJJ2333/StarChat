# Moments 评论权限部署与回退

本次已授权范围及证据：`docs/verification/2026-09-10-four-fixes-2083-delivery.md`。连接遵循 `app-release-deployment.md`，本机代理不可用时使用 `ssh -J jumper -p 23421 root@207.56.8.8`。

发布目录：`/opt/starchat/releases/moments-comment-privacy-20260910/`。目录内运行环境快照、Compose、数据库备份保持仅服务器管理员可读，不下载、提交或打印其中的环境变量。

## 本次发行

1. 比较运行中 `starchat-business-api-1` 的三个 Moments 文件与本地基线，确认线上缺少评论权限查询。保留旧源码及其校验值。
2. 冻结实际 API 的环境、挂载、启动命令、网络、健康检查和安全配置，准备原镜像回退配置。
3. 用原 API 镜像为基底，只复制 `service.py`、`visibility.py`、`media_access.py` 至 `/opt/business-api/app/modules/moments/`；验证每个输入 SHA256，禁用网络构建。
4. 创建但不启动候选/回退容器，比较配置。候选独立运行 `candidate_probe.py`，显式设 `PYTHONPATH=/opt/business-api`，仅内存 SQLite 与合成账号，不连接生产数据库；基础镜像还包含旧 `/app` 源码，不应误测该导入路径。
5. 生产库只读 `pg_dump -Fc` 后，在无网络临时 PostgreSQL 中恢复验证。此次没有迁移，不要为了本次修复升级到本地较新的空合并迁移头。
6. 仅替换 API，保持 Worker、网关和其他容器不变；验证健康状态、运行文件哈希、完整配置及其他容器 ID。
7. 从 `https://liuhetong888.com/api/v1/health/ready` 验证 JSON ready，从未认证 feed 验证 401。`www` 静态站点的 HTML 200 不可充当 API 验证。
8. 客户端评论元数据 key 为 `cache.moments.feed.latest.audience-v2`，保证升级首屏不展示旧权限的评论；媒体缓存独立保留。

本次部署脚本已经执行，后续不要原样重跑 `snapshot/build/backup` 覆盖已有记录。新发行使用新目录并重新核对实际基线。

## 验证与回退

在服务器运行：

```sh
python3 /opt/starchat/releases/moments-comment-privacy-20260910/server_release.py verify
```

只有在确实需要回退本次 API 时运行：

```sh
python3 /opt/starchat/releases/moments-comment-privacy-20260910/server_release.py rollback
```

脚本恢复冻结的原 API 镜像与运行配置，不覆盖生产数据库。回退会恢复原先存在评论泄露的旧实现，需要同时明确记录该权限问题重新开放。备份恢复仅用于灾难恢复流程，不是本次无迁移 API 回退步骤。

此次没有发布正式 APK、修改全局更新弹窗或改变正式签名，仅向授权连接的测试设备覆盖安装 Debug 包。
