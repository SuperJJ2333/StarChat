# v0.3.45 APK 构建与验证记录

**日期：** 2026-09-06　**构建基线：** `81554a9`（含十项聊天体验规格 + 三轮审查修复）

## 构建参数

| 参数 | 值 |
|---|---|
| 源码版本 | pubspec.yaml `0.3.45+48` |
| versionName | 0.3.45 |
| versionCode | 48 |
| 构建模式 | release |
| flavor | standard |
| target-platform | android-arm64 |
| 构建命令 | `flutter build apk --release --flavor standard --target-platform android-arm64` |

## 重建流程（按 docs/runbooks/android-apk-rebuild.md）

| 步骤 | 工具 | 结果 |
|---|---|---|
| 源码构建 | Flutter 3.44.9 + Gradle | `app-standard-release.apk`（115.8MB） |
| Apktool 解包 | Apktool 3.0.3（`java -Xmx4G -jar /tmp/apktool.jar d`） | ✅ |
| Apktool 重建 | 同上（`b` 命令，独立 framework 目录） | ✅ `unsigned.apk` |
| Zipalign | build-tools 36.0.0，`-P 16 -f 4` | ✅ |
| 签名 | 固定密钥（`sign-diagnostic.ps1` 脚本） | ✅ |
| apksigner verify | `verify` | ✅ |
| zipalign verify | `-c -P 16 4` | ✅ |

> 注意：本机 Apktool 为 3.0.3（运行手册指定 2.12.1 未找到）；两者输出均为有效 APK，签名验证通过。

## 签名验证

```
Signer #1 certificate DN: CN=ChatFlow Local Diagnostic, OU=Local Testing, O=ChatFlow, C=CN
Signer #1 certificate SHA-256 digest: 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff
Signer #1 key algorithm: RSA
Signer #1 key size (bits): 3072
```

证书 SHA256 与运行手册一致（`75b31c...61fff`，RSA 3072）。

## 包信息

```
package: name='com.liuhetong.mobile' versionCode='48' versionName='0.3.45'
application-label: '畅聊 ChatFlow'
native-code: arm64-v8a, armeabi-v7a, x86_64
```

## 最终产物

| 文件 | 路径 | SHA256 |
|---|---|---|
| **签名 APK** | `docs/verification/artifacts/2026-09-06/v0.3.45-release/ChatFlow-0.3.45-arm64.apk` | `f2519bd919c4b6fcb060384ab723576a75ff995c0e931261fb6ae00920534007` |

文件大小：121,797,267 字节（~116MB）

## 上传与发布（需手动执行）

SSH 到服务器当前被拒绝（Connection closed by UNKNOWN port 65535），无法自动上传。恢复后执行：

### 1. 上传 APK

```bash
scp -P 23421 docs/verification/artifacts/2026-09-06/v0.3.45-release/ChatFlow-0.3.45-arm64.apk \
  root@207.56.8.8:/var/www/chatflow/downloads/
```

（具体路径以 nginx `location /downloads` 配置为准）

### 2. 服务器上核对 SHA256

```bash
sha256sum /var/www/chatflow/downloads/ChatFlow-0.3.45-arm64.apk
# 应为 f2519bd919c4b6fcb060384ab723576a75ff995c0e931261fb6ae00920534007
```

### 3. 发布更新设置（business-api 容器内）

```bash
export RELEASE_VERSION=0.3.45
export RELEASE_BUILD=48
export APK_URL=https://www.liuhetong888.com/downloads/ChatFlow-0.3.45-arm64.apk
export NOTES_FILE=/tmp/update-notes.txt
# 先把 update-notes.txt 上传到服务器 /tmp/
python3 /opt/business-api/scripts/publish_app_update.py
# 期望输出 PUBLISH_RESULT PASS
```

### 4. 验证更新弹窗

任意已登录客户端调用 `GET /api/v1/app-updates/latest` 应返回 `latest_version=0.3.45, latest_build=48`。

## 版本更新内容

见同目录 `update-notes.txt`（已准备，需上传到服务器供发布脚本读取）。
