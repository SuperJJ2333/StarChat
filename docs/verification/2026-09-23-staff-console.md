# 客服后台五项反馈验证（2026-09-23）

基线 f43ec78a；候选位于独立工作树 `.worktrees/staff-console-20260923`。本任务不包含其他任务的移动端、诊断或红包修改。未发送真实验证码、未操作生产资金。发布状态以末尾追加记录为准。

| 验收 | 实现与证据 | 当前状态 |
|---|---|---|
| 三入口选中变色 | 原按钮及主题色，aria-pressed；浏览器实际切换 | 本地通过 |
| 常规客服登录不重复验证码 | /auth/staff-login，密码+已开通客服；首次开通 email/phone 选择；邮件 worker 按所选通道复核 | 本地通过 |
| 同款运营概览 | 同一汇总接口与页面，四指标、趋势、点钻总量；未授予管理员明细或写权限 | 本地通过 |
| 订单免额外操作密码与验证 | SupportOrderSessionAuthorizer，仍校验会话/角色/身份、认领、凭证、审批、幂等与提交前状态 | 本地通过 |
| 客服隐藏 USDT 入口 | 前端过滤以及 context 不预加载 wallet | 本地通过 |

认证/概览最终专项：67 passed，248.01 秒，`artifacts/2026-09-23/staff-console/reviewed-backend.log`。前端最终：280 passed/0 failed，`frontend-final2.log`。订单专项参见 orders/ 下原始日志（最终34通过，扩展回归134通过/4项PostgreSQL条件跳过与已修夹具失败保留）。完整 verify 正在执行，不能提前判通过。

规格审查后进行质量安全审查：独立复审发现混合 SUPER_ADMIN+客服身份可绕过管理员验证码；已在锁内签发会话之前拒绝此入口，回归通过。另发现延迟 CAPTCHA 图片错误会禁用客服登录；已忽略其他模式的旧错误，红绿证据保留。浏览器发现 hidden 被 display:grid 覆盖，改用登录页作用域样式；首次使用 !important 被既有契约拒绝，已按契约移除且280项全绿。管理员钱包二次验证未改。

浏览器本地 fixture 验证 login / staff / activation 状态、邮箱手机选项、4项概览+趋势+总量，以及无 USDT 菜单。使用真实页面函数，API为替身；不作为真实客服生产登录证据。demo 路径 `artifacts/2026-09-23/staff-console/{browser,overview}.html`。

生产预备：备份约22MB留服务器0700任务目录；候选覆盖10个Python文件、完整350文件哈希比对通过；数据库head仍0087，隔离恢复及upgrade head前后原有表行哈希一致。首次恢复恰逢PostgreSQL临时初始化停库，保留失败日志，等待目标库可连接后重试成功。生产尚未切换。

磁盘恢复：旧任务4个APK中间文件校验SHA后移动归档至 C:/Users/Administrator/.codex/StarChat/docs/verification/artifacts/2026-09-23/support-feedback/android-2162/；源/目的均保留索引，final.apk未移动。被拒绝的临时目录递归清理未执行、未重试。

17:42 隔离本地PostgreSQL追加：充值持久认领/两小时恢复及提现独立进程竞争，4 passed（9.56秒）。连接仅127.0.0.1:25486；充值新建staff_console_orders_20260923库，提现使用既有专用support_payout_review库随机schema；生产数据库未参与。
