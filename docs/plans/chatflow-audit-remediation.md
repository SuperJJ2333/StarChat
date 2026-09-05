# ChatFlow 审计修复计划（27 项）

## Goal
按 `docs/ChatFlow_Codex_审计修复Prompt.md` 完成 27 项审计发现的实际修复、自动化验证与交付记录；保留既有成果（图库视频/封面、通话、来电链路修复）；不 pull/reset、不 push、不部署。

## Context
- 审计基线 `35cd07e`（仅说明来源）；当前工作区为其后继（含 e7bd02e 已推送的上一轮修复）。
- 后端 FastAPI 模块化单体（services/business-api + business-worker + getui-bridge）；客户端 Flutter（apps/mobile_flutter）。
- 隔离测试：pytest（.venv）+ 隔离 PostgreSQL（initdb 临时集群 127.0.0.1:55432，见下"复现命令"）；Flutter：flutter test。

## Constraints
- E2EE 边界、Decimal 资金、平衡分录、幂等、审计；不删测试/降断言/吞异常/伪造成功。
- 优先局部修复；增量迁移；不动生产。

## Done when
- 27 项逐项有代码改动或反证，配套回归测试通过，`docs/reports/chatflow-audit-remediation-result.md` 与 `docs/testing/chatflow-manual-acceptance.md` 完成。✅ 2026-09-05 完成。

## 批次
1. 资金/账号隔离：F01–F06、A04、U04 ✅
2. 推送/后台任务：P01–P03、C02–C05 ✅
3. 功能闭环：A01–A03、U01–U03 ✅
4. 容量/媒体：C01、F07、M01–M04 ✅

## 27 项跟踪表（最终）

| # | 级别 | 状态 | 验证 |
|---|---|---|---|
| F01 红包/转账统一事务 | P1 | 已修复并验证 | PG 注入异常整体回滚 ×2 + 并发同键 ×1 + 合并退款 ×1（tests/business_api/audit_pg/test_f01_f02_transactions.py） |
| F02 调账单执行幂等 | P1 | 已修复并验证 | PG 并发不同 HTTP 键 ×1 + 重试同交易 ×1 + 崩溃重试 ×1 |
| F03 充值事件/补记账 | P1 | 已修复并验证 | PG 低确认→阈值/同事件重放/同 txid 新事件/乱序/半程恢复 ×3 |
| F04 提现订单唯一范围 | P1 | 已修复并验证 | PG 跨用户同键/载荷冲突/回调按 ID+legacy 歧义拒绝 ×2 + 路由 409 |
| F05 提现失败补偿闭环 | P1 | 已修复并验证 | PG FAILED 补偿一次/重复回调/乱序成功/UNKNOWN 不退/resolve 幂等 ×3 |
| F06 群红包房间成员授权 | P1 | 已修复并验证 | 成员/非成员/退群/发起人/专属矩阵 ×5 + 路由 403 ×1（真实路由发起） |
| F07 钱包历史分页 | P2 | 已修复并验证 | PG 120 条翻页无重无漏 + 用户隔离 ×2 + 索引迁移 0037 |
| A01 充值地址接口 | P1 | 已修复并验证 | 路由级首次分配/复用/隔离 + 迁移 0037 + 生产 503 门禁 |
| A02 提现回调路由分发 | P1 | 已修复并验证 | 路由级提现事件推进 + 未知类型 400 + 坏签名 401 |
| A03 鉴权刷新超时边界 | P2 | 已修复并验证 | 会话代数（迟到刷新不恢复）×1 + 登出 8s 时限实测 ×1；8s/20s 每段超时为实时常量（见报告限制） |
| A04 沙箱/生产钱包门禁 | P1 | 已修复并验证 | 生产资金入口 503/只读照常 ×1 + 占位密钥拒绝 ×1 + worker 门禁 |
| P01 推送临时失败返回200 | P1 | 已修复并验证 | 桥接 503 重试语义 ×3（网络/5xx/限流码）+ 限频资格回滚 |
| P02 个推401刷新不可达 | P1 | 已修复并验证 | 401/10001→刷新一次成功 ×1 + 二次 401 不循环 ×1 + 并发刷新合并（锁） |
| P03 event_id_only 来电分类 | P1 | 当前代码已满足并有证据 | 桥接 type 缺省→message 唤醒（既有测试）+ 客户端唤醒→同步→解密→来电链路（native_call_coordinator 12 例 + call_ui_manager 7 例，上一轮） |
| C01 异步入口同步阻塞 | P1 | 已修复并验证 | 登录整段线程池卸载（既有登录测试全过）+ 桥接并发分发 < 串行 75% 实测 ×1；p95/p99 负载数据未采集（见报告限制） |
| C02 Outbox 主题/消费者 | P1 | 已修复并验证 | 主题过滤领取 ×1 + 死信收割/宽限/重放 ×1 + 全生产主题契约枚举 ×1 + 有界退避死信 ×1 |
| C03 维护任务异常中断 | P1 | 已修复并验证 | 钱包维护抛错不中断 ×1 + 周期调度/恢复清零 ×1 |
| C04 推送注册/注销竞态 | P2 | 已修复并验证 | create 在途注销→收敛+补偿删除 ×1 + dispose 后不重试 ×1 |
| C05 前台服务资源清理 | P2 | 已修复并验证 | start 失败 stop 释放锁/取消看门狗 ×1 + 交错平衡 ×1 + 从未启动契约 ×1 |
| M01 文件发送内存预检 | P1 | 已修复并验证 | 超限在 readAsBytes 前拒绝 ×1 + 不存在明确错误 + 并发槽 |
| M02 语音播放 generation | P2 | 已修复并验证 | A 慢 B 快只播 B ×1 + stopAll/dispose 后不 play ×1 |
| M03 媒体缓存原子写 | P2 | 已修复并验证 | 截断判损坏→删除→重下修复 ×1 + 空文件 ×1 + 并发写合并 ×1 |
| M04 缓存字节限额 | P2 | 已修复并验证 | 字节加权 LRU ×1 + 失败不占预算 ×1 + 磁盘软/硬配额（LRU 回收，代码+文档） |
| U01 提现按钮提交互斥 | P1 | 已修复并验证 | 快速双击只创建一单 ×1（真实客户端路径）+ 持久化订单键 |
| U02 提现页生命周期 | P2 | 已修复并验证 | 提交期间退出无异常 ×1 + 串行轮询终态停止 ×1 |
| U03 充值确认数文案 | P3 | 已修复并验证 | /wallet/config 服务端阈值 → 客户端统一展示（路由测试 ×1 + 客户端接线） |
| U04 朋友圈缓存账号隔离 | P1 | 已修复并验证 | A/B 命名空间隔离 + 登出只清当前账号 ×2 + 迟到写保护（代码） |

