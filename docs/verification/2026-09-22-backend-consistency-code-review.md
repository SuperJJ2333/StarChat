# 第二轮后端一致性与后台代码复审

日期：2026-09-22（Asia/Hong_Kong）。范围：用户提供的 ZCode 第二批实现；依据实际工作区代码，不依据聊天中的 PASS 声明。授权：本地复审、纠错、隔离验证和下一步提示词；未部署、未发真实短信、未访问报价供应商、未处理真实资金或生产数据。

## 结论

原实现存在可复现的认证、资金一致性、群主转让和后台交互缺陷，不能按原总结判为全部闭环。本轮已做针对性修正；群主转让开关仍默认关闭。Flutter、真实短信及真实 Matrix 联测仍未完成。本轮测试不证明 500 人群聊容量或真机流畅度。

## 基线与变更身份

- main HEAD：`878dcc372393e8e7bc97684b017c9e9cc4b8953c`；原有 115 个相关未提交/未跟踪文件作为输入，原始 SHA256 见 [input-snapshot.json](artifacts/2026-09-22/consistency-review/input-snapshot.json)。快照时间 2026-09-22 01:30:15 +08:00。
- 隔离工作树 `.worktrees/consistency-review`，分支 `codex/consistency-review-20260922`。没有复制生产 .env；测试使用示例配置。未改他人 Flutter 或客服派发相关文件。
- 回填清单、回填前/后 SHA256 与冲突检查见 [applied-changes.json](artifacts/2026-09-22/consistency-review/applied-changes.json)；源码、工具和依赖身份见 [final-inputs.json](artifacts/2026-09-22/consistency-review/final-inputs.json)。原件保存在同工件目录 before-corrections/。回填不是部署或提交。

## 已复现并修复的问题

| 优先级 | 原问题及后果 | 修正与回归证据 |
| --- | --- | --- |
| P1（认证高风险） | 阿里云 Code=OK 被当作验证码通过，忽略 VerifyResult；用途/签发关联不足 | 仅 PASS + 对应 OutId 可通过；Send/Check 共享用途/challenge 派生 SchemeName。UNKNOWN/FAIL 错误尝试；供应商异常不消费。sms-second-red/green.log |
| P1 | 邮箱旧联系方式验证误走短信；发送失败仍留下可验证 challenge；区域拼出的 endpoint 与钉版 SDK 不符 | 邮箱本地校验；待发送不可验证，失败或被取代不激活；中央 endpoint、明确大陆国家码与数字验证码参数。短信 6 项原失败及 endpoint 原失败已补回归 |
| P1（构建阻断） | pyproject 增加 SDK，但 Docker 安装的 requirements.lock 未更新；--no-deps 安装后 pip check 会缺依赖 | 补 SDK 及解析出的传递依赖精确版本，保留原有依赖版本；新增项目声明与锁文件一致性回归；实际 Docker 构建验证 |
| P1（资金一致性） | 活动绑定仍可取消/拒绝；直接登记可换掉命令；已执行但登记失败释放绑定可能导致再次充值 | BOUND/NEEDS_REVIEW 阻止取消与换单，双向核对凭证；不确定登记继续占用绑定。原 9 项回归失败已修复 |
| P1 | 终态 state_active=0 的唯一约束只允许一条历史；无最终金额/率快照；登记与冲正竞态 | 0081 将终态置 NULL，保留历史并增加快照；公开账本锁接口统一锁顺序；失败转换审计/Outbox；恢复优先执行完成项。PostgreSQL 并发及冲正先后顺序通过 |
| P1 | 转让发送只构造 users，覆盖其他 ACL；目标/请求者校验不足；多个意图可先后改 Matrix；成功后的业务提交可能使用过期观察 | 深拷贝完整 power_levels，只变更旧/新群主条目；完整领域复验；每房间一未决意图；完成前再次确认；读锁次序修正 |
| P1 | 发送返回丢失后回 VALIDATED 自动重发；恢复 worker 没遵守关闭开关 | 不确定结果保留 MATRIX_PENDING，过期恢复只读确认，否则 NEEDS_REVIEW；端点和 worker 同开关。故障注入原 8 项失败已修复 |
| P1 | 储备汇率读取宽泛吞异常，数据库失败可能伪装成无报价 | SQLAlchemy 错误明确 503，非数据库编程错误继续暴露；缺新鲜报价沿用原 fail-closed 规则。2 项红/绿回归 |
| P2 | 目录 API 用 POST 调 PUT 接口；刷新传入函数但未调用；登记按钮不区分待审批；管理列表看不到停用条目 | 正确 PUT/ID 路径及严格载荷；实际执行刷新；明确 PENDING_APPROVAL 与 CREDITED/REGISTERED；系统管理员目录包含停用条目。新建 3 项前端红/绿 + API 权限断言 + 真实 DOM 交互 |

短信判断依据为 [阿里云 CheckSmsVerifyCode 官方契约](https://help.aliyun.com/en/pnvs/developer-reference/api-dypnsapi-2017-05-25-checksmsverifycode)，不是把 API 调用成功等同认证成功。下载核对的 SDK 为 pyproject 钉版 2.0.0，wheel SHA256：`59fe474f2356e65c453ef4b235bd0fbf2827f2971196fbcbb8bb2769610507dd`。未在生产安装或真实发送。

## 规格符合性、质量及安全复审

先对照用户明确规则检查手机号换绑、单位/汇率、0.5%/0.1%、满 10 人与任期规则，再检查并发、状态、权限和外部结果不确定性。未引入客服调价新增审批、群钱包或额外人数门槛。认证与充值由独立复审者复现/修正，根任务核对代码及实际 PostgreSQL 结果；群转让由根任务修正后独立复审锁顺序，随后完成实库验证。受保护变更记录在 ADR-0075、0077、0079 的 2026-09-22 修正中。

当前变化未获取生产启用批准；此处“质量审查通过针对性回归”不等于真实供应商/Matrix 安全验收完成。未读到的生产配置不做推断。

## 验证记录

工具：Windows、PowerShell 7.6.5、Python 3.12.10、Node 22.22.2；本地 Docker PostgreSQL 16.9-alpine；Node 浏览器专项使用 Playwright + headless Edge。所有日志保留完整输出，首轮失败不覆盖。

| 检查 | 结果 | 工件 |
| --- | --- | --- |
| 手机/供应商专项 | 54 passed；endpoint 修正后综合预检 61 passed | consistency-review/sms-second-green.log、preflight.log |
| 充值/账本相邻回归 | 48 passed；新增最终回归 14 passed | consistency-second-review/recharge-ledger-green.log、recharge-final-regressions.log |
| 群领域/协调专项 | 52 passed；独立复审 13 passed | consistency-review/groups-green.log、group-independent-review.log |
| 储备异常、后台目录 API | 2 passed、1 passed；后者新增 GET 管理权限/停用条目/用户过滤断言单独执行 | reserve-green.log、admin-directory-green.log |
| frontend 全量 | 230 passed，0 failed | frontend-full.log |
| SDK 构建依赖 | 原缺锁回归 1 failed/2 passed；补锁后 3 passed；实际 Docker build/pip check exit 0；禁网容器中生产客户端/请求工厂 PASS | sdk-lock-red.log、sdk-lock-green.log、docker-build.log、sdk-runtime.log |
| 浏览器实际 DOM | PASS，零 JS 异常；实际 AdminApi 发 PUT，绑定/登记/刷新及停用后仍可读取均验证 | admin-browser.cjs、admin-browser-result.json、admin-panel.png |
| PostgreSQL 迁移 | 在线空库 0001→0081 PASS；另外 SQLite 0079→0081 带历史数据专项通过 | postgres-migration.log、充值最终回归 |
| PostgreSQL 群并发 | 16 请求 1 意图/15 冲突；一次 Matrix 替身写入；幂等重放锁顺序 PASS | postgres_group_probe.py、postgres-group.log |
| PostgreSQL 充值并发 | 16 次登记仅 1 审计/Outbox/入账；一案件/多命令及多案件/一命令均 1 成功/15 冲突；登记阻塞冲正、先冲正拒绝登记；保留 3 条历史 | postgres_recharge_probe.py、postgres-recharge-probe.log |
| scripts/verify.ps1 | **PASS，exit 0；API/worker 2404 passed / 58 skipped / 1 warning** | verify-full.log、verify-exit.txt |

表中未列前缀的工件均在 [consistency-review/](artifacts/2026-09-22/consistency-review/)，充值红绿工件在 [consistency-second-review/](artifacts/2026-09-22/consistency-second-review/)。专项数量有重叠，不能求和当作独立用例总数。

本地测试镜像 `starchat-review-local:20260922`，image ID `sha256:c57ef839953833ff3df449fa412a0c0b4f804b9ff7f2729de3c1ae5bc18c40b0`，未发布。SDK runtime 使用 `--network none`；PostgreSQL 测试容器已停止并自动删除。

完整门禁开始后补群模块/模型注释、文档、已有目录 API 测试的额外断言，以及缺失的 SDK 锁定依赖和构建契约测试；没有更改业务方法行为。目录 API 新断言和构建契约测试单独通过，依赖变更另做真实 Docker 构建与 SDK 工厂验证；不虚构重新全量执行。浏览器使用本地 API fixture，不是完整后端联调；截图使用测试容器外壳，不是全站视觉验收。

完整门禁时间：2026-09-22 01:47:39—02:10:59 +08:00（日志创建/退出记录），后端 pytest 1355.06 秒。Infra 143、Getui 28、Matrix Bot 9、mobile 84 通过，UI 契约/AST/离线迁移/OpenAPI/Compose PASS。Getui 的 Starlette/httpx 与 Pydantic class Config 两条、后端一条 Starlette/httpx 现有弃用警告保留，未为本轮功能调整依赖消除警告；本轮另外新增的构建契约测试独立 3 passed。

## 发布前仍未验证/未完成

1. 群转让保持 `group_transfer_coordination_enabled=false`。真实 Matrix 回读和外部改权竞态、旧客户端治理、NEEDS_REVIEW 人工处置入口尚未验收。不能声称 Matrix 与 SQL 原子一致。
2. 真实短信签名/模板/发送/回传、动态 SchemeName 兼容性未验证；默认不开通。缺失配置或 SDK 保持失败关闭。
3. 后台仍需分页、历史/审计时间线和待核对处理工作台；Flutter 批次 3、Android/iOS 真机没有在本轮实现或验收。后台单面板及本地 DOM 通过不是全部 UI 完成。
4. 0081 必须先于新应用部署；部署前需对生产备份副本进行数据迁移与恢复演练。实库空库全链和本地历史数据测试不等于生产数据迁移验收。回退保留历史表/列，暂停相关入口及恢复 worker，不做 destructive downgrade。
5. 全量门禁中的 skip 项继续算未验证；容量、性能、真实短信与生产结果不由门禁数量替代。

下一步直接使用 [2026-09-22-zcode-next-step.md](../workflow/prompts/2026-09-22-zcode-next-step.md)，先补剩余流程及隔离联测，再接 Flutter，不重复实现已修正部分。
