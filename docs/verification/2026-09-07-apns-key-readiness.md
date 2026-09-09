# APNs 密钥准备及 iOS 首次构建

用户提供 Key ID Z7TMWKHXMS，服务为 Apple Push Notifications service，团队 HY9Q7Q35S5。

本机文件 C:/Users/Administrator/AppData/Local/ChatFlowSigning/HY9Q7Q35S5/AuthKey_Z7TMWKHXMS.p8 已确认存在，可解析为 P-256 EC 私钥，本机 ECDSA SHA-256 签名及验签成功。未输出私钥内容，文件仍在仓库外受 ACL 保护的目录中。此检查不能证明 Key ID 与 Apple 登记一致、密钥未被撤销或设备可收到推送；真实 APNs 请求与真机验收尚待完成。

现有 Sygnal 模板支持 APNs，但客户端的 iOS pusher 实际仍从 Firebase 取得 FCM token，不能直接送给 APNs pushkin。接入前必须补齐原生 APNs token 提供方与点击路由，核对 gateway app_id 和 Apple topic，不能仅部署 .p8 就宣布推送成功。

基于既有 Flutter E2EE 与发布阶段实施计划的云构建步骤，建立 codex/ios-build-preflight-20260907 分支，提交当前移动端源码快照和独立无签名构建工作流。使用临时 Git index，未修改用户当前分支或真实暂存区；快照相对 origin/main 为 8 个移动端/工作流文件，没有后端业务改动或签名秘密。

- 初始提交：3bcc27b1d3ccae7255a29170850648152041e332。
- 初始运行：https://github.com/SuperJJ2333/StarChat/actions/runs/34097613784
- 环境：Flutter 3.44.9 / macos-15。
- 初始运行因 Firebase Swift Package 最低 iOS 15 要求失败，修复部署版本；第二轮根据编译错误修复 Flutter implicit engine messenger API。

## 已验证进度

- 未签名 iOS 真机 Release 编译成功：https://github.com/SuperJJ2333/StarChat/actions/runs/34099508857 ，提交 11b69f9c14922d3ecc7ac3d77907ec54cd86fb98。
- 本地推送测试 35 项通过；分析 lib/app_home.dart、lib/features/push、test/features/push 无问题。
- 退出登录竞态回归：在 getToken 等待过程中销毁 provider，旧实现返回失效 token（red），修复后返回 null（green）；额外 gated start/dispose 测试通过。AppHome 在 await 前持有 provider，异步边界检查 mounted，防止退出后注册旧会话。
- 仓库 scripts/verify.ps1 已运行至 Verification: PASS，日志位于 artifacts/2026-09-07/ios-build/repository-verify.log。
- 签名与 TestFlight 工作流已配置：导入现有分发身份与生产 APNs profile，生成 IPA，校验签名/entitlements/iPad/权限，保留 IPA 后上传 App Store Connect。上传不等同于 Apple 处理完成或测试员可安装。
- 生产 SSH 经直接连接及现有代理均超时，尚未部署 APNs 密钥到 Sygnal。没有声称消息送达或锁屏来电通过；这些仍需服务器及真实 iPad 验收。

## 服务器连接恢复后的部署

用户确认服务器在线后，使用 OpenSSH `-F NUL`、既有专用 SSH key 直连 207.56.8.8:23421 成功。既有 Sygnal 容器 starchat-sygnal-1 使用 matrixdotorg/sygnal:v0.15.1。

- 密钥部署到 /opt/starchat/data/sygnal/apns/AuthKey_Z7TMWKHXMS.p8，目录 0700、文件 0600；容器内路径 /data/apns/AuthKey_Z7TMWKHXMS.p8。
- 在原配置中新增 com.liuhetong.mobile.ios，保留原 placeholder；topic=com.liuhetong.liuhetongMobile、team_id=HY9Q7Q35S5、key_id=Z7TMWKHXMS、platform=production、push_type=alert、convert_device_token_to_hex=false。
- sygnal.apnspushkin 日志级别 WARNING，避免上游 INFO 输出设备 token。
- 原配置备份 /opt/starchat/data/sygnal/apns/sygnal-before-apns-20260907.yaml，0600。需要回滚时恢复该文件内容到 sygnal.yaml 并重启单一 Sygnal 容器。
- 重启后容器 running，RestartCount=0。本地端口和公网 /_matrix/push/v1/notify 均对空 devices 请求返回 Sygnal 的预期 400 `No devices in notification`，证明路由到达；不是推送投递成功。
- 从容器到 api.push.apple.com:443 的受信 TLS 与 ALPN h2 成功；未提交伪造设备 token，尚未验证 APNs key 的实际投递认证。
- 新签名工作流固定 Xcode 26.3（云默认16.4不满足现行上传要求），运行 https://github.com/SuperJJ2333/StarChat/actions/runs/34103447049 ，提交 1ed6a927a37ab2779c45347e4eeea69aa3528ac1。签名身份导入已通过，IPA 尚在构建。

## 签名与上传完成

上述运行全部步骤 success。Xcode 26.3，版本 0.3.47，构建号 6。IPA 导出、codesign --verify --deep --strict、生产 aps-environment、团队/Bundle ID、get-task-allow=false、iPad UIDeviceFamily 和麦克风/相机声明均通过校验。

2026-09-07 09:10:42 UTC 上传日志：`UPLOAD SUCCEEDED with no errors`。此结论表示 Apple 接收上传，尚未读取 Apple processing/TestFlight 可用状态，也未完成加密合规问答或分配测试组。

本地 IPA：artifacts/2026-09-07/ios-build/signed-34103447049/liuhetong_mobile.ipa。
SHA-256：3dfec20d781eeb114ed0c441937fff1384ec43387afaad32097935804b409f9e，与云端签名后校验输出完全一致。

完整运行日志：artifacts/2026-09-07/ios-secrets-check/job-101683059466.log。存在 Flutter 关于依赖尚未采用 Swift Package Manager 的未来兼容提醒；当前工具链采用兼容路径完成构建，不是构建错误。上传 artifact action 的 Node url.parse 弃用提示属于 action 运行时，未阻断产物或上传；后续工具链升级需复核。

剩余验收：Apple 处理/加密问答/内部测试组、iPad 实际安装、真实 APNs 投递、前后台和锁屏通知点击、语音视频权限与通话、锁屏来电唤醒。普通 APNs 接入和签名成功不代表 PushKit/CallKit 已完成。