## 进度日志
- 2026-09-05 11:00：任务启动，工作区核对（基线 e7bd02e）。
- 2026-09-05 11:20：隔离 PostgreSQL 集群就绪（initdb 临时目录，127.0.0.1:55432）。
- 2026-09-05 12:30：批次 1+2 后端代码完成；隔离 PG 18/18。
- 2026-09-05 13:30：Flutter 批次 3+4 代码完成；C04/C05/M02/M03/M04/M01/U01/U02/U04/A03 测试逐项通过。
- 2026-09-05 14:00：全量验证——pytest 业务 311 通过（迁移 head 与 OpenAPI 契约同步后）、桥接 28 通过、隔离 PG 18 通过；flutter analyze 无问题、flutter test 846+2 通过；Kotlin compileStandardDebugKotlin BUILD SUCCESSFUL。
- 交付文档：docs/reports/chatflow-audit-remediation-result.md + docs/testing/chatflow-manual-acceptance.md。

## 隔离 PostgreSQL 复现命令（Windows）
```
PG="/c/Program Files/PostgreSQL/18/bin"
D=/tmp/chatflow_audit_pg
"$PG/initdb" -D "$(cygpath -w $D)" -U audit --auth=trust -E UTF8
# 启动（分离）：
powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c','%TEMP%\start_audit_pg.cmd' -WindowStyle Hidden"
# start_audit_pg.cmd：pg_ctl -D <data dir> -l <data dir>\pg2.log -o "-p 55432" -w start
"$PG/createdb" -h 127.0.0.1 -p 55432 -U audit chatflow_audit
RUN_POSTGRES_TESTS=1 PYTHONPATH="services/business-api;services/business-worker/app" \
  .venv/Scripts/python.exe -m pytest tests/business_api/audit_pg -q
```
