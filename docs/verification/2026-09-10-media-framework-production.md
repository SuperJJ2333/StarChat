# Matrix 框架生产发布记录

状态：生产发布与上线验收完成。用户于 2026-09-10 明确授权按
`docs/runbooks/app-release-deployment.md` 同步更新后的服务器框架。

## 范围与基线

- 目标 `/opt/starchat`，通过已配置的 jumper 连接；只变更 Matrix PostgreSQL、
  Synapse main、独立 Matrix Redis、sync worker 和 Nginx sync 路由。
- 不发布新的客户端安装包，不修改业务服务或全局版本升级设置。
- 原运行镜像为 Synapse 1.132.0，基础 digest 与补丁要求一致；数据库 schema
  `92|t`、549 条媒体记录。服务器 8 个逻辑 CPU、约 7.9 GB 内存，预检可用
  约 5 GB，磁盘可用 174 GB；同机还运行其他服务。
- 新镜像 `starchat/synapse:v1.132.0-dedup.20260910`，实际 image ID：
  `sha256:53b8a7c992fd9fab1a86c3ea657c006e6400fa4fe0655fc6d7dedb1c3e57859c`。

## 已完成的发布完善

- 新增候选配置工具，保留不相关 Compose 服务和生产 iOS 来电路由，拒绝
  Matrix 身份/凭据/监听配置的非预期改变；16 项聚焦测试通过。
- 发现运行进程与磁盘注册密钥不一致：已用历史配置的 HMAC 注册成功确认
  运行值。候选配置保留该值，未轮换密钥；保留 `push.include_content=false`。
  候选环境文件也进入完整性校验。密钥和测试凭据均只留在服务器私密目录。
- 私密备份位于 `/opt/starchat-backups/media-20260910`；在线备份已在
  `--network none`、无端口、512 MB/1 CPU 的临时 PostgreSQL 中恢复成功，
  schema 和 549 条媒体记录一致；临时恢复容器已移除。
- 发布前已验证一个原有 opaque 媒体和一个旧版上传合成文件能够读取；
  两个专用测试账号的令牌留在服务器，不发送聊天消息。
- 领域评审、质量安全评审均通过。4 项故障注入测试覆盖停止命令报错、
  快照失败、部分安装失败和回退顺序；停止报错用例先失败后修复通过。
- 候选 Compose、隔离 Nginx 配置测试、源文件和发布脚本传输哈希通过。

## 容量与兼容性边界

保留[既有容量实测](2026-09-10-media-capacity-runtime.md)中的 500 VU 首轮
失败结果，不将生产发布解释为问题已解决。SDK 默认采用成员懒加载，而
既有容量测试使用完整成员状态；两者负载条件不同，不能据此换算容量。
本发布不在生产执行容量压测，也不声称完成千人 E2EE 或新旧真机互通验收。

## 验收结果

- 2026-09-10 05:14（香港时间）激活成功，整个执行流程耗时 28.34 秒；
  该数字包含快照、就绪等待和冒烟，不是测量得到的用户断线时长。
- main、worker、Matrix PostgreSQL、Matrix Redis 全部 healthy，检查时
  重启次数均为 0、未 OOM。两台 Synapse 进程使用上述同一 image ID。
- 正常 runner 完成 `92/99_chatflow_media.sql` 增量迁移，三张表与视图存在。
  PostgreSQL `max_connections=250`，main/worker 连接池分别为 30/15，
  presence 已关闭，main/worker 宿主端口均限制为回环地址。
- 两个用户上传同一合成 opaque 文件得到同一 MXC；数据库确认两条有效
  独立引用。上线前旧文件和原有 opaque 媒体读取哈希保持一致。
- main、worker 和公网认证同步通过；专用 `release_probe` 的成功请求在
  worker 请求日志中出现，证明公网 sync 路由确实进入 worker。
- 服务器和工作站上线后各 7 项公网检查全部通过：Matrix versions、
  discovery、未认证 sync、受保护管理路径、业务健康、下载页、升级 API。
  网关容器读取的配置 SHA-256 与宿主文件一致，签名密钥保持不变。
- 所有不相关容器 ID 保持不变。两个测试会话已登出，账号保留供审计；
  两次恢复演练的临时数据库容器均已移除，没有影响同机其他项目。
- 最终停止写入快照再次恢复成功，恢复 schema 为 `92|t`、媒体 550 条
  （比初始多一条发布前合成文件）。最终 dump SHA-256 为
  `e70d09ff33defbd1ca04f319e0167c3a0ce67bfc04692ee07688055d732ce7e8`。
- 服务器 renderer 已补齐 worker 映射；保留 iOS 来电、下载分发、个推的
  既有路由并回写到服务器模板，渲染结果与当前配置精确一致，`--check
  --require-production` 返回 `NO DRIFT`。未再次改写运行配置。
- 完整 `scripts/verify.ps1` 返回 0：infra 118、Getui 28、bot 9、业务
  1400、移动边界 66 通过；UI contract、192 文件 AST、迁移、OpenAPI、
  Compose 通过。业务 34 项条件跳过和原有依赖弃用警告如实保留。

`activation-result.json` 中最后一轮 `verify` 的 `cross_user_dedup=false`
表示该轮只复查已有共享媒体，没有重复上传；激活前一轮 `after` 已断言
两个上传返回同一 MXC，`post-verify.json` 再次确认两条共享引用。此字段
不是去重失败结论。

回退保持补丁镜像/schema/Redis，关闭新去重并将 sync 恢复到 main。
本次未触发生产回退；代码经过故障注入，数据库备份经过实际恢复。
专用测试令牌已失效，今后人工回退须先准备新的专用验证会话，不能直接
复用本次私密 smoke 文件中的已登出令牌。

可公开的脚本、测试和校验清单位于
`docs/verification/artifacts/2026-09-10/media-production-release/`。
