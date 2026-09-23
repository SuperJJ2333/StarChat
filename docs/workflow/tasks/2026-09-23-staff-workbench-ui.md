# 客服订单 UI 整理

## 恢复入口
- 用户授权：八项 UI 整理，先展示 HTML demo；追加充值/提现所有处理操作进入弹窗。
- 计划：`docs/superpowers/plans/2026-09-23-staff-workbench-ui.md`。
- 状态：实现完成，验证中；候选在 `.worktrees/staff-workbench-ui-20260923`，基线 1baaf36e。未发布。
- 所有权：root 负责页面/CSS/demo；notifications 与 identity 由两个独立子任务完成。未触碰主工作区其他任务。
- 更新时间：2026-09-23 +08。
- 下一步：读 `docs/verification/artifacts/2026-09-23/staff-workbench-ui/verify-exit.txt` 与 verify-retry.log 确认完整门禁结果；按 demo 反馈继续调整，未收到本批生产发布指令不发布。

## 验收台账
| ID | 场景 | 证据 | 发布 |
| --- | --- | --- | --- |
| UI-1 | 参考信息卡/刷新图标状态 | 浏览器+共享模块 | 未发布 |
| UI-2 | 明确列表范围/选中态/服务端 mine 分页 | frontend+identity15 | 未发布 |
| UI-3 | 管理员工具与普通客服主流程分离 | frontend | 未发布 |
| UI-4 | 新单铃铛/侧通知/历史不计数 | notification10+浏览器 | 未发布 |
| UI-5 | 用户昵称/畅聊号/处理入口 | identity15+浏览器 | 未发布 |
| UI-6 | 充值提现与待核对处理弹窗 | modal 红绿+浏览器 | 未发布 |
| UI-7 | 草稿保留/跨订单回执隔离 | frontend293 | 未发布 |

## 阶段计时
- 18:25 前调查与拆分，精确起点未知。
- 18:25–18:31 +08：身份投影红绿、通知专项、第一版 demo；identity green 50.52s。
- 18:31 首次完整门禁启动；中途会话结束，36%无最终退出码，不记成功。
- 18:50–19:16 +08：用户追加弹窗设计，实施、真实浏览器验证、独立复审及串单反馈修正。区间近似，非精确计费。
- 完整门禁后台重跑日志：verify-retry.log；frontend 最终单轮约2秒。

## 交接
- Demo：localhost:8155/admin-workbench-demo.html；服务器根目录为本工作树 frontend。
- 停止后可在该目录运行 `py -3.12 -m http.server 8155 --bind 127.0.0.1` 恢复。
- 完整说明：`docs/verification/2026-09-23-staff-workbench-ui.md`。
- 生产无更改，无需生产回滚；没有安装 APK。
