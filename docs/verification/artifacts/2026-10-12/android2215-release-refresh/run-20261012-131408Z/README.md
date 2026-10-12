# Android2215：正式构建前只读基线刷新

此次仅复用已审 `c1b1ccd777d7ef11a1a1af956547b43bbf89d573` 中 `android2215-release/baseline/` 的三个精确 Git 脚本，复制到独立新 run；旧冻结目录未改。HK 经既有 `scripts/starchat-server.ps1`/jumper，SG 经既有 jumper/固定 SSH 主机身份，保留主机验证；HK/SG 各执行一次且 exit 0。没有重跑准备级测试。源脚本身份见 `source-identities.json`。

- HK checked UTC：`2026-10-12T13:14:18.447538+00:00`（可传 builder 的 `ProductionCheckedAtUtc`；仍适用其 30 分钟时效门禁）。
- SG checked UTC：`2026-10-12T13:14:21.948533+00:00`。
- 实际 Android `0.4.45+2214`、iOS `0.4.44+2213`，minima `3/3`；10 项设置均与已冻结前态相同。
- 35 个运行容器的名称、完整 ID、镜像、restart_count、started_at 全部一致；schema `0095_wallet_source_alerts`。这不是新增健康/性能检查，未读取日志或执行业务调用。
- 永久 guard `46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b`，probe `2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15`；只哈希，不运行。
- HK `/opt/starchat/frontend/downloads/ChatFlow-0.4.46-build2215-arm64.apk` 不存在；7 项静态文件、registry、3 个 ABI alias 和旧 2214 包均与原基线一致。
- SG 固定 AWS 身份/桶策略/CloudFront 配置未变：16 条规则，`Deployed`，ETag `E3R76HOPU0Z2CB`，未出现新 2215 路由。未额外查询 S3 目标对象，不能把 HK 文件不存在扩展为全部远端位置均不存在。
- HK snapshot SHA256：`f4d8e75c3fd58005901619234378bd91a5331abc0cc901870b9e2a8d02060940`。
- SG snapshot SHA256：`3d940e58e09c917d5962c5540538177a00d0d29031b913f7fbdae07ae4529f4f`。

`comparison-receipt.json` 的 18 项比较均 true，保存原始投影/元数据/公开静态字节；本 run 的输入清单使用精确 Git blob 字节，静态和 JSON 原始捕获通过 `-text` 保留。旧工作状态页只是历史索引，以上事实来自本次读取。

未上传、生产写、云变更、启动临时容器、构建、签名、安装或发布；此记录仅为前态，不是新 APK/三门禁/发布批准。root 负责正式构建与发布，实际 mutation 前仍执行框架 fresh preflight/CAS，漂移需停止。
