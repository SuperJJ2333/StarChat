# 仅使用 Windows 和 iPad 配置 TestFlight

日期：2026-09-07。签名 IPA 0.3.47（6）已生成并成功上传 App Store Connect；Apple 处理状态与真机推送/通话尚待验收。

当前进度：用户已确认应用创建完成；五项 GitHub Secrets 已通过云端格式检查及 Apple API 应用读取验证，Bundle ID 确认为 com.liuhetong.liuhetongMobile。四项分发签名 Secrets 已写入并通过 macOS 钥匙串导入和有效签名身份验证。证据见 ../verification/2026-09-07-ios-secrets-check.md 与 ../verification/2026-09-07-ios-distribution-signing.md。APNs 服务凭据、实际 IPA 和真机行为仍未验证。

## 已确定的值

| 项目 | 值 |
| --- | --- |
| Apple Team ID | HY9Q7Q35S5 |
| Bundle ID（沿用源码，待 Apple 注册确认） | com.liuhetong.liuhetongMobile |
| App ID Description | ChatFlow |
| App Store Connect 应用名（需 Apple 接受） | 畅聊 ChatFlow |
| SKU（新应用内部编号） | chatflow-ios-001 |
| 平台 | iOS（覆盖 iPhone 和 iPad） |
| 主要语言 | 简体中文 |

## 1. Windows 浏览器注册 App ID

打开 https://developer.apple.com/account/resources/identifiers/list ，确认当前团队为 HY9Q7Q35S5。

点击加号，选择 App IDs → App，Description 填 ChatFlow，Bundle ID 选择 Explicit 并填写 com.liuhetong.liuhetongMobile。在能力列表启用 Push Notifications，继续核对并注册。

若 Apple 提示标识被占用，停止使用该候选值，先确定可注册的最终值，再统一更新工程、推送配置和描述文件；不能只改控制台。

## 2. 创建 App Store Connect 应用

打开 https://appstoreconnect.apple.com/apps ，选择加号 → 新建 App。按上表填写，Bundle ID 选择刚注册的标识。若尚未显示，稍候刷新并确认当前账号/团队一致。应用名称如不可用，按控制台提示确定名称。

创建应用记录不等于提交 App Store 审核；本次目标是 TestFlight 内部测试。

## 3. 准备云上传授权

App Store Connect → 用户和访问 → 集成 → App Store Connect API。首次由账号持有人申请 API 访问；通过后创建团队 API 密钥。仅用于上传和应用管理可用 App Manager 角色；若之后采用自动管理证书/描述文件，须另外核实并授予该流程要求的权限。

记录 Key ID、Issuer ID，下载 .p8 私钥并妥善保存。Issuer ID 与 Team ID 是两个不同字段，不能互填。私钥不发聊天、不放 Git 仓库。

具体操作：选择团队密钥（Team Keys），名称填 ChatFlow TestFlight，上传用途选择 App Manager。下载密钥后，在 https://github.com/SuperJJ2333/StarChat/settings/secrets/actions 点击 New repository secret，依次按下表添加名称与值。APPSTORE_PRIVATE_KEY 要填写包含 BEGIN PRIVATE KEY / END PRIVATE KEY 行的完整内容，而不是文件路径或文件名。不要使用 Repository variables 存放私钥，也不要把 .p8 作为普通仓库文件上传。Apple 只允许下载该私钥一次，应保留仓库外的安全备份。

完成后只需告知 Secrets 已配置，不需要把值粘贴到聊天。此步骤只完成上传授权；后续仍需分发证书和描述文件，不能立即据此运行现有签名工作流。

已有 GitHub 工作流读取以下 Actions secrets，可在仓库 Settings → Secrets and variables → Actions 中配置：

| Secret 名 | 内容 |
| --- | --- |
| APPLE_TEAM_ID | HY9Q7Q35S5 |
| IOS_BUNDLE_ID | Apple 最终注册的 Bundle ID |
| APPSTORE_KEY_ID | App Store Connect API 的 Key ID |
| APPSTORE_ISSUER_ID | App Store Connect API 的 Issuer ID |
| APPSTORE_PRIVATE_KEY | App Store Connect API .p8 文件全文 |

