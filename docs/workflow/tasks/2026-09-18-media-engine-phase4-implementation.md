# 2026-09-18 ChatFlow Media Engine Phase 4 — Full Implementation（服务端 Media Platform）

## 恢复入口

- 目标、用户授权来源及边界：用户直接指令（本会话）。**实现 ChatFlow Media Platform**（Phase 4 Full Implementation）：
  能力完整实现 + 数据渐进迁移（**Strangler Pattern**，禁止一次替换全部旧媒体）；严格遵守 Phase 3.1 的
  ADR-001…ADR-006。
  **禁止**：全球明文去重；E2EE 服务端处理（解密/转码/生成变体）；迁移 Matrix 媒体字节；修改 Matrix 协议；
  实现 Avatar 接入（明确延期）；分片上传的实际传输（本阶段只做接口）；一个巨大提交（要求 5 个可构建提交）。
  不做 `git pull`、不构建 APK/IPA、不真机、不部署。
- 关联计划/ADR：[Phase 3.1 冻结](../architecture/media-engine-phase3-freeze.md)（ADR-001…006）、
  [Phase 3 设计](../architecture/media-engine-phase3-server-design.md)、
  [Phase 3 审计](../architecture/media-engine-phase3-server-audit.md)、
  [实施报告](../verification/media-engine-phase4-implementation.md)。
- 当前状态：**实现完成 + 门禁通过（本地）**；未构建 APK/IPA、未真机、未部署。
- 负责人、工作树、文件所有权、源码commit：本地工作树 `D:\pythonProject\outsource\StarChat`，分支 `main`，
  起点 `afe70a1c`。5 个提交：`bf397700`、`88a6b0c7`、`850935e7`、`e8284bbb`、`dfbcf4f6`。
  新增文件全部在 `services/business-api/app/modules/media/**`、`services/business-api/app/api/media_platform.py`、
  `migrations/versions/0069_media_platform.py`、`tests/business_api/media_platform/**`。
- 最后更新时间（含时区）：2026-09-18（Asia/Hong_Kong）。
- 下一条具体操作、必要输入、阻断的验收ID：下一阶段（客户端接入 + 分片上传实现）需要：
  ① 客户端按新端点接入（上传/读取/选档/501 特性探测）；② 部署侧确认 nginx/Synapse 上传上限与维护令牌；
  ③ 生产配置独立 `BUSINESS_MEDIA_URL_SIGNING_SECRET`。当前**无阻断项**。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A1 | MediaObject 存在 | `models.MediaObject` + `0069` 迁移 | `test_media_domain_core.py`（关系与字段） | 未发布 | — |
