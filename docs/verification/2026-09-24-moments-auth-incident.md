# 0.4.6朋友圈/钱包/资料加载失败：生产刷新协议缺失

- 调查时间：2026-09-24 04:42–04:49 +08:00（结束以文件记录时间为近似，不作精确工时）。
- 用户反馈：所有0.4.6用户出现，朋友圈显示加载失败，同账号钱包/资料也失败。
- 只读调查，未修改业务代码、数据库、镜像、设备会话或发布配置。

## 确认根因

正式0.4.6来源12ded275的business_session_refresh.dart发送refresh_token与operation_id。该提交服务端MobileRefreshRequest和TokenService.rotate支持可恢复刷新协议。但实时生产API镜像8ca2962190f2中没有MobileRefreshRequest，/auth/refresh仍绑定仅有refresh_token且extra=forbid的RefreshRequest，TokenService.rotate也没有operation_id参数。

运行时模型校验：加入operation_id直接extra_forbidden。服务器通过正常TLS访问公网入口的合成无效凭证探针：带operation_id返回422 VALIDATION_ERROR；不带该字段返回401 REFRESH_TOKEN_INVALID，表明后者通过请求结构校验进入令牌验证。未读取/生成/冒用真实用户凭证。

近3小时有界日志统计：refresh422共350次（含本次1个合成探针）、refresh200共3次；moments/feed401共16次，200共5次。朋友圈路径未见500或相关异常堆栈。时间序列显示feed401伴随refresh422。日志仅保留白名单路由/状态汇总，见artifacts/2026-09-24/moments-auth-incident/probe.txt。

因果链：业务access token失效→客户端正常自动刷新→生产后端拒绝新版字段→不能拿到新access token→朋友圈/钱包/资料等业务API401→客户端通用加载失败。Matrix独立会话可能继续正常，所以不能用聊天可用证明业务登录正常。

## 发布边界与下一步

这是生产镜像与已发布客户端的协议不一致。此前2026-09-23-phone-wallet-live-restore.md记载已恢复该协议；当前运行事实再次缺失。具体是哪次后续镜像继承丢失，尚未逐镜像追溯，不把原因归给最近账单两文件或本轮2168安装。

本轮2168仅真机安装没有改生产；它也不能弥补服务端拒绝协议。重新登录最多临时获得新access token，之后仍可能复现。

正确恢复需沿既有ADR0080-mobile-refresh-recovery，核对当前数据库operation恢复字段和生产文件清单，恢复请求模型、可恢复轮换/重放处理及配套模型，而非简单忽略operation_id；应保持重用检测、设备撤销和会话安全。发布前隔离恢复验证同operation重试与不同operation重用、旧客户端兼容，以及朋友圈/钱包/资料鉴权。尚未进行生产修复或宣称恢复。