当前工作流还要求 IOS_CERTIFICATE_BASE64、IOS_CERTIFICATE_PASSWORD、IOS_PROFILE_BASE64、IOS_PROVISIONING_PROFILE_NAME，分别对应带私钥的分发证书、证书密码、分发描述文件和其名称。上述五项不足以使现有工作流成功签名。

只有 Windows 也能用 OpenSSL 生成 CSR/私钥，再通过 Apple 网页签发证书并制作 P12。2026-09-07 已在 C:/Users/Administrator/AppData/Local/ChatFlowSigning/HY9Q7Q35S5 完成 CSR、私钥、证书与描述文件验证，导出 ChatFlowDistribution-macos.p12 并配置四项签名 Secrets。目录仅当前用户及 SYSTEM 可访问；密码以 DPAPI 保存。后续复用该私钥，不重新生成覆盖。证据见 ../verification/2026-09-07-ios-distribution-signing.md。

## 4. 普通推送与来电

App Store Connect API 密钥用于上传/管理，不是 APNs 推送密钥。需在 Apple Developer 的 Keys 中另行准备 APNs 授权，并按实际选定的网关或 Firebase 配置保管到服务端。

相机/麦克风权限说明、通知授权、签名 entitlements、APNs 投递、PushKit/CallKit、后台音频是各自独立的环节。当前项目缺口和验收矩阵见 ../verification/2026-09-07-ios-ipad-readiness.md。不得将普通消息都作为 VoIP 推送，且来电唤醒方案必须维持 Matrix E2EE 边界。

## 5. 云构建和安装顺序

1. 修复 iOS 工程与工作流。现有工作流仍使用 macos-14，需要选择并验证满足当前上传要求的固定 macOS/Xcode 环境；修复签名设置、运行时配置、凭据前置检查、构建检查依赖、签名清理与产物留存。
2. 在云端先运行不需要发布凭据的编译和测试，再运行签名 archive/export，验证 IPA 的 Bundle ID、Team ID、最终 entitlements、描述文件与 SHA-256。
3. 上传构建到 App Store Connect，完成真实的加密出口合规问答、等待处理，在 TestFlight 中分配给内部测试组。
4. iPad 安装 TestFlight，接受邀请后安装。此路径无需提供 UDID、无需 USB 连接 Windows、无需开发者模式。
5. 真机允许通知、麦克风和相机；验证锁屏横幅/声音和前后台音视频通话。未通过实测前不能宣称完整交付。

## 当前安装下一步（等待签名构建及 Apple 处理完成）

Windows 打开 App Store Connect → 畅聊 ChatFlow → TestFlight。构建可用于测试后，在“内部测试”旁点 + 建立“iPad 测试”组，选择自己的账号作为内部测试员，将此次构建加入该组。在 iPad App Store 安装 Apple 的 TestFlight，打开邀请邮件并接受，再点击安装。

如果构建显示“缺少合规证明”，需按应用真实使用的 Matrix 端到端加密情况完成 Apple 的加密问答；不能为了跳过提示直接声明不使用加密。本次工作流仅上传测试构建，不提交公开 App Store 审核。

安装后用两个测试账号验证：消息前台接收、后台和锁屏通知的声音/横幅、点击定位会话、退出登录不再收到旧账号通知，以及语音/视频双向通话、麦克风/相机权限拒绝后重新启用。后台来电唤醒仍未通过验收，需独立验证 PushKit/CallKit 能力。

当前 APNs 密钥已安全部署服务器、Sygnal 保持运行，服务器至 Apple 的 TLS/HTTP2 通过；尚无真实 iPad 投递证据。云构建固定 Xcode 26.3 / macos-15 / Flutter 3.44.9。

## 官方资料

- App ID：https://developer.apple.com/help/account/identifiers/register-an-app-id
- API 密钥：https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/
- GitHub macOS 签名：https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications
- TestFlight 内部测试：https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers
