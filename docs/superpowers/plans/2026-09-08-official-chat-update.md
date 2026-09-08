# 0.3.52 正式更新发布

用户已授权上线 APK 和更新弹窗。仅发布客户端，不部署开发中的钱包/后端。

- 隔离还原已发布钱包源码并核对 0.3.51 来源哈希；合入截至 e454bf5 的聊天/主题修复。
- 在隔离源码执行 Flutter 全量测试、analyze；standard/release/ARM64，0.3.52 build54，三项 HTTPS define 保留。
- Apktool2.12.1 完整重建，36.0.0 对齐，固定正式 signer75b31c66…；版本递增、无debuggable、资产/smali/manifest语义核验。
- 上传不可变APK名，验证本地/远端/公网SHA256；基于读取的0.3.51/build53五项设置事务更新并审计，latest符号链接原子切换，保留条件回退。
- 官方签名与Mi6当前debug签名不同；此次不卸载或覆盖该调试安装。
