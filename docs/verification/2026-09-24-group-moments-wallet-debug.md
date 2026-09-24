# 群聊、朋友圈、钱包与 MI 6 Debug 交付证据

## 范围与基线

用户本次授权八项功能及 MI 6 Debug 测试安装；不发布正式版/更新弹窗。候选工作树 `.worktrees/online-room-refresh` 基于 `8ed729a1`，保留已交付 0.4.9/2168 的前轮未提交修复。开始时 MI 6 (`cbd0156b`, Android 9) 在线，已安装 `com.liuhetong.mobile` 0.4.9/2168 Debug，设备 APK SHA256 `1a2bb53e47191ae0b51192ae30bbdbba251b95ee90aaa55251fe73d7ded07d9a`，首次安装时间 `2026-09-20 09:35:24`。

计划：[实施计划](../superpowers/plans/2026-09-24-group-moments-wallet-debug.md)；任务：[交接记录](../workflow/tasks/2026-09-24-group-moments-wallet-debug.md)。命令日志在 [本次测试目录](artifacts/2026-09-24/group-moments-wallet-debug/)；Android 工件使用独立 C 盘同名 `docs/verification/artifacts/2026-09-24/android-debug2169/`，防止覆盖 2168 证据。

## 红绿与当前验证

| 范围 | 红灯 | 绿灯 / 当前结果 |
| --- | --- | --- |
| 钱包文案 | 新精确文本 widget test exit 1：找不到文本 | `flutter test --no-pub test/features/wallet/manual_wallet_navigation_test.dart` exit 0，1 passed；`wallet-red.log`、`wallet-green.log` |
| 朋友圈上传完成缓存 ID | 视频上传→发布 test exit 1：`media_cache_key` KeyError | 定向 test exit 0；Moments API suite `PYTHONPATH=services/business-api python -m pytest tests/business_api/moments -q` exit 0，119 passed / 1 既有 Starlette 弃用警告；`media-key-red.log`、`media-key-green.log`、`moments-api-suite.log` |
| 群公告/群名/群管理 | 新 banner/编辑/旧 topic 同文重发/账号切换/12 字场景均按缺失行为失败 | 六个群测试文件 90 passed、定向 Dart analyze 0 issue，代理独立记录 |
| 朋友圈 GIF/视频/警告 | 视频重签后仍联网、封面不见、错误样式无警告 icon；个人页视频账号上下文和草稿重开海报关联按缺失行为失败 | 修复后相关 25/25，个人页 26/26，账号清理/下载竞态测试通过；定向 analyze 0。Flutter 全量 4087 passed / 9 既有条件跳过；相册 GIF 修正后完整 `flutter analyze --no-pub` 仍 0 issue。 |
| HTML demo / UI registry | 新状态聚焦测试 0/3 | 聚焦测试通过、完整 frontend `npm test` 303/303，`python scripts/verify_ui_contract.py` PASS：32 components / 415 screens；复合 emoji 群名按字素限制。 |
| API 合同 | — | `python scripts/export_openapi.py --check` exit 0；完成上传响应新增稳定账号可命名空间化的 `media_cache_key`，与发布后 feed key 一致；GET 草稿从已验证视频引用派生同序稳定键，PUT 丢弃调用方伪造的键。两组 RED/ GREEN，最终 Moments API suite 119 passed / 1 既有弃用警告，309.57s。 |
| 版本与依赖 | — | `scripts/bump_version.ps1 -Version 0.4.10+2169` exit 0，版本契约 2 passed。正常 `flutter pub get --offline` 临时改变镜像 URL 及两个传递依赖；已恢复原锁，并以 `PUB_HOSTED_URL=https://pub.dev flutter pub get --offline --enforce-lockfile` exit 0 重新生成依赖配置。`pubspec.lock` SHA256 保持 `a2af1ef677f2bee3af4d012d15eb5dc2492d220bf66eabb27ccf62c17fd733fc`。最终候选 93 个源码/合同/测试文件哈希清单见 `source-manifest.json`，清单摘要 `279f7974c2491913b5739fde900e5c1d65111bba7a4a34e1e41f776507703815`。 |

