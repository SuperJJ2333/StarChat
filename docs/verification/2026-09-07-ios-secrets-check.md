# Apple 上传 Secrets 验证

日期：2026-09-07。结果：成功。

通过本机 Git Credential Manager 的既有 GitHub 登录读取仓库 Secret 元数据，确认 APPLE_TEAM_ID、IOS_BUNDLE_ID、APPSTORE_ISSUER_ID、APPSTORE_KEY_ID、APPSTORE_PRIVATE_KEY 全部存在。未读取或输出其保存值。

为用户请求的实际有效性检查，在独立远端分支 codex/ios-secrets-check-20260907-151818 增加仅执行配置校验和 Apple GET 请求的 GitHub Actions 工作流。没有修改 main、构建应用、上传 TestFlight、创建证书或更改 Secrets。工作流不 checkout 仓库代码，不安装第三方包，GITHUB_TOKEN permissions 为空，仅使用 Node 内置 crypto 和 fetch；私钥仅通过环境变量注入，JWT 动态掩码，输出固定检查结果，不打印 Apple 响应正文。

- 提交：2f616a5a8a4fb36af2606b6b0d609d46b5cdd5c9
- 运行：https://github.com/SuperJJ2333/StarChat/actions/runs/34095057537
- 工作流结果：completed / success
- 校验步骤：Validate configuration and read Apple app record / success
- 本地脚本语法：提取工作流内 Node 脚本后，node --check 通过。

成功路径断言：

1. 五项 Secrets 非空。
2. APPLE_TEAM_ID 严格等于 HY9Q7Q35S5。
3. IOS_BUNDLE_ID 严格等于 com.liuhetong.liuhetongMobile。
4. Issuer ID 为 UUID 格式，Key ID 为 10 位大写字母/数字。
5. 私钥可解析为 P-256 EC 私钥并签发 ES256 JWT。
6. 对 api.appstoreconnect.apple.com 的应用列表 GET 请求返回 HTTP 200。
7. 返回唯一应用，其 Bundle ID 与目标一致。

范围限制：Team ID 仅验证与用户提供配置一致，不是对 Apple 团队归属的独立证书验证。成功读取应用不等于已执行上传或拥有自动签发证书的权限。分发 P12、描述文件、APNs、最终 IPA 签名及 iPad 真机行为均未验证。Secret 元数据列表未包含现有发布工作流要求的 IOS_CERTIFICATE_BASE64、IOS_CERTIFICATE_PASSWORD、IOS_PROFILE_BASE64、IOS_PROVISIONING_PROFILE_NAME。

浏览器加载和初次 API 网络操作未成功，随后通过同一本机 GitHub 凭据完成实际云端验证；不影响上述成功结果。
