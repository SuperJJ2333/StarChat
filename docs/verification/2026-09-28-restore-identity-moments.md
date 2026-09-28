# 已发布资料与朋友圈行为独立恢复：验证记录

状态（截至 2026-09-28 23:19 +08:00）：**本地实现、源码规格/领域审查和 r2 独立增量质量/安全审查通过，后者无 P0–P3；修正环境后的完整 Business API 套件真实 exit 0（2837 passed、78 skipped、1 条环境弃用 warning）。r2 已在生产仅切换 API，发布器 verify 于 2026-09-28 15:14:50 UTC 通过，服务器与工作站严格 TLS 公网匿名探针均通过。真实产品会话操作仍待反馈。** 用户已批准[独立计划](../superpowers/plans/2026-09-28-restore-published-identity-moments.md)及[双角色镜像门禁 ADR](../adr/2026-09-28-role-aware-refresh-image-gate.md)。

## 现网和恢复范围

- r2 发布前 API `sha256:2b847ef70e0257f4ba52e663812112d7664016ff427d454c32630da1b0c89a63`；发布后 API `sha256:8015e9637fb33c3cf07995612ba1680dbdd3acec4705dee062803517d4bd26d3`。Worker 未切换，仍为 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`；schema 唯一 head 保持 `0091_moment_video_posters`。
- [逐文件清单](artifacts/2026-09-28/restore-identity-moments/inventory-delta-final.txt)由发布前容器只读 SHA 清单核对：API 248 个 Python 文件中仅 7 个既有文件与恢复源码不同，新增现网缺失的 `profile_text.py`；其余 241 个相同。Worker 20/20 相同。r2 候选构建与上线 verify 均核对八目标 SHA。
- 恢复 9 月 24 日已批准发布的昵称/签名可见字素限制、旧 COMPLETED 注册请求只读重放、资料审计去原文、朋友圈互动隐私投影及回复/分页；保留当前手机号、用户名、0091 视频海报、钱包 T2 与资金边界。另修复了同键空白推荐码的规范化错配，以及客户端伪造 `video_cache_keys` 被草稿保存的现网回归。

## 本地红绿与相邻门禁

| 检查 | 结果 | 证据位置或限制 |
| --- | --- | --- |
| 资料/注册聚焦 | 现网对应输入 RED：29 pass/10 fail；恢复 GREEN：39/39 | `artifacts/2026-09-28/restore-identity-moments/identity-profile-{red-2,green-final}.log` |
| 空白推荐码同键重试 | 原样请求第二次预检 RED 409；统一规范化后 GREEN 1/1；注册/推荐/手机/Identity 相邻 67/67 | `artifacts/2026-09-28/restore-identity-moments/blank-referral-{red,green,adjacent}.log` |
| 朋友圈互动 | 当前生产源码聚焦 2 pass/20 fail；恢复聚焦 22/22；完整 Moments 164/164；视频海报 27/27 | 代理红绿与完整测试输出，最终文件 SHA 在恢复包清单 |
| 业务 Worker | 115/115；为当前生产 Worker 20 文件镜像补齐本地只读快照，并更新与现网注册事件/媒体依赖一致的旧测试装配 | 本地执行输出；Worker 镜像未覆盖 |
| 其他可运行门禁 | 仓库策略、部署策略、模板、infra 201/201、Getui 28/28、Matrix Bot 9/9、mobile 238 pass/1 skip、UI 契约 32 组件/433 屏、API import、278 个 Python 文件 AST、Compose config 均通过 | `scripts/verify.ps1` 需 `.env` 才能完成 Matrix render；隔离 worktree 无该文件，未运行也不宣称整脚本 PASS |
| 契约与迁移 | OpenAPI 导出后 `--check` 通过，契约 4/4；Alembic 唯一 `0091` head 与全量离线 upgrade 通过 | 本地命令输出；无新迁移 |
| 风格 | 恢复 8 个 API 文件、此次修改的身份/Worker 测试 Ruff 通过；`git diff --check` 通过 | 旧版 Moments 测试目录存在与本次运行时代码无关的 Ruff 样式错误，不作为本次新代码通过声明 |
| 首次完整 Business API suite | 2832 pass/78 skip/5 fail，耗时 2265.06 秒；五项均为与现行线上行为失配的旧测试断言 | [原始全量日志](artifacts/2026-09-28/restore-identity-moments/business-api-full-final.log)，不声明全量通过 |
| 五项旧断言修订 | 先复现 5 fail，再聚焦 5/5；三个所属文件完整 171/171；枚举收紧后相关 9/9，Ruff 与 diff check 通过 | 仅改 `test_client_diagnostics.py`、`test_user_search.py`、`test_wallet_release_baseline.py`；未改运行时代码或发布包 |
| 完整 suite 复跑 | 首次复跑因 Worker tasks 不在 PYTHONPATH，收集 2 错后停止；修正 PYTHONPATH 后真实 exit 0：2837 passed、78 skipped、1 条 Starlette/httpx 环境弃用 warning，2252.75 秒 | [首次复跑错误日志](artifacts/2026-09-28/restore-identity-moments/business-api-full-pass.log)；[成功复跑日志](artifacts/2026-09-28/restore-identity-moments/business-api-full-pass-2.log) |

独立规格/领域审查于源码冻结后通过，无未解决阻断；独立质量/安全审查对 r1 包复核 23/23、契约/迁移 17/17 后放行。r2 探针另有 `127.0.0.1/32` 回归 RED/GREEN，r2 包测试 23/23、Ruff、compileall 和 17 个归档成员复核通过；r2 独立增量质量/安全审查 PASS，无 P0–P3。完整 Business API 修正环境后 exit 0；生产用户资料、实际互动、短信、邮件和资金写入未用于自动验收。

五项旧断言的归因已按现网源码核对：诊断服务端允许值包含 Dart 当前未发出的 `timeline_published`、`video_thumbnail_started`、`request_timeout`，测试仍以集合等号核对 Dart 枚举加这三个显式已发布例外，避免任意新增值静默通过；搜索仅对含 `@` 的完整邮箱做大小写不敏感精确匹配，其余按畅聊号发现规则检索。现网与恢复源码的 `ProfileService.search_public_profiles` 函数字节 SHA 同为 `a58f91521c35bd0ab18ef1cad3579fa97ea01b3cab425820c663978dc7adfcc4`。迁移头为唯一 `0091_moment_video_posters`，历史祖先断言保留。原有诊断负向自由文本、搜索未授权及脱敏断言均保留；三文件修订经独立审查通过。

## 双角色门禁与冻结包

- 获批 guard/probe 安装包 SHA `3a15381b23e11adb4d3841ab1177ecbdf26fd7681ce95a23ad7446e68ea33e67`；服务器安装前的两个旧 SHA 分别为 `4d1d4a00c91d706fead2037072811a8688c0ba88d317c0f1dbbb42df2a243b02`、`6f6662c746cbc881c38672c67fcee1b968a9190c798ff0d623d457623a3ad6ab`。安装后分别为 `78b2beb6c20484cea04fa8e77c1dd23b9a3e401af9d6fafd3e4b7d316d07beec`、`d77a83e89d848bfc8b6d7dad72b9abd01d60550a6e356d0a12b382674c37b678`；旧版私有备份 `/opt/starchat/releases/role-aware-guard-20260928-d0_vhuqs`。`verify-package`、`dry-run`、`install` 均返回通过，新门禁对当前不可变 API 9/9、Worker 8/8 实测通过。r2 候选/回退 API 与 Worker 镜像逐角色检查已通过，切换前仍须再次核对。
- 恢复 r1 [manifest](artifacts/2026-09-28/restore-identity-moments-release/package/manifest.json) SHA `9531c7da3311a59900e9df4f48ea4369e04509f5e52f2682ab2c55fb57c8bcb7`，[archive](artifacts/2026-09-28/restore-identity-moments-release/restore-identity-moments-20260928-r1.tar.gz) SHA `f46ebe6385aefeedd8de4291fd5e8f5b78aaa6184fea01fb3895ccffb1e5237a`。17 个普通归档成员逐字节复核；仅 8 个 API 文件与锁定 `regex==2026.2.28` wheel（SHA `d6b08a06976ff4fb0d83077022fde3eca06c55432bb997d8c0495b9a4e9872f4`），Worker/静态/迁移为零。本地发布器测试 23/23、Ruff 和 compileall 通过。服务器归档、manifest SHA 与只读预检通过；0700 备份 SHA `a0629a8de4cb3c4cc66c751715fea7ac8e85983b3a71d1c0092f9148a8dd55b3`，候选 API `sha256:65e0974113572c8ca5777844261ce110e30e63d16a21ce3cc847bc65ce37ef13`，候选/回退双角色镜像门禁通过。生产服务未切换。
- 独立 r2 [manifest](artifacts/2026-09-28/restore-identity-moments-release-r2/package/manifest.json) SHA `d69138a8499b71ccd28933b4bd0911b646736813a7fa3b541d0969075d34625e`，[archive](artifacts/2026-09-28/restore-identity-moments-release-r2/restore-identity-moments-20260928-r2.tar.gz) SHA `4da255803e61a606970c4ddbd9bddbf630d6afe0d1205cc179fc5d6c9b40ad61`。r2 仅将 PG 探针 SQL 改为 `host(inet_server_addr())`、更新发布 ID/探针 SHA；8 个 API payload 和同一锁定 wheel 与 r1 逐字节一致，Worker/静态/迁移仍为零。新服务器目录 `/opt/starchat/releases/restore-identity-moments-20260928-r2` 为 root 0700；validate/preflight 返回 0091；新 `private/` 0700、文件 0600，PG 备份 SHA `c32fea3a0df88ee34c92f072517cb181c22dc01184c64ca7f49e834e835011e7`。禁网构建候选 API `sha256:8015e9637fb33c3cf07995612ba1680dbdd3acec4705dee062803517d4bd26d3`，Worker 保持原 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`；镜像内 `regex==2026.2.28` 导入与候选/回退双角色门禁通过。0091 禁网克隆恢复、`run-pg-probe` 返回 true、`restore-finalize` 确认克隆已删除。其后切换前 `server_release.py preflight` 再次 exit 0 且 schema 为 0091，`deploy` exit 0 并仅切换 API。

