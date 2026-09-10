# 计划：内容寻址媒体去重与千人加密群扩容

**状态：用户已确认修订并要求执行，2026-09-09。** 原预审被后续决策替代，不再要求独立 media_id 或热缓存检查附件信封。依据：[ADR-0060](../../adr/0060-content-addressed-media-dedup.md)。证据：[执行记录](../../verification/2026-09-09-media-dedup-implementation.md)。

## 全局约束

共享 media_id＋独立上传者引用；可信内容哈希命中经过校验的缓存。精确最终字节去重，压缩先于哈希/加密，重试复用生成结果。明文哈希只在 E2EE 事件内传送。采用 ADR 的固定派生协议。默认开关可回退，不改 Megolm 轮换、不做先问后传。每个行为任务先失败测试再实现。临时文件只在 docs/verification/。保留其他任务修改；compose 由根协调者唯一拥有。初始范围不含生产部署；2026-09-10 用户明确要求按 app-release-deployment.md 将更新框架同步生产，追加 Task 10，替代原生产部署限制。

## Task 1：文档、审批和协议

拥有 ADR、计划、规格及证据。记录后续用户授权并纠正过强预审限制。固定 HKDF 原始摘要、salt/info、48 字节 OKM、32 字节 key、8 字节 nonce＋8 零的 IV。先领域后质量安全复核。1000 人是目标，presence 关闭为授权可见行为。

## Task 2：SDK 预加密支持

拥有 apps/mobile_flutter/third_party/matrix/。新增 encryptFileWithKey，保持 Matrix v2 编码与密文摘要。预加密文件携带明文预览和信封，避免二次加密；保留图像/音视频元数据。缩放和自动缩略图在派生前完成或由上层完成后禁用二次处理。重试复用对象。更新 CHATFLOW_PATCH.md。先测试固定向量、无二次加密、预览、类型和缩略图。

## Task 3：确定性发送

拥有 content_addressed_media.dart、matrix_e2ee_client.dart、core/app_config.dart 及发送测试。MediaEnvelope.forBytes 按 ADR 派生且在途合并；deterministicMediaEncryption 默认 true。扩展 chatflow_media={v:1,content_sha256:<hex>,thumbnail_sha256:<optional hex>} 仅放加密事件中。调用方 extraContent 不能覆盖实际摘要，关闭开关删除该扩展。正文和缩略图分别处理；转发不重复压缩。测试向量、回退和上传边界。

## Task 4：内容缓存

拥有 media_cache.dart 及缓存测试。MediaCacheKey 添加可选可信 contentSha256；chat-media/content/<hash> 单副本，旧 room/event fallback 保留；磁盘、内存、在途键一致，原 LRU 总预算覆盖新旧。内容读写均验实际 SHA-256；损坏清理后 miss 重拉，错误下载不落盘；播放原地扩展不复制。热命中不调用下载/附件解密、不比较当前 key/iv。

## Task 5：接收与所有调用点

拥有 timeline adapter、room_page、voice/forward 调用点及测试。只取成功解密事件里的扩展，严格 v/hex，缺失兼容、畸形拒绝。正文和缩略图摘要分别透传；图像视频语音转发统一验证实际内容。测试跨房间零下载、异内容隔离、同长度损坏、畸形字段；冷路径仍经 SDK 校验/解密后验明文哈希。

## Task 6：Synapse 去重和引用生命周期

拥有 third_party/synapse/ 和 tests/infra/test_media_dedup*。锚定 v1.132.0、真实解析 digest。密文唯一摘要索引指向共享 media_id，(media_id,user_id) 保存独立引用、最近上传和删除状态。按用户列表/统计/删除使用引用；全局隔离不能绕过，最后引用删除后保留供重用。DB 跨进程串行化上传和回收，文件失败不发布坏 ID，唯一约束兜底，幂等重新激活。CHATFLOW_MEDIA_DEDUP 控制新去重，关闭仍处理已有引用。不把上传者引用当消息数。提供 schema/事务/生命周期源码及补丁、Dockerfile、回退；真实集成测试不同用户同 ID、逻辑删除后复用、并发、隔离、关闭开关。根协调者接入 compose/.env.example。

## Task 7：Worker 扩容

拥有 infra/synapse 模板、render_config.py、scripts/init_matrix.ps1、nginx 模板和测试。独立 matrix-redis、main replication 9093、presence=false、rc_invites.per_room burst_count=1200/per_second=50、main cp_max=30/worker=15、PG max_connections=250。generic_worker 8081 client/replication、独立 name/pid，instance_map.main 指向 synapse:9093（1.132.0 拒绝旧 worker_replication_* 字段）。redis:7.4.2-alpine。worker 与 main 同补丁镜像；sync/events r0/v3 路由 worker，其余 main。开发 worker 127.0.0.1:18081（容器 8081，避免 bot 端口冲突）。渲染、健康和回退验证。

## Task 8：压测运维

拥有 scripts/loadtest/、thousand-member-capacity.md 及隔离集成证据。k6 固定版本、env 输入无真实凭据；sync 持续使用 since/timeout，加入入群收发场景。区分 HTTP 传输负载和真正 E2EE 解密正确性。隔离本机 200–500 VU 实测，记录成功率/延迟/资源和基线差异；未来千人步骤写 runbook。恢复本机 Docker 后尝试运行；不能伪造环境受阻时的实测。

## Task 9：门禁评审

执行 flutter analyze --no-pub、flutter test --no-pub、py -3.12 -m pytest tests/mobile -q、pwsh -NoProfile -File scripts/verify.ps1。先规格评审、后质量安全；修正后复核。区分通过、失败、环境限制。未授权生产部署或全量千人压测。


## Task 10：生产框架发布（2026-09-10 用户追加授权）

根协调者拥有生产发布脚本、infra/compose 下 Matrix 发布 overlay、部署文档及当日发布证据。按指定 runbook 的 jumper SSH、文件 SHA-256、服务器私密备份、网关 inode 保持和双端验证流程执行。先核对现有配置漂移，保留服务器独有配置；只同步本任务 Synapse 补丁、main/worker/Redis 配置和 sync 路由，不覆盖其他业务模块、客户端版本或升级设置。镜像基于已验证 digest 构建并记录最终 image ID。备份数据库与密文媒体/签名配置，验证可恢复后，先 main/Redis、后 worker、最后 nginx 路由切换。上线前领域评审通过后再质量安全评审。回退关闭新去重并将 sync 路由恢复 main，保留补丁与增量 schema，不恢复会丢失发布后写入的旧数据库。验证现有媒体读取、健康、权限边界及 worker 请求路径。保留 500 VU 首轮失败的容量结论；生产上线不等于千人 E2EE 验收，不在生产进行容量压测。
