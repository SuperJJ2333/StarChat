# Android APK 固定打包流程

**生效：2026-09-05，用户明确要求后续打包沿用。** 用户确认 `ChatFlow-0.3.40-arm64-rebuilt-test.apk` 安装没有问题。本流程替代之前“只从源码构建、不重建 APK”的偏好，但不启用加壳、Dart 混淆或 R8 混淆。

## 固定顺序

1. 完成源码修改、版本递增和相关测试。从源码构建 standard APK；按用户目前要求只构建 ARM64。保留 HTTPS Business API、Matrix、Getui 三项构建参数。Debug 测试包同样遵循重建和验证流程，除非用户明确要求原始调试产物。
2. 使用固定版本 **Apktool 2.12.1** 完整解包中间 APK，重建 smali/DEX、资源及二进制清单。使用本次构建独立的输出和 framework 目录。
3. 保留清单语义、权限、组件、任务归属及原生库设置。不要照搬“安卓修改大师”增加空 DEX、随机注释、修改存储模式/任务归属等额外操作。不要手工改写业务指令。
4. 使用 Android build-tools **36.0.0** 的 zipalign 对齐：`-P 16 -f 4`。对齐在签名前完成。
5. 使用下述**固定的、用户已经验证的签名身份**签名。不得每次生成新密钥，不能继续把旧签名的源码中间包当最终交付。
6. 执行 apksigner verify、签名后 zipalign 检查、aapt 包名/版本/ABI/清单检查、重解包代码核对，以及原生库/Flutter 资产逐项 SHA256 对比。
7. 保存最终 APK、SHA256、证书指纹、工具版本、构建参数和验证记录。上传/更新弹窗必须指向验证过的最终重建 APK。下载后再次核对 SHA256；不能误发布原始中间包。

## 签名连续性

当前用户验证身份的证书 SHA256：
`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`（RSA 3072）。

本机私钥位于 `%USERPROFILE%/.chatflow-signing/diagnostic-20260905/diagnostic.p12`，别名 `chatflow-local-ab-20260905`，密码保存在同目录 Windows DPAPI 加密文件。目录名保留历史 diagnostic 命名，不代表每次重新生成。只允许当前授权账户使用；私钥、密码和 DPAPI 文件不得进入仓库或分发服务器，不得打印密码。

签名脚本证据位置：`docs/verification/artifacts/2026-09-05/background-call-signature/sign-diagnostic.ps1`。后续运行前必须确认 keystore 和 DPAPI 文件已存在；若丢失，不要让脚本自动生成另一张证书冒充同一身份。

旧正式证书 `b4784ac301d54add4157427713b136cb22cefd626e9c7a6092882e145c0b22f6` 与当前身份不同。旧正式安装一般不能直接覆盖升级；不要自动卸载或清除数据。用户已安装的新身份包之间应保持同一证书和递增 versionCode。历史 CI 的 GitHub Secrets/发布脚本不会因本文自动改用新密钥；在完成签名一致性配置和核验前，不可直接发布其原始产物。换机器/CI 须通过受保护的密钥迁移保留同一身份，不能传输本机明文凭据或仅依赖无法跨账户解密的 DPAPI 文件。

## 已验证命令形式

所有 Windows 命令使用 pwsh.exe，先设置 UTF-8 输入、输出、管道编码；Python 设置 PYTHONUTF8=1 和 PYTHONIOENCODING=utf-8。下列变量需指向当次 `docs/verification/artifacts/<日期>/<任务>/` 下的独立目录，不覆盖先前验证包。

```powershell
java -Xmx4G -jar $ApktoolJar d $SourceApk -o $Decoded -p $Framework
java -Xmx4G -jar $ApktoolJar b $Decoded -p $Framework -o $UnsignedApk
& $Zipalign -P 16 -f 4 $UnsignedApk $AlignedApk
# 然后调用受保护的固定密钥签名流程；最终输出为 $FinalApk。
& $Apksigner verify --verbose --print-certs $FinalApk
& $Zipalign -c -P 16 4 $FinalApk
```

每一步必须检查退出码，失败不得继续签名/发布。不要在最终签名后重新压缩或修改 APK。

## 验证基线

已通过用户安装测试的包 SHA256：
`386fe5980de5de4d8bcebf52559af80e5d7e6ad91b8e3675074015af1ec3c448`。

详细证据：`docs/verification/2026-09-05-apk-rebuild-test.md`。工具与验证脚本位于 `docs/verification/artifacts/2026-09-05/apk-rebuild-test/`。

当次检查：24,570 个类保留，所有方法 smali 内容一致；只将重编译器省略的静态默认值 `false`、整数 `0`、引用 `null` 按严格类型规则归一化。331 个原生库/资产条目字节一致，完整清单语义一致。对未来版本应按当次源码结果重新计算，不能把这些数字硬编码为所有版本的类数/资产数。

用户这次安装成功是该具体包的结果，不是未来所有版本、设备或病毒库的保证。遇到新告警应保留样本与日志、比较变化并请求检测厂商复核，不得擅自叠加加壳或随机变形。