## r1 隔离探针失败与新发布 ID

`restore` 在 `--network none` 的 PostgreSQL 16.9 克隆中从私有备份恢复 0091，结构校验通过。`run-pg-probe` 退出 1 并按发布器 `finally` 移除了原克隆；私有错误只含 `pg_probe.py:61 ValueError("isolated clone identity, read-only mode or schema mismatch")`，无用户记录。为确认根因，从同一私有备份建立另一临时禁网克隆，在同一候选 API 镜像和 loopback/只读参数下只输出聚合诊断：`inet_server_addr()::text` 为 `127.0.0.1/32`、只读 `on`、schema `0091_moment_video_posters`、公共表 138。r1 探针把显式转换结果与无掩码的 `127.0.0.1` 比较，必然失败；原探针在新克隆再次 RED。r2 以 `host(inet_server_addr())` 消除掩码差异，独立 r2 克隆探针已 GREEN；其克隆由 finalize 确认删除。

r1 的 write-once `restore-running.json` 绑定已删除的原克隆身份，不覆盖、修改或伪造该文件续跑。保留 r1 的服务器目录和私有失败证据；独立 r2 已重跑准备、构建与隔离验证。r1 失败阶段发生在业务 API 切换前；r2 随后独立完成生产发布。

## 生产切换与独立验收

