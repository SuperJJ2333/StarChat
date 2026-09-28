# 朋友圈视频封面 API261f / 0091 发布核验

用户于 2026-09-28 明确批准固定候选 API `sha256:261f0425ba69581357038e86e3804be6a596fed8c81af386ab58daa82dc1c07a` 与扩展迁移 `0091_moment_video_posters`。本报告仅记录该服务发布；iOS 企业版2189分发由[独立任务](2026-09-28-ios-enterprise-distribution.md)记录。

## 发布前门禁

- [候选](artifacts/2026-09-28/ios-media-room-followup/moments-server/candidate-report.md)与[独立规格→质量安全评审](artifacts/2026-09-28/ios-media-room-followup/moments-server/release-review.md)：六源文件身份冻结，最终 Ubuntu CI Moments154/PG16.9并发5/迁移2 全通过；旧0090生产备份的隔离恢复与0091升级、旧行保持及兼容回退已验证。
- [独立现网前态](artifacts/2026-09-28/ios-media-room-followup/server-publish-preflight/report.md)：API e304/容器5e43、worker a508/容器aed4、PG7c688/容器0d07、固定Compose SHA、单0090 head均匹配；0091两列不存在。候选261f和兼容回退30391镜像已在宿主机；发布目录和迁移容器原先不存在。
- 冻结脚本 SHA256 `8966c7babbc5157187339164f8b9f706a0cba6a7707d3bc17394f5be51d54954`；经跳板上传至服务器 root-owned 发布目录后，服务器 `sha256sum`同值，权限0600。

## 实际激活

- 以用户授权对应的固定标识执行 `moments_api_release.py activate --approved-candidate starchat-api-261f0091-20260928`，退出码0，输出 `{"release":"starchat-api-261f0091-20260928","phase":"active","status":"verified"}`；本地[执行日志](artifacts/2026-09-28/moments-poster-api-publish/activate.log)和[退出码](artifacts/2026-09-28/moments-poster-api-publish/activate.exit)保留。
- 脚本设计先在服务器私有0700目录保存0600 PostgreSQL custom backup与Compose/runtime，再验证并执行0091，最后仅重建 business-api；完成前检查健康、现有OpenAPI路径、新旧写入口匿名401、六文件SHA及其他容器身份。数据库备份/环境/运行凭据未下载至本地。
- [独立规格复核](artifacts/2026-09-28/moments-poster-api-publish/spec-review.md)确认脚本本地与远端 SHA 一致；仅白名单读取服务器私有 state 的 phase=active、root/0600、备份摘要与三个配置名，不输出环境或备份内容。
- [独立公网/本机接口验收](artifacts/2026-09-28/moments-poster-api-publish/public-qa/report.md)通过：严格 TLS 公网 live/ready 200，数据库 ready；本机 OpenAPI 326 路径=旧324+2，新增两 POST 与四个抽查旧路由存在；公网和本机六个新旧受保护入口匿名均401。公网 OpenAPI 404 为网关不公开文档；不把它当服务故障。
- [独立服务器后态](artifacts/2026-09-28/ios-media-room-followup/server-publish-preflight/postpublish/report.md)通过：新 API 容器 `6dfb930293cc…090a93a0` 运行/healthy/restart0，实际六源文件SHA与冻结身份6/6同值；数据库单0091 head及两可空列。其它45容器 ID/镜像与发布前 checkpoint 相同，之后无重启，当前restart0；命名迁移容器已消失。
- 服务器私有 checkpoint `active`，完成mtime 2026-09-28 05:45:13.990289Z；目录0700、state/backup0600。完整备份29,265,946字节，SHA256与checkpoint一致，内容未下载；有界最近300条API日志中标准severity错误0、可识别HTTP5xx 0，一条单纯数字5xx未归类。此检查不覆盖全部日志格式或长期流量；各阶段迁移精确耗时未知。

## 回退边界

0091为两个可空列的扩展迁移，不执行数据库降级。若必须应用回退，使用含0091迁移元数据的兼容镜像 `sha256:30391c2a2a82d6a6b20b4024b9f4e57ed2ee8dcd2791553f3fc8cb43f179b8b6` 和[冻结交接](artifacts/2026-09-28/ios-media-room-followup/moments-server/release-handoff.md)中的显式 `rollback`，保留新增列/数据。不会用不认识0091的原始e304镜像直接启动。

**结论：** API261f/0091生产发布与只读后验通过。因无生产测试账号，本次未执行真实已鉴权上传、跨账号可见性读取；iOS2189真机跨设备封面与旧聊天连续性仍需设备验收。关联[任务台账](../workflow/tasks/2026-09-28-moments-poster-api-publish.md)。
