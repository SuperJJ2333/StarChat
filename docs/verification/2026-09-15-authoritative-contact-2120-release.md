# 2026-09-15 发消息权威联系人统一 + Android 0.3.92/2120 发布 + iOS 2120 待签交付

## 问题与根因

新增好友 zhsb 的资料页“发消息”报“无法打开加密会话”，群聊/朋友圈入口却正常。
根因：两个入口传给资料页的 `ContactDetails` 来源不同——
- 群聊成员/朋友圈入口：从 Matrix 房间成员实时状态构造，matrixUserId 必然有效；
- 通讯录/新的朋友入口：来自本地好友缓存（接受好友时的业务快照），
  新好友刚验证时本地缓存可能尚未写入 matrix 绑定（`matrixUserId` 为空白），
  空 ID 进入 DM 创建流程必然失败。服务端 DB 核实 zhsb 的 `matrix_user_id`
  （`@gjjyrdfjk:matrix.localhost`）数据正常，问题纯在客户端缓存时序。

## 修复（统一权威解析，commit 67fc3cf8 + a14bf583）

- `ProfileRepository` 新增 `contactDetailsByUserId(userId)`：按业务 userId 解析
  权威联系人详情；缓存条目缺失或 matrixUserId 为空白时返回 null（绝不返回坏数据）。
- 新增 `upsertContactDetails`：按业务 userId 覆盖写入双索引缓存。
- `AppHome._openMessage` 重写为**入口无关**的统一流程：
  1. 好友目录存在且 matrixUserId 有效 → 直接使用；
  2. 本地无有效绑定 → 若入口 contact 自带有效 matrixUserId（群聊/朋友圈实时态）
     则回填目录；
  3. 仍无法解析才抛“该好友已不在你的好友列表”（明确文案，不带重试）。
  无论从哪个入口进入，“发消息”都收敛到同一条权威解析链路。
- 回归测试：空白 matrixUserId 解析返回 null；有效条目解析出权威详情。
  全量 Flutter **2675 通过**；analyze 零问题。

## Android 0.3.92/2120 发布

- 固定流程构建（ARM64 正式 + 三项 HTTPS dart-define + Apktool 2.12.1 +
  zipalign 36.0.0 + 固定证书 `75b31c66…`），aapt 验证
  `com.liuhetong.mobile` 2120 / 0.3.92 / arm64；语义验证通过。
- SHA256：`26B295C5A48F083D77134585C6A2F002B132F8EDA125BE7CF88CE930098EFB7B`（79,277,086 字节）。
- 分块上传 + 服务端合并 SHA 门一致 → 安装为
  `/opt/starchat/frontend/downloads/ChatFlow-0.3.92-build2120-arm64.apk`；
  `latest-arm64.apk` 切换；2117 及更早保留。
- 更新弹窗（trace `0.3.92-2120-20260915`，5 条审计）：0.3.92/2120，
  notes 指向本修复；iOS 行（2117）核对未改动。
- 公网验证：2117 包与 latest 均 206 + 正确 MIME；2115 保留 200。

## iOS 2120 待签交付

- GitHub Actions run `34983765284`（commit `a14bf583`，0.3.92+2120）success；
  `ChatFlow-iOS-signed` 解包后 IPA 59,818,509 字节。
- 交付文件：`docs/verification/artifacts/2026-09-15/release-2120/ios/ChatFlow-0.3.92-build2120-for-enterprise-resign.ipa`
- SHA256：`3E85A19BE6E2153A3B36FDFB4BF6CB58B58F123316A84B22FCC3B8D88F0ED370`
- 包内核验：bundle id、0.3.92/2120、SQLCipher 在位、统计 HTML SHA 与 Android 一致。
- 签名身份沿用同一企业描述文件（与 2085/2117 相同）。请完成企业签名后回传，
  核验通过后更新 manifest.plist 与 iOS 设置（独立事务）。