1. 完整 API suite exit 0 后，切换前 `server_release.py preflight` exit 0、schema `0091_moment_video_posters`。`server_release.py deploy` exit 0，仅 API 切至 `sha256:8015e9637fb33c3cf07995612ba1680dbdd3acec4705dee062803517d4bd26d3`；Worker `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf` 未切，静态与迁移均无发布目标。
2. `server_release.py verify` 于 **2026-09-28 15:14:50 UTC** exit 0：八个 API 目标 hash、schema 0091 和其他运行容器不变。服务器 `public_verify.py` 严格 TLS JSON ready 与两项未认证 401 exit 0；工作站经 jumper 临时 loopback SOCKS `127.0.0.1:18946` 执行同样严格 TLS 检查 exit 0，验后隧道已关闭。API/Worker Docker inspect 均 healthy、restart count 0。
3. 上线后日志聚合检查：Traceback 0、JSON `ERROR`/`CRITICAL` level 0；含 `ERROR` 字样的行仅为 `event=client_diagnostics` 聚合，不输出敏感日志或用户记录。这些观察与匿名 ready/401 探针不能证明真实用户资料写入、旧请求重放、朋友圈互动、短信/邮件或资金路径；产品会话反馈仍待取得。

管理台 A1–A5 的下一步是以新生产 API 镜像重新冻结目标源与静态 SHA、合入恢复八文件后制作新包，旧 v3 不能直接发布。必要回退仅按 r2 冻结包恢复旧 API/Compose，保留 Worker、schema 0091 与静态，不执行数据库回灌。