## 规格与安全审查

先进行只读规格符合性审查，发现个人朋友圈列表/详情两个视频入口缺账号和可信源，已按测试先红后绿修复。HTML 群名复合 emoji 字素计数已修复，frontend 完整测试 303/303。第二轮质量/安全复审发现候选群公告相对 HEAD 的未提交明文发送回归：旧实现绕开 SDK 加密事件与加密附件路径。已依照既有群公告加密计划及 ADR-0060 的附件边界恢复 `room.sendEvent`、`prepareContentAddressedMedia` + `room.sendFileEvent`，新发布需要加密状态，公开旧公告只读，旧公开图片再次发布时重新加密。两组安全测试先红后绿，相关 98 passed / 9 条既有条件跳过、定向 analyze 0；root 独立领域/质量安全审查确认成员/管理员权限、公开 state 仅 event ID、正文/附件密钥留在加密事件、不修改协议或密钥恢复、无原始明文上传。后来发现公告相册误滤 GIF，针对性两例先红后绿，最终相关 99 passed / 9 条既有条件跳过、完整 Dart analyze 0。Flutter 4087/9 全量是在此最后一处局部改动前通过；依照影响规则复用未变部分，由最终群公告聚焦测试覆盖改动。此前另两次启动的全量 Flutter 与 verify 因审查返工主动中止，均不计通过。

服务端首轮从现网 `sha256:38ed2becf2b9f75a3d0dd46e51188c84c638092c57ffa002de6b2118b9165e59` 最小叠加四个 Moments 文件，API 镜像 `sha256:f89c02b36b575778bf04c31e107b2ff00bf922264de243fddbca2724aaf4db71` 通过双导入/协议/隔离 PG 后已部署。第二轮从该在线镜像只叠加 `service.py` 单文件，现用 API `sha256:f63cb266617819f5f407bba4bac0622fce4bfca83581f6e5ceb72f9c17d92f91`，worker 始终 `sha256:237162bea8f8b8f8e662daa35ed585b17ee16922fde2eec97ff478892f7860b4`。第二候选两导入路径源码哈希一致，刷新协议 API/worker 各 9/9、Moments ASGI 双路径各 5/5；隔离 PostgreSQL 16.9 恢复 136 表/224592 行、测试 5/5，原数据摘要不变。predeploy、精确 API-only release_guard、postdeploy 均 exit 0；生产 API healthy/restarts 0、其他 23 容器身份和启动时间不变、schema 0087。服务器及工作站经跳板 HTTPS ready 200 JSON，无授权 feed/draft 401，伪刷新 401，新 API 错误日志 0，临时 SOCKS 已关闭。证据在服务器私有目录 `/opt/starchat/releases/moments-media-20260924/`、`/opt/starchat/releases/moments-draft-cache-20260924/`；第二轮本地脱敏副本见 [server-draft-cache](artifacts/2026-09-24/group-moments-wallet-debug/server-draft-cache/)。

