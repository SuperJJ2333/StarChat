# 第二轮后端一致性代码复审任务

## 恢复入口

- 授权：用户要求检查 ZCode 第二批修改、发现问题及时纠正，并提供下一步 prompt。范围为本地实现和验证，无生产部署、真实短信或真实资金。
- 批准计划：`docs/superpowers/plans/2026-09-21-pricing-auth-redpacket-group-program.md`；ADR-0075/0077/0079 的本轮修正解释安全与一致性实现，不改商业规则。
- 工作树 `.worktrees/consistency-review`，分支 `codex/consistency-review-20260922`，基线 HEAD `878dcc372393e8e7bc97684b017c9e9cc4b8953c`。复审输入 115 个文件；按 SHA256 安全回填，仅覆盖本轮差量。
- 文件所有权：短信实现由 sms_second_review，充值/账本由 recharge_second_review 顺序实施并释放；根任务负责群协调、worker 开关、储备异常、admin API/面板、契约和集成。没有两个代理同时编辑同一文件。
- 当前状态：专项及完整门禁通过（exit 0，2404 passed/58 skipped），代码修正完成；按回填清单交接，未发布。
- 下一步：按 2026-09-22-zcode-next-step.md 完成待核对流程与隔离联调，再接 Flutter；生产与真实通道验收继续独立。

最后更新：2026-09-22 02:11 +08:00。

## 验收台账

| ID | 场景 | 当前证据 | 发布/真实依赖 |
| --- | --- | --- | --- |
| AUTH | 供应商验证结果、challenge 隔离、邮箱换绑、发送失败 | 54 专项 + endpoint/综合 61 PASS | 未发真实短信 |
| MONEY | 命令唯一绑定、登记失败保留、不可取消、历史与冲正 | 48 相邻 + 14 新回归、PG 六场景 PASS | 未操作真实资金 |
| GROUP | ACL 保留、成员/任期、单意图、未知结果、worker 开关 | 52 专项 + 独立 13、PG 16 并发 PASS | flag 默认关闭；真实 Matrix 未测 |
| ADMIN | PUT/刷新/权威状态/停用目录 | frontend 230、目录 API、浏览器 fixture PASS | 未发布，完整 UI/后端联调待办 |
| MIGRATION | 0081 保留历史/快照 | PG 在线 0001→0081、SQLite 有历史迁移 PASS | 生产备份副本未测 |
| BUILD | SDK 进入 Docker 锁文件 | 构建契约 3 PASS；真实镜像 build/pip check 与禁网 SDK 工厂 PASS | 本地镜像，未发布 |
| GATE | 完整 verify | exit 0；2404 passed / 58 skipped；其他门禁 PASS | skip 项不算通过 |

## 证据及阶段计时

完整详情、命令结果及工件索引见 [复审报告](../../verification/2026-09-22-backend-consistency-code-review.md)。原始基线和最终回填均保存 SHA256。工具版本与依赖身份见 final-inputs.json；本地执行，无 CI run ID。

| 阶段 | 开始/结束（+08:00） | 结果/时间来源 |
| --- | --- | --- |
| 输入快照 | 2026-09-22 01:30:15 | input-snapshot.json UTC 转换；早期读取精确耗时未记录 |
| 专项红/绿、独立复审 | 快照后至完整门禁前后 | 耗时以各 pytest 日志为准，不能相加当总墙钟 |
| 完整门禁 | 01:47:39—02:10:59 | verify-full.log/进程退出记录 |
| PostgreSQL 与浏览器 | 完整门禁期间并行 | 单独日志，无真实外部依赖 |
| 回填与交接 | 02:11 后执行，以清单精确时间为准 | applied-changes.json 精确时间 |

## 交接与回退

- 根因及修正见报告；历史失败保留，不用成功覆盖失败轮次。未运行生产或真实渠道。
- 新迁移头 0081；保持群协调关闭。回退只能先停相关写入/恢复任务并保留追加历史，禁止删除绑定/账本历史。
- isolated PostgreSQL 容器 `starchat-consistency-review-pg` 仅用于测试，现已停止并自动删除，不保留外部端口。没有生产隧道。仅保留本地测试镜像，ID 见验证报告。
- 下一批执行 [ZCode prompt](../prompts/2026-09-22-zcode-next-step.md)：待核对流程、管理端工作台、隔离真实依赖联测、Flutter；不重做已修正代码。


## 2026-09-22 追加：第三轮批次 1 完成（处置流程/分页时间线/隔离 Synapse 联测）

- 充值 NEEDS_REVIEW：review-queue / timeline / review(retry|release) 端点与服务方法；release 服务端核证"调整被拒/缺失/已冲正"，证据不足 409——超时不视为失败。契约测试 4 项。
- 转让 NEEDS_REVIEW：transfer-intents 时间线（群主或管理员）+ review(confirm_applied|fail_unapplied)；confirm 仅凭权威状态既成事实；fail 仅凭旧群主仍持唯一最高权确证未应用。契约断言并入协调套件。
- 案件分页（稳定游标）+ 绑定状态投影 + 面板"待核对队列/案件历史（下一页禁用）"扩展；node +2。
- 隔离真实 Synapse 联测通过（本地 Docker `starchat/synapse:v1.132.0-dedup.1`）：真实注册（镜像自带脚本）/建房/协调推进/权威回读确认/ACL 保持/换主/desync 观测。2 passed。期间修正脚本注册交互（stdin）、模型导入序。
- 阿里云真实通道前置清单交付（无凭据，未验收）。
- 门禁：受影响专项 451 passed；frontend 232 passed；后端全量 **2411 passed / 58 skipped, exit 0**；verify.ps1 见 artifacts/2026-09-22/verify-exit.txt。
- Flutter 批次 3 未动工（如实）。


## 2026-09-23 追加：阿里云真实通道接入 + 后台工作台补全（第三轮复审后批次）

- 用户移交凭据（.env）与测试号；SDK 2.0.0 本地安装；中央 endpoint 可达（区域被工作站网络重置）。
- 真实 SendSmsVerifyCode：签名通过、到达阿里云，被 **RAM 403 Forbidden.NoPermission** 拒绝（缺 dypns:SendSmsVerifyCode）。适配器新增 SMS_SEND_REJECTED 分类（区别网络超时），回归 14 passed。**等用户 RAM 授权后重发**；正确码/错码/OutId 验收顺延。
- 后台：时间线详情查询 UI、转让意图查询与复核 UI（真实 AdminApi 路由 + 403/404/409 如实展示）。
- 证据：[验证](../../verification/2026-09-23-after-third-review-batch.md)。