| A2 | MediaBlob 存在（含 digest_kind/storage_key） | `models.MediaBlob` | 同上 + 摘要/隔离规则用例 | 未发布 | — |
| A3 | MediaVariant 存在（图片/视频枚举） | `models.MediaVariant` + `domain.VariantKind` | Test 8 选档用例 | 未发布 | — |
| A4 | MediaReference 存在（含 permission_scope） | `references.MediaReferenceService` | Test 2 + 幂等/隔离/释放用例 | 未发布 | — |
| A5 | MediaGateway 存在（resolve/authorize/resolveVariant） | `gateway.py` | `test_media_gateway.py` | 未发布 | — |
| A6 | Matrix Adapter 存在且不迁移字节 | `MatrixMediaGateway`（解析 + 委派） | Test 5 + "零对象"断言 | 未发布 | — |
| A7 | Moments Adapter 存在 | `BusinessMediaGateway` + `MomentsMediaBridge` | Test 6 + 端到端桥接用例 | 未发布 | 客户端未接入 |
| A8 | Authorization 存在（Grant + fail-closed） | `grants.py` + `authorization.GrantAuthorizer` | Test 3/4 + 撤销/到期用例 | 未发布 | — |
| A9 | Signed URL 存在（绑定 5 项 + 服务端 TTL） | `signed_urls.py` | 令牌绑定/篡改/过期/TTL 用例 | 未发布 | — |
| A10 | Lifecycle 存在（ACTIVE/ORPHAN/DELETING/DELETED） | `lifecycle.py` + `references.py` | Test 7 + 恢复用例 | 未发布 | — |
| A11 | GC 可运行（dry-run/audit/recovery） | `MediaGarbageCollector` + `media_gc_runs` | GC 8 条用例 | 未发布 | — |
| A12 | 旧 Matrix 媒体仍可读 | `MatrixMediaGateway` 委派 + 双读 | Test 5/6 | 未发布 | — |
| A13 | 不迁移旧字节 | 无搬移/重加密/事件重写 | 零对象断言 + 既有 106 条回归 | 未发布 | — |
| A14 | 不破坏 E2EE | 平台不接收明文摘要/密钥；E2EE 变体不由服务端生成 | 摘要种类用例 + Matrix 适配器设计 | 未发布 | — |
| A15 | 不修改 Matrix 协议 | 未触碰 `third_party/**`、无上传接口改动 | `git diff --stat` 范围检查 | 未发布 | — |
| A16 | 不创建第二套缓存 | 复用既有私有对象目录 + 新键空间；无缓存层 | 代码审查 + 设计说明 | 未发布 | — |
| A17 | 不实现全球去重 | `MediaDedupPolicy` 对开启跨用户明文去重直接抛错 | `test_dedup_policy_refuses_cross_user_plaintext...` | 未发布 | — |
| A18 | analyze 通过 | 仅服务端改动 | `flutter analyze` → No issues found | 未发布 | — |
| A19 | test 通过 | 71 条新测试 + 无回归 | 见"版本与证据" | 未发布 | — |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源commit | 包名/签名渠道 | 文件位置及SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| business-api（本地 pytest） | 无镜像构建（未部署） | `bf397700`…`dfbcf4f6` | 无 | 代码在 `services/business-api/**`；合同重导出于 `packages/api-contracts/openapi/liuhetong-v1.yaml`（+2028 行） | 无 |

- 命令与退出码（本次实际运行）：
  - `flutter analyze` → **No issues found!**（21.3s）
  - `flutter test --timeout 120s` → **3120 通过 / 0 失败（退出码 0）**
  - `py -3.12 -m pytest tests/business_api/media_platform -q` → **71 通过**
  - `py -3.12 -m pytest tests/business_api/moments tests/business_api/media -q` → **106 通过**（未改其中任何文件）
  - `py -3.12 -m pytest tests/mobile -q` → **70 通过**（333.27s）
  - `npm test`（`frontend/`）→ **209 通过 / 0 失败**
  - `py -3.12 scripts/export_openapi.py --check` → 先 drift（新增 14 条路由）→ 重新导出后 **PASS**
  - `pwsh -NoProfile -File scripts/verify.ps1` → **`Verification: PASS`（退出码 0）**
    （内部子步骤：`Alembic migrations: PASS`（含 `0068_red_packet_fee -> 0069_media_platform`）、
    `OpenAPI contract: PASS`、Docker Compose render 通过）
  - **门禁发现并修复 2 个真实问题**：G1 两条基线用例把迁移 head 钉死在 `0068_red_packet_fee`（已按
    expand-migrate 流程更新为 `0069_media_platform`，17 条相关用例重跑通过）；G2 OpenAPI drift（已重新导出）。
- 依赖锁与工具版本：未新增任何 Python/Dart 依赖（`pyproject`/`pubspec` 未改动）。
- 未执行项：真机、构建、部署、负载压测（需按下一阶段计划执行）。
- 复用依据：Phase 2/3 的全量门禁在同工作树更早批次完成；本次改动为服务端 Python，Flutter 侧仅回归复验。

## 阶段计时