Android 0.4.10/2169 Debug 最终 APK 已由源码构建、apktool 2.12.1 常规 DEX/资源重建、16K alignment 和固定本地测试证书签名；[工件 JSON](<C:/Users/Administrator/.codex/visualizations/2026/09/23/01a0d059-a062-7cd3-b140-f324cc27a599/docs/verification/artifacts/2026-09-24/android-debug2169/artifact.json>) 记录 SHA256 `6168daef6120eb28344eb55d21bbab4a17b72375400807bc1bd1197ab1540a57`、145477931 bytes。apksigner v2/v3 通过、证书 SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff` 与用户测试身份一致；独立重解包确认 manifest 语义相同、339 个原生/资产条目不变、27317 smali class 不变、资源/Dex 正常重建。最终包有 arm64 Debug kernel、无 AOT libapp.so。

首次 2169 构建在安全/规格复查发现公告相册误滤 GIF 后主动中止；已生成的旧源码 APK 与部分解包结果移至同一证据目录的 `attempt-1-aborted/`，未签名、未安装。修正后最终源码 APK 哈希与该中间件不同；最终 Android 构建 exit 0 并产出上列签名工件。

MI 6 (`cbd0156b`) `adb install -r` 保留数据覆盖安装 exit 0，设备已安装版本 0.4.10/2169，设备 base.apk SHA256 与最终包一致，首次安装时间仍为 `2026-09-20 09:35:24`，启动 `MainActivity` 成功、进程 PID 1898，安装后 crash buffer 0；[设备验证 JSON](<C:/Users/Administrator/.codex/visualizations/2026/09/23/01a0d059-a062-7cd3-b140-f324cc27a599/docs/verification/artifacts/2026-09-24/android-debug2169/device-verification.json>)。用户真机行为验收仍待用户反馈。

## 完整脚本结果与影响范围补跑

`pwsh -NoProfile -File scripts/verify.ps1` 原次执行退出 1，原因是 `tests/mobile/test_ui_component_registry.py` 两个断言仍把 HTML 演示屏幕数写为 403，而本次注册表与独立 UI 合同均已更新为 415。原脚本在该处之前完成：仓库/部署政策、模板、配置渲染通过，infra 144 passed，Getui 28 passed（2 既有弃用警告），Matrix Bot 9 passed，Business API/Worker 2735 passed / 77 条条件跳过（1 既有弃用警告，1647.75s）。移动边界初次 106 passed / 1 skipped / 2 failed，失败仅上述旧计数。

将两个断言更新为 415 后，移动边界复测 108 passed / 1 skipped。依照变更影响复用已通过且输入未变的前段门禁，后段单独补跑：Flutter/HTML UI 合同 32 components / 415 screens、Business API 导入、267 个 Python AST、Alembic 唯一 head 与离线 upgrade、OpenAPI drift、Docker Compose render 全部通过，`verify-remainder.ps1` exit 0。原完整脚本不记为一次 exit 0；[原日志](artifacts/2026-09-24/group-moments-wallet-debug/verify-complete.log)、[边界复测](artifacts/2026-09-24/group-moments-wallet-debug/mobile-boundary-green.log)、[后段补跑](artifacts/2026-09-24/group-moments-wallet-debug/verify-remainder.log) 分开保存。此次任务文档及 `current-state.md` 新增段落的相对链接检查通过；全量扫描 `current-state.md` 的历史段落另有 16 个既有失效链接，与本次改动无关。

## 阶段计时（Asia/Hong_Kong）

| 阶段 | 时间 | 说明 |
| --- | --- | --- |
| 恢复基线与并行分工 | 2026-09-24 06:20 起，约 06:35 完成 | 读取工作流/现状、设备与源码基线；root / 群 / 朋友圈 / HTML 分文件所有权 |
| 客户端与 API 增量、红绿 | 约 06:25–07:19；命令精确时间见日志 | 并行实现与专项复测，包含第二轮草稿键、安全回归及 GIF 筛选返工 |
| 规格与质量安全复审 | 约 06:45–07:19 | 发现并修复个人朋友圈上下文、公告明文回归、HTML 字素差异和相册 GIF 过滤 |
| 服务端两段隔离验证与切换 | 约 06:35–07:19 | 两次均从当时生产镜像最小叠加，双路径/协议/隔离 PG 与双侧 HTTPS 门禁；详情以服务器 JSON 时间为准 |
| Flutter 与 HTML 门禁 | 约 07:10–07:19 | Flutter 全量 2m35s；最终 GIF 增量聚焦及 analyze；frontend 303，通过后不重复未变输入 |
| APK 构建与设备安装 | 最终 APK 07:20:40–07:22:13；MI 6 07:22:48–07:23:04 | 前一候选在 GIF 规格差异后中止并隔离保留；最终包/真机 SHA 同一 |
| 仓库验证与定向补跑 | 约 07:10–07:40 | Business API/Worker 1647.75s；旧 403 屏幕断言导致原脚本 exit1；修正后移动边界及后段门禁通过 |

阶段墙钟与返工耗时最终按工具日志和区间并集更新，缺失精确时刻保持“约/未知”，不伪造分钟数。
