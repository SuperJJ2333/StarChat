# iOS 分发证书 CSR 准备

日期：2026-09-07。用户要求指导后续签名准备；本机生成 CSR 和配套私钥，不创建任何远端 Apple 证书。

- 团队：HY9Q7Q35S5。
- 本机持久签名目录：C:/Users/Administrator/AppData/Local/ChatFlowSigning/HY9Q7Q35S5。
- 目录 ACL 关闭继承，仅当前 Windows 用户和 SYSTEM FullControl；不位于 Git 仓库内。
- 私钥：RSA 2048 位；文件名 chatflow-distribution.key.pem。后续复用，不重新生成覆盖。
- 公共 CSR：ChatFlowDistribution.certSigningRequest；SHA-256 为 14A9C7B9D319E2D095649BC2A96F0D676A37E7B91045E66F26218B750A046350。
- OpenSSL req -verify：Certificate request self-signature verify OK。
- 从 CSR 和私钥提取的公钥比较：CSR_KEY_MATCH_PASS；没有输出私钥或公钥内容。
- 尚未签发 .cer、导出 .p12、创建描述文件或上传 GitHub signing secrets。

用户网页后续操作：Apple Developer → Certificates → Apple Distribution → 上传此 CSR → 下载证书到上述签名目录。先确认目标 App ID 开启 Push Notifications，再创建 App Store Connect 分发描述文件，选择 com.liuhetong.liuhetongMobile 和此次证书，名称 ChatFlow_AppStore，下载到同一目录。证书、描述文件返回后，验证公钥匹配、证书团队/有效期、描述文件 App ID/团队/证书关联和 aps-environment，再导出 P12 并配置加密 Secrets。
