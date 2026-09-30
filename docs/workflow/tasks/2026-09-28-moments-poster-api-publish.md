# 朋友圈视频封面 API261f 与 0091 生产发布

## 授权与恢复

- 用户 2026-09-28 明确回复“批准发布新视频封面的配套 API 和 0091 迁移”。此授权仅覆盖固定 API 镜像 `sha256:261f0425ba69581357038e86e3804be6a596fed8c81af386ab58daa82dc1c07a`、可空扩展迁移 `0091_moment_video_posters`；不授权 worker、其他服务、Android 包或金融状态变更。
- 关联[原实施台账](2026-09-28-ios-media-room-followup.md)、[候选报告](../../verification/artifacts/2026-09-28/ios-media-room-followup/moments-server/candidate-report.md)、[冻结发布交接](../../verification/artifacts/2026-09-28/ios-media-room-followup/moments-server/release-handoff.md)、[独立发布评审](../../verification/artifacts/2026-09-28/ios-media-room-followup/moments-server/release-review.md)。原记录“待批准”是批准前阶段快照，本记录承接服务发布。
- 执行工作树 `C:/Users/Administrator/.codex/worktrees/ios-media-room-followup/StarChat`；生产入口 `scripts/starchat-server.ps1` 经既有 jumper。冻结 Linux 发布脚本 `moments_api_release.py` SHA256 `8966c7babbc5157187339164f8b9f706a0cba6a7707d3bc17394f5be51d54954`，固定标识 `starchat-api-261f0091-20260928`。受保护备份和运行环境只留服务器 0700 私有目录。

## 发布验收台账

| ID | 目标 | 当前状态 |
| --- | --- | --- |
| P01 | fresh 基线匹配 e304 API、a508 worker、Compose、PG、0090 与容器身份 | PASS；[独立前态](../../verification/artifacts/2026-09-28/ios-media-room-followup/server-publish-preflight/report.md)与发布器执行时守卫同值 |
| P02 | 备份、0090→0091、可空列与旧行保持；回退不降库 | PASS。服务器 root/0600 custom dump 29,265,946 字节，SHA 与私有 checkpoint 相同；`pg_restore --list`、0091 单 head 和两可空列通过。旧行保持/兼容回退为此前实际 PG16 隔离恢复证据；生产不降库 |
| P03 | 仅切 business-api 至固定 261f，运行环境/端口与其他容器保持 | PASS。新 API 容器 `6dfb930293cc…090a93a0`/261f healthy、restart0；其余45容器 ID/镜像与 checkpoint 同值，worker/PG 不重启 |
| P04 | 健康、鉴权401、新 poster/CAS 路径、旧 OpenAPI 路径与实际六文件 SHA 验证 | PASS。发布器及独立服务器后验各核六源文件 SHA；本机 OpenAPI326=旧324+2，旧路径全保留；新旧受保护入口匿名401。本机/公网 health/ready200 |
| P05 | 双侧 HTTPS、错误/重启观察、可用兼容回退与交接 | PASS。独立服务器与工作站严格 TLS 验收；截至05:49Z有界最近300条 API 日志无标准severity错误及可识别HTTP访问5xx，45容器重启0；一条未归类数字5xx保留限制。兼容回退30391可用但本次未触发 |
| P06 | 新版 iOS 真机跨设备视频封面显示 | 待设备验证，不能由服务端探针代替 |

## 冻结依据与回退

- 最终 Linux [36350245275](https://github.com/SuperJJ2333/StarChat/actions/runs/36350245275)：Moments154、PostgreSQL16.9 并发5、迁移2 全通过；此前生产数据库备份隔离恢复、0090→0091 旧行保持和兼容旧应用读验证通过。冻结发布脚本合成26项 exit0；先规格后质量安全独立复核 PASS。旧仓库整份 OpenAPI exporter 的非 Moments 漂移单独留存，范围契约仅增五个 Moments 路径/五 schema，不覆盖旧接口。
- 兼容回退镜像 `sha256:30391c2a2a82d6a6b20b4024b9f4e57ed2ee8dcd2791553f3fc8cb43f179b8b6` 保留旧业务行为和0091迁移元数据；生产0091一旦执行不降级或删列。未知漂移、残留迁移容器、部分备份或未成 checkpoint 必须停下来读取私有状态，不能盲目重试。

## 阶段计时和下一步

| 阶段 | 起止（Asia/Hong_Kong） | 证据 |
| --- | --- | --- |
| 授权与只读复核 | 精确起点未知；首次 clock 2026-09-28 13:41:18，前态约13:41–13:42 | 三只读代理并行；fresh 基线、候选/脚本评审均 PASS |
| 传输与执行 | SHA暂存后，服务器 state 完成时间 2026-09-28 13:45:13.990289 | 脚本 SHA 同值、0600；activate exit0 `active/verified`，备份/0091/API-only |
| 双侧验收与记录 | 13:45–13:49:24，服务器精确观测始于13:47:38 | 本机/公网健康、鉴权、OpenAPI、全部其它容器、六源文件和备份独立读回 PASS；迁移分阶段耗时未知 |

发布记录：[核验报告](../../verification/2026-09-28-moments-poster-api-publish.md)。下一步：在 iOS2189 企业包可安装设备上验证已鉴权视频发表、其他设备读取封面、旧无封面动态播放及本机消息/推送连续性。没有生产测试账号，本轮只验证匿名边界和公开契约；不读取用户内容。若后续发生生产故障，先读取当前 phase/image/schema 和私有日志固定错误类，再决定已审兼容回退或停止。
