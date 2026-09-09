# iOS 分发签名资产验证

日期：2026-09-07。结果：本机验证通过，GitHub macOS 钥匙串实际导入通过。尚未构建或上传 IPA。

## 文件与检查

签名资产只保存在仓库外 C:/Users/Administrator/AppData/Local/ChatFlowSigning/HY9Q7Q35S5，其目录 ACL 仅当前用户及 SYSTEM 可访问。

- distribution.cer 与原 CSR 私钥匹配；Apple Distribution，团队 HY9Q7Q35S5。
- 证书有效期：2026-09-07 07:15:26 UTC 至 2027-09-07 07:15:25 UTC。
- 证书 SHA-256：d354ebdd20426c83a4e6f960586bbb981d9889278c63326ec67fbf10978cfeeb。
- 验证证书到 WWDR G3、Apple Root 的签名及有效期；CA 文件通过 Apple 官方 HTTPS 下载。Apple 专用 critical submission extensions 采用白名单和 ASN.1 NULL 内容断言，未知 critical extension 拒绝；标准 EKU/KU/CA 属性单独检查。
- ChatFlow_AppStore.mobileprovision 的 CMS 签名与 Apple 根证书链通过；名称 ChatFlow_AppStore。
- application-identifier 为 HY9Q7Q35S5.com.liuhetong.liuhetongMobile；团队匹配。
- DeveloperCertificates 包含此次证书；描述文件有效期至 2027-09-07 07:15:25 UTC。
- get-task-allow=false，无 ProvisionedDevices、无 ProvisionsAllDevices；符合 App Store 分发类型。
- aps-environment=production；这是签名权限验证，不是推送投递验证。

## P12 与 GitHub

生成 48 字节随机密码，使用 Windows DPAPI 保存至本机 p12-password.dpapi。未将密码、私钥或证书材料打印到日志或写入仓库。

初次 P12 使用现代默认封装，本地解析成功，但 macOS security import 失败。按 cryptography 官方兼容性说明改为 PBESv1 SHA1/3DES PKCS12 封装和 50000 KDF rounds，生成 ChatFlowDistribution-macos.p12。RSA 签名私钥和 Apple 证书保持不变，P12 round-trip 验证通过。P12 的保管依赖目录权限、DPAPI 密码、GitHub Secrets 加密和 TLS，而不单独依赖兼容 P12 封装。

通过 GitHub 公钥与 PyNaCl sealed box 加密写入，并检查元数据存在：

- IOS_CERTIFICATE_BASE64
- IOS_CERTIFICATE_PASSWORD
- IOS_PROFILE_BASE64
- IOS_PROVISIONING_PROFILE_NAME

## 云端证据

- 工作流分支：codex/ios-secrets-check-20260907-151818。
- 提交：0cd579a6c81ac1558f82c35be679a6de5958b41c。
- 运行：https://github.com/SuperJJ2333/StarChat/actions/runs/34096621360
- 第一次尝试：Apple API 校验成功、描述文件校验成功，macOS P12 导入失败。
- 更新兼容 P12 Secret 后仅重跑失败 job，最终 completed / success。
- Verify Apple signing assets in macOS keychain：success。
- 实际通过 macOS security import、set-key-partition-list、find-identity -v -p codesigning，找到与目标证书匹配的有效签名身份。
- 临时钥匙串、P12 和描述文件在 finally 中清理；工作流不 checkout 仓库、不构建应用、不上传 TestFlight。

## 后续

签名和上传授权准备完毕。仍需 iOS 工程修复、APNs 服务凭据和推送通话实现、实际 IPA archive/export 以及 iPad 实测。不宣称已完成 Apple 在线撤销状态的独立检查。

官方兼容性依据：https://cryptography.io/en/latest/hazmat/primitives/asymmetric/serialization/
