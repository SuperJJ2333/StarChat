# 管理台候选：r2 生产基线补齐与 Worker 全量门禁

## r2 基线完整性

资料审计及朋友圈恢复包 r2 已于 2026-09-28 15:14:50 UTC 发布，当前 API 镜像为 `sha256:8015e9637fb33c3cf07995612ba1680dbdd3acec4705dee062803517d4bd26d3`；Worker 镜像保持 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`，schema 为 `0091_moment_video_posters`。管理台候选必须以此为基线，旧 v3 包作废。

首次管理台 API 全量从旧分支源码启动，在 18% 时主动中断，日志保留为 `business-api-full-interrupted-baseline.log`；此运行没有失败结论，不作为完整通过证据。随后与 r2 恢复工作树逐文件比较，发现 `api/client_diagnostics.py`、`api/performance_diagnostics.py`、`core/database.py`、`core/tracing.py` 为旧或不同字节，且缺少 `core/network_request_timeline.py`。从已发布恢复树复制这五个文件并逐个核对 SHA256，均与 r2 同字节；`app/main.py` 相对 r2 仅有本次后台响应守卫与中间件安装顺序差异。合并后的追踪、性能、钱包及用户目录 5 文件聚焦测试为 62 passed、1 条环境弃用 warning，见 `live-observability-merge-focused-2.log`。首轮未带缺失模块的测试收集错误留在 `live-observability-merge-focused.log`，不作为源码问题已通过的证据。

独立只读审计比较 r2 与管理台 `app/` 和迁移：22 个路径差异中 21 个为 A1–A5 与 `0092_admin_session_entry_mode`，唯一多余的 `modules/audit/writer.py` 是非本任务的 Worker 内部 publication 扩展，须排除 v4 API overlay。r2 恢复 manifest/payload 的八个修复目标均通过 SHA 复核；管理台树其中六个字节一致，`identity/models.py` 仅加入入口模式，`api/identity.py` 仅增加已批准的管理登录/客服改密行为，未丢恢复语义。完整 Business API 套件已从补齐后的树重新启动，结果单独记录。

补齐已发布性能诊断源码后，原生成 OpenAPI `--check` 如预期发现契约漂移（exit 1）；重新由当前 `create_app()` 导出后 `--check` exit 0，`test_openapi_contract.py` 4/4 通过，原始日志见 `openapi-after-live-observability.log`。这只更新生成契约，未再改运行时源码。

补齐基线后的管理台完整 Business API 首跑 exit 1：3029 passed、83 skipped、3 failed、1 条环境弃用 warning，耗时 2252.53 秒，原始日志 `business-api-full-baseline-r2.log`。失败全部是旧测试断言：管理台基线测试仍要求 0091 head；旧钱包分支测试仍要求 0088 head；客户端诊断测试未纳入 r2 已发布的三项服务端专用枚举值。先对三文件聚焦真实复现 RED（3 failed、165 passed、1 skipped，`baseline-test-assertions-red.log`），随后仅修改这三项测试：精确要求唯一 0092 且父修订 0091，保留 0088–0091 链和旧分支汇合断言，并对 16 个客户端枚举维持精确相等、只显式加入三项已发布服务端值。聚焦 GREEN 为 168 passed、1 skipped（`baseline-test-assertions-green.log`）。运行时及 v5 发布 payload 源码均未变；完整 API 第二轮结果另记。

## Worker 红绿

Worker 全量首跑 `business-worker-full-final.log`：195 passed、4 failed。三个失败为旧 handler 集合断言漏掉已存在的 `identity.account_credentials`；另一个钱包接线夹具缺已发布媒体 backend 配置和内部 publication handler。按实际运行接线只更新 `tests/business_worker/test_worker.py`、`test_wallet_operations_wiring.py` 的预期和 mock，未因这组失败修改 Worker 业务源码。重跑 `business-worker-full-pass-2.log`：199 passed、exit 0。生产 Worker 镜像仍以独立不可变镜像及实际导入路径进行双角色门禁；此本地测试不代替该门禁。

## 其他本地门禁

前端 Node 全量 345 passed；infra 全量 210 passed；OpenAPI `--check`、UI contract 32 components/433 screens、Alembic 唯一 `0092` head 与离线 upgrade、Compose `.env.example` 渲染、Repository/Deployment policy、TemplateTools、原 270 个 API/Worker Python 文件编译、补齐后 271 文件 AST 解析和 `git diff --check` 均 exit 0。`scripts/verify.ps1` 在隔离工作树缺 `.env`，按既有预检与证据复用规则未重复运行这个确定会停在 Matrix 渲染的整脚本；不能将分项门禁称作整脚本通过。完整 API、v4 发布器/禁网克隆与最终生产证据仍待写入正式验证报告。
