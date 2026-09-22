# 短信实测后与后台工作台代码复审

用户授权检查并纠正 ZCode 修改；用户已确认短信服务验证完成。本轮没有读取/复制真实凭据、再次发短信、调用生产或处理真实资金。测试号码仅按已验证状态登记，不存入工件。

## 基线与范围

隔离工作树 `.worktrees/sms-workbench-audit`，分支 `codex/sms-workbench-audit-20260922`。146 个相关工作区输入的 HEAD/时间/SHA256 见 [input-snapshot.json](artifacts/2026-09-22/sms-workbench-audit/input-snapshot.json)。使用 .env.example，没有复制主目录 .env。既有 ZCode 摘要全绿不作为本轮正确性证明。

## 已确认并修正

| 优先级 | 问题 | 修正与复现 |
| --- | --- | --- |
| P2 | SMS 用异常文本包含 isv.ValidateFail 推断错码；网络/配置描述含该字符串也扣次数，而结构化 code 存在但文本没有时反而不扣 | 只读 SDK 结构化 code 精确匹配；Forbidden/403 同样不解析任意描述；兼容响应体 isv.ValidateFail。5 项针对性失败转绿 |
| P2 | 连续查询案件/房间，较慢旧响应覆盖时间线或追加旧意图按钮；不能明确当前案件身份 | 请求代次检查，丢弃过期成功和失败结果；时间线显示 request_id |
| P2 | 转让处置未禁用重复操作，确认/失败可并发发起；刷新与在途响应缺少协调 | 每个意图单个在途命令，成对禁用按钮，实际回执显示 stage/error，切换查询后不覆盖当前状态，结束恢复当前行按钮 |
| P2 | 新增时间线/转让 UI 没有新增对应测试，原 235 个前端通过不能证明其正确 | 增加真实 AdminApi 路由、异步竞态、503 错误、重复点击、空输入回归，并运行浏览器 DOM + HTTP fixture |
| 文档 | 旧 RAM 403 被当作当前阻断，关闭开关时已有意图可复核的描述错误；记录保留真实 OTP 明文 | 明确短信已由用户确认，关闭开关仍拒绝所有复核写入；脱敏两条 OTP，区分供应商校验与本地次数验证 |

独立复审发现空输入查询提前增加代次，导致有效请求被丢弃/按钮无效；新增失败回归后，将代次推进放到输入校验之后。没有修改商业规则、资金状态机、迁移、API 契约或生产开关。

## 验证

- SMS 新回归最初 5 failed；适配器及相邻回归 33 passed，见 sms-red.log / sms-green.log。
- PhoneOtpService + 真实适配器离线集成：网络/配置错误仍为 5 次；精确 TeaException 错码后为 4/3/2/1/0；第六次在本地拒绝，不再调用供应商。所有失败均未消费 challenge。见 probe_sms_attempts_result.json，含源码哈希。这是 SQLite 顺序集成，不是生产或 PG 并发。
- 前端初始 3 个竞态/重复点击失败，后补刷新恢复/空查询回归各一次失败，均保留。最终 npm --prefix frontend test：240 passed / 0 failed。
- Edge 实际 AdminApi + DOM：最新案件/房间、关闭开关 503、处理中按钮、非终态回执、终态无操作按钮通过，零 pageerror。见 browser-result.json；使用本地 HTTP fixture，不冒充真实业务后端联测或完整视觉验收。
- 完整 scripts/verify.ps1：PASS，exit 0；后端 2449 passed / 58 skipped（跳过项仍未验证）。

工件统一位于 [sms-workbench-audit](artifacts/2026-09-22/sms-workbench-audit/)。财务及群权威模块没有改动，复用前轮实际 PG/Synapse 证据，不再造数。独立领域与质量审查批准本轮 SMS 分类修正；UI 空输入反馈已处理并测试。

## 交付边界与下一步

修正仅本地，未发布。短信供应商正向验收以用户确认和原实测追记为准，不重复申请 RAM 授权或要求验证码。Flutter 注册/登录/换绑仍未实现/真机验收；下一阶段使用[已更新的下一步 prompt](../workflow/prompts/2026-09-22-zcode-after-third-review.md)独立推进客户端。转让协调开关继续关闭；500 人压测、生产数据恢复与部署不在本轮。

回填清单及前后哈希见 [applied-changes.json](artifacts/2026-09-22/sms-workbench-audit/applied-changes.json)，最终输入身份见 [final-inputs.json](artifacts/2026-09-22/sms-workbench-audit/final-inputs.json)。
