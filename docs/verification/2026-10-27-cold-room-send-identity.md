# 冷启动文字发送与本人归属：源码验收

## 范围与身份

用户批准：账号、目标和持久化队列就绪即允许文字提交；可靠落盘后显示右侧气泡；网络、权限、加密满足后按原事务 ID 发送；本人归属从首帧稳定；落盘失败保留输入并说明原因。

基线 6853790df944fa60543dba93164ab9128d17ad94；候选分支 codex/cold-room-send-identity-20261027，工作树 C:/Users/Administrator/.codex/worktrees/maintenance-completion/StarChat。本轮交付源码与验证，不打包、不安装、不合并、不推送、不发布提醒或变更官网下载。Android 2235 / iOS 2215 的既有发布身份未由本任务改变。主工作区原有改动不纳入本次提交。

已验证源码提交：7b6a894ba9b3a20e5ca43c19392b5c6cf251c8f6。后续提交仅补记该证据身份。

## 修复结果

- RoomPage 在历史加载开始前接入账号级 outbox；文字按钮和历史控制器解耦。提交先持久化，写入未完成不会出现新气泡；失败保留输入并提示。同一失败提交重试复用事务 ID，写入期间二次提交不重复建行。
- 历史未就绪时仅显示本页已落盘消息；恢复后由原控制器沿原事务接管。背景发送直接使用既有租约发送门禁，去除打开历史的前置操作。
- 时间线用已捕获且持续校验的账号身份判定本人；SDK userID 暂空时不把本人缓存归为他人。换号、epoch 变化、租约退役后的旧异步结果不得更新页面或放行发送。
- 本地 outbox v3 新增可空 text_metadata，保留 @成员、引用事件 ID 和选中文字；原正文、状态和 txid 不变。v1/v2 通过加列升级。前后台恢复/重试共享持久化内容，仍走权限和 E2EE 门禁。
- 本页同步捕获实际 ACK，迟到数据库读取不得把 sent 回退；没有数据库行不等于送达。manager 的 ACK 身份记录最多 512 项，无正文；本页早期投影最多 200 行。
- 发送意图在写入前登记，完成回调不重新拉回最新窗口。新正文、新引用保留；只移动光标不会留下已经提交的正文。历史失败时保留重试入口。

核心文件：apps/mobile_flutter/lib/features/matrix/room_page.dart、matrix_e2ee_client.dart、room_timeline_controller.dart；apps/mobile_flutter/lib/app_home.dart；apps/mobile_flutter/lib/core/outbox/ 下 message_send_scheduler.dart、outbox_message.dart、outbox_store.dart、persistent_outbox_manager.dart。未修改业务 API、资金、认证规则或加密算法。

## 验证与审查

证据根：D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-10-27/cold-room-send-identity/。日志仅使用合成消息及身份。Flutter 3.44.9 / Dart 3.12.2，独立 Python 3.12；原依赖锁未修改。native libolm/libsqlcipher 身份由 run-full.ps1 校验；相关输入保存在 full-inputs.json 与 locks.json。

| 检查 | 结果 |
| --- | --- |
| 原始根因 RED | red.log：10 PASS / 2 FAIL，历史阻塞与空 SDK 身份归属均复现 |
| 后台历史依赖 RED | red-background.log：1 FAIL；修复后同事务发送 PASS |
| 写入重试身份 RED | red-retry-tx.log：5 PASS / 1 FAIL；修复后沿原 txid |
| 规格审查修正 RED | 元数据/ACK 3 FAIL，编辑 2 FAIL，历史恢复/意图 3 FAIL；后续 GREEN 全部通过 |
| 定向综合 | final-focused.log：111 PASS / 0 FAIL |
| 最终质量修正 | red-quality-ack-nudge.log：3 FAIL；green-quality-ack-nudge.log：37 PASS / 0 FAIL |
| 完整 Flutter | full.log：6421 PASS / 9 诊断 SKIP / 1 Windows 清理失败，exit1；analyze exit0，source_stable=true |
| 未变输入的失败文件复跑 | staged-cleanup-rerun.log：12 PASS / 0 FAIL，exit0；覆盖原失败用例 |
| 诊断开启变体 | diagnostics-final.log：9 PASS / 1 默认关闭分支 SKIP，exit0；该默认分支已在完整运行执行 |
| 移动边界 | mobile-delivery.log：404 PASS / 1 Ruby 条件 SKIP，exit0 |
| UI 契约 / 仓库策略 | 34 组件 / 540 页面 PASS；Repository policy PASS |
| scripts/verify.ps1 | 独立 Python/依赖/UTF-8 stdin/业务导入预检 PASS；随后缺少候选 .env，exit1，未继续后端/部署全套门禁 |

独立审查按规格→质量/安全顺序执行。规格审查的五项发现均红绿修复；质量审查的 ACK 淘汰竞争和意外拍一拍意图变更已红绿修复，同时消除重复发送意图调用。审查后的最终修正由根代理用测试及输入校验验收，不将其表述为独立复审通过。

早期 first-full.log 为 6406 PASS / 9 SKIP / 6 FAIL，包含铃声测试真实时钟竞争、测试 fixture 缺少账号，以及四项 widget 清理级联；后续只调整测试时钟和 fixture，通话运行代码不变。两次 lint 尝试和质量审查中断的中间全量均保留原件，不覆盖为通过。

最终完整运行（16:33:38–16:41:29，UTC+08:00）的唯一失败发生在 startup_projection_staged_capture_test.dart 的临时目录删除：Windows errno32，目录仍被占用。未修改该测试或运行源码，单独复跑整个文件 12 项全部通过。按移动交付流程的未变输入复用规则，保留完整运行其余 6421 项通过证据并补入该文件结果；**原 full.log 仍是 exit1，不称为一次全绿全量**。所有默认实际执行用例均获得通过证据；9 项诊断条件跳过另以开启变体覆盖。

delivery-validation.json 确认交付的 16 个 Dart 文件与最终 full-inputs.json 逐项一致，无输入漂移。最后移动边界、UI 契约、仓库策略均重新执行；测试、审查后修正和交付的运行源码身份相同。后台/基础设施源码未修改，缺少 .env 的总门禁未重试或替换生产配置。

## 平台与维护限制

- 尚未打包或执行 Android/iOS 真机验收。下次构建后应覆盖：杀进程后直接进群、慢历史/离线输入、连续提交、@和引用、切号、磁盘不足、发送后上滑、历史失败重试及后台回到前台。
- 本轮没有改变设备数据库。未来安装新版本首次打开 outbox 时将升级 v3；旧二进制的 v2 打开器不支持直接降级。回退构建需保留 v3 兼容读取或采用受控数据恢复，不能靠删除数据库处理。
- 缺少 .env 的总验证和 Ruby/CocoaPods hook 验证不得记为通过；iOS 构建、签名与物理设备验证需对应环境。
- 候选工作树没有 .codegraph。本轮通过当前候选源码和可执行测试分析，未把主树的过期索引或本报告冒充 CodeGraph 动态结果。

后续执行入口：[任务记录](../workflow/tasks/2026-10-27-cold-room-send-identity.md) · [实现计划](../superpowers/plans/2026-10-27-cold-room-send-identity.md)。