| 阶段 | 开始 | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 4.1 domain core + 迁移 + 测试 | 2026-09-17/18 | 2026-09-18 | 主动 + 1 次返工（dedup 归属语义：`dedup_eligible` 曾被误用为"策略允许复用"，导致明文对象占用跨用户摘要槽；已修正为独立谓词） | — | `bf397700`；22 条测试 | 4.2 |
| 4.2 gateway + variant resolver + upload 接口 | 2026-09-18 | 2026-09-18 | 主动 | — | `88a6b0c7`；12 条测试 | 4.3 |
| 4.3/4.6 reference + lifecycle + GC | 2026-09-18 | 2026-09-18 | 主动 | — | `850935e7`；15 条测试 | 4.4 |
| 4.4 authorization + signed URL | 2026-09-18 | 2026-09-18 | 主动 + 1 次返工（单次使用用例改为真正的端到端；清理测试辅助类） | — | `e8284bbb`；14 条测试 | 4.7 |
| 4.7 Moments 桥接 + 端到端 | 2026-09-18 | 2026-09-18 | 主动 + 1 次返工（遗留读者要求 `moments/` 键前缀 → 引入命名空间前缀并保留隔离地址） | 与既有 moments/media 回归并行 | `dfbcf4f6`；8 条测试 | 报告 |
| 合同重导出 + 门禁 | 2026-09-18 | 2026-09-18 | 工具等待（Flutter 2.6 min、pytest 5.5 min、verify.ps1 长跑） | Flutter 与文档撰写并行 | 见"门禁执行记录" | 交付 |

总墙钟：跨 2026-09-17/18 一个夜班完成。返工：3 次（均为实现期自查发现，非外部反馈），已记录在报告中。

## 交接与回退

- 已确认根因/已排除假设：
  - 已确认：Phase 3 审计的结论可直接作为实现前提（E2EE 明文摘要不可得、业务侧零治理、旧媒体无需迁移）。
  - 已确认（实现期发现）：**平台不能为 E2EE 附件建立对象身份**（无权威摘要、客户端摘要不可信）
    ⇒ Matrix 适配器只做"解析 + 授权委派"，并把该限制写入报告 R1。
  - 已确认（实现期发现）：既有 Moments 读者只识别 `media://moments/...` 前缀与"COMPLETED 上传行"
    ⇒ 桥接通过"命名空间前缀 + 记账行指向平台键"实现**零代码改动**接入。
  - 已排除：为省存储而开启跨用户明文去重（策略层直接抛错，测试锁定）。
  - 已排除：把 Avatar 或 E2EE 转码塞进本阶段（违反冻结）。
- 待办及验收失败项：无失败项。下一阶段：客户端接入、分片上传实现、CDN/对象存储（均属 DEFERRED）。
- 已发布与仅候选的区别：**仅候选**（本地提交，未构建未部署）。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：迁移 0069 为 expand-only，回退只需 `alembic downgrade` 或停用新端点；
  字节与既有表未被修改，旧路径随时可用。
- 运行中CI/命令/自己创建的隧道（无凭据）：无。
- 下次恢复先检查的事实：① `git log` 是否含 5 个提交；② `export_openapi.py --check` 是否仍 PASS；
  ③ 生产是否配置了独立媒体签名密钥与维护令牌；④ `media_gc_runs` 是否有异常增长。

## 门禁执行记录

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 1 | `flutter analyze` | No issues found!（21.3s） |
| 2 | `flutter test --timeout 120s` | 3120 通过 / 0 失败（退出码 0） |
| 3 | `py -3.12 -m pytest tests/business_api/media_platform -q` | 71 通过 |
| 4 | `py -3.12 -m pytest tests/business_api/moments tests/business_api/media -q` | 106 通过 |
| 5 | `py -3.12 -m pytest tests/mobile -q` | 70 通过（333.27s） |
| 6 | `npm test`（`frontend/`） | 209 通过 / 0 失败 |
| 7 | `py -3.12 scripts/export_openapi.py --check` | drift → 重新导出 → PASS |
| 8 | `pwsh -NoProfile -File scripts/verify.ps1` | **Verification: PASS（退出码 0）** |

未执行项：真机、APK/IPA 构建、部署、负载压测（200/500/1000 VU）——不在本阶段范围且未获授权。
