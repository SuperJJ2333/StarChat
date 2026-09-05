# 0.3.36 ARM64 无混淆测试包

用户于 2026-09-05 明确要求关闭 Dart 与 Android R8 混淆，从源码构建正式签名 APK 供测试。

范围：仅 docs/verification/nomin36 下的独立源码导出、构建产物和验证证据，不修改工作区产品源码或线上发布。

1. 从 v0.3.36（1879a0d5f90b6d80ccc15464c661a62936aa5d2a）导出 mobile_flutter。
2. 在导出副本关闭 isMinifyEnabled 和 isShrinkResources；不传 --obfuscate 或 --split-debug-info；引用现有本地正式签名配置，不复制或输出密钥。
3. 使用 standard release、android-arm64、split-per-abi，保留版本 0.3.36+39 和线上 API/推送地址。
4. 验证构建退出状态、包内版本 0.3.36/2039、仅 ARM64、非 debuggable、证书与原正式包一致，并记录 SHA256。
5. 单独交付测试 APK，不发布、不替换下载别名；是否消除报毒由用户 Redmi K80 实测确认。

这是用户授权的构建参数对照，不新增产品行为或功能，不以重构/功能测试代替 APK 构建和签名验证。构建环境与线上 CI 的差异需在证据中说明。
