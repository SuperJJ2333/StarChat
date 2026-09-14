# 客服管理与窗口外人工补录生产发布

状态：2026-09-13 12:49+08生产发布与双侧HTTPS验收通过。未执行两笔充值的创建/审批/预检/入账请求；无生产管理员会话，未伪造登录。真机与实际业务审批由用户负责。

## 发布范围

- 基于当次现网 `sha256:eb14b5969f5a6953c17ef0186c99e195fbec606241172bc4c370edaa15137038` 增量构建，当前运行 `sha256:119e69710767af56613425341ed7e7920f5f1d9123d3926c8ee0139dd159ce1f`。
- 14个API镜像覆盖文件（包括0065/0066迁移及API内release_preflight），6个后台JS文件。客服管理、搜索派发、旧充值修复刷新与独立人工补录流程上线。
- 生产schema由0064升级为0066_manual_deposit_cases。新增表/收据列已查实。
- 发现生产compose原未设置BUSINESS_WALLET_MANUAL_REPAIRS_ENABLED，运行值默认false。因此本次另显式设true，使已授权人工修复流程可执行；manual_tron、钱包负责人、grant与其余配置原样保留。此前关闭开关会拒绝写入，但不是对用户历史每次失败原因的追溯证明。
- 未发布APP安装包或HTML设计演示页；APP客服后缀仍需具备该实现的客户端。保留本地109个非候选API文本差异，未整树构建；未纳入其他任务的兑换/提现字段、tokens及Flutter变更。

## Astra实际验收

代码由显式gpt-5.6-terra准备清单/发布工具，Astra检查现网差异、实际脚本及资金调用链，执行生产操作。最多两个执行者，未修改业务源码。

| 验收 | 结果 | 本任务日志 |
| --- | --- | --- |
| 已验收25输入hash | 无漂移 | accepted-input-drift.json |
| 候选构建 | 只FROM当次现网镜像+14文件overlay | build.log |
| 备份与隔离恢复 | PG16.9无网络容器恢复真实备份成功 | prepare.log、rehearsal.log |
| 0064→0065→0066演练 | 成功；原账本/收据行变更探测摘要不变，旧API ORM仍可读扩展schema | rehearsal.log |
| 候选Linux定向（审批/HTTP/PG并发约束/支持管理） | 55通过，24.79秒 | rehearsal.log |
| 候选旧充值/提现修复回归 | 25通过，4.01秒 | candidate-old-repair-tests.log |
| Astra发布脚本故障注入 | 15通过，0.642秒；中途静态失败与journal失败完整回退、开关恢复 | astra-release-final-15-tests.log |
| 本次25条接口/15个关联schema契约 | 相等 | prepare-precheck-final.log |
| 配置差异 | 仅API image与人工修复flag | prepare-precheck-final.log |
| 生产迁移/切换 | 退出0，只重建business-api | apply.log |
| 生产读回 | 14镜像文件+6静态hash一致，schema/flag/健康正常，4个匿名读取401；其他容器ID不变，无新Traceback | postcheck-result.json |
| 工作站HTTPS | 6静态文件hash及API JSON ready通过，TLS保持校验 | workstation-public-check.json |

已有本地前端199项、移动边界70项及综合证据按未变输入复用；未重复宣称原始verify.ps1整条退出0。本轮实际镜像在Linux运行80项针对性测试。未运行生产资金写入验收，不宣称真实两笔已到账。

## 审查返工与限制

Astra发现发布工具将write_static返回值赋给written，函数中途失败会丢失已替换列表；Terra改为共享列表并在替换前登记，主线程亲跑故障注入。初始开关校验只接受显式false，现网实际为缺失键/default false；修正后严格接受缺失或false，拒绝显式null/true，并验证回退原样恢复。

首轮契约脚本因从/verification执行而导入镜像内已安装旧包，修正验证进程PYTHONPATH=/opt/business-api；候选业务测试此前已显式使用此路径。广域契约又发现本地其它任务的ManualPayoutSnapshot兑换字段未上线，候选保留现网该模型；最终对本次客服、充值修复、人工补录及提现核对关联契约进行精确比对，没有为通过检查覆盖无关金融代码。失败日志均保留。

Docker旧builder弃用提示、隔离测试pip root提示和单服务compose的orphan提示原样记录；未升级生产工具链、未执行remove-orphans。行MD5仅作隔离恢复中的内容变更探测，发布包/文件/备份/候选绑定均用SHA256。

## 备份与回退

服务器私有目录 `/opt/starchat/releases/manual-deposit-20260913/`（0700），backup目录0700，数据库dump0600；数据库和含环境的compose未下载至工作站。

备份dump SHA256：`ccc5bc2c54dd83989fb169f88d8914f0ef8d937e0b48afe6a9ab1271f23af6fd`。候选包SHA256：`3f80ec80931d663120455587bc356e13f5fb32fd9769c90f2488ff700c5ef929`。

服务器执行 `python3 /opt/starchat/releases/manual-deposit-20260913/deploy_release.py rollback` 可在无未知漂移时恢复原镜像、原flag和静态备份。保留0065/0066扩展表、审计与财务历史，禁止破坏性downgrade。真实服务回退未执行；已完成脚本故障注入和旧ORM兼容验证。

隔离恢复容器已清理；本轮工作站19013 SOCKS已关闭并确认无监听。前一任务的本地测试残留未尝试清理。

## 时间与下一步

准备开始约12:32+08（精确首条工具时间未记录）；12:34完成现网源码/状态观察；12:44–12:48契约/开关核对与发布工具返工；12:48:50开始生产迁移，12:49完成切换及服务器验证，12:50完成工作站验证与隧道关闭。并行区间未重复累计。

用户刷新[生产后台](https://admin.liuhetong888.com/)，按[人工补录手册](../runbooks/manual-deposit-cases.md)完成钱包验证及业务审批。以最终EXECUTED和账本编号为成功依据，预检/审批本身不入账。

[任务记录](../workflow/tasks/2026-09-13-manual-deposit-production.md) · [发布计划](../superpowers/plans/2026-09-13-manual-deposit-production.md) · [原本地验证](2026-09-13-manual-deposit-cases.md)
