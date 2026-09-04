# 视频发送管线（0.3.33）：阶段化、内存与流式评估

适用客户端：`apps/mobile_flutter`（聊天视频消息）
关联验证：`docs/verification/2026-09-04-release-0.3.33.md`

## 1. 阶段状态机（0.3.33 起）

发送条按 **转码 → 加密 → 上传 → 发送事件** 展示阶段：

| 阶段 | 数据来源 | 进度 |
| --- | --- | --- |
| 转码（480p 压缩） | 应用层 `transcodeForChat`（VideoCompress 回调） | **真实百分比** |
| 加密 | SDK 上传伪事件 `unsigned[fileSendingStatusKey]` = `encrypting` | 不定进度（如实） |
| 上传 | 同上 = `uploading` | **不定进度（如实）**：SDK `uploadContent` 单次 PUT，无进度回调 |
| 发送事件 | 上传完成、事件落库前（伪事件仍在 sending 且无细分状态） | 不定进度 |

实现：`lib/features/matrix/video_send_stage.dart`（纯映射，含测试）；
`room_page._sendPendingVideo` 以 300ms 轮询 SDK 伪事件状态驱动 UI。
此前整个加密+上传+发送被折叠成一句"发送中"，用户无从判断卡在哪一步。

## 2. 内存复制盘点（0.3.33 消除项 vs 不可消除项）

| 复制点 | 0.3.32 及之前 | 0.3.33 | 说明 |
| --- | --- | --- | --- |
| `sendEncryptedMedia` 正文 `Uint8List.fromList` | ❌ 每次全量拷贝 | ✅ 已删除，原实例透传 | 视频路径节省一份完整副本 |
| `sendEncryptedMedia` 缩略图 `Uint8List.fromList` | ❌ | ✅ 已删除 | 参数类型收窄为 `Uint8List`（接口同步） |
| `rendition.file.readAsBytes()` 整文件入内存 | ❌ | ⚠️ 保留 | SDK `MatrixFile`/`uploadContent` 均为整缓冲 API，见 §3 |
| SDK `Cipher.encrypt` 原生侧 `setAll` 拷贝 | ❌ | ⚠️ 不可消除 | matrix 0.34.0 内部实现（FFI OpenSSL，先拷入原生内存再原地加密） |
| SDK `uploadContent` `bodyBytes` | ❌ | ⚠️ 不可消除 | http 单次 PUT 携带完整 body |

防回归：`test/features/matrix/video_send_stage_test.dart` 以源码断言
`sendEncryptedMedia` 体内不得再出现 `Uint8List.fromList`。

## 3. 流式/分块加密上传评估（结论：当前不可行，如实记录）

- **服务端协议**：Synapse（v1.132.0）`POST /_matrix/media/v3/upload` 是
  **单次完整 PUT**；Matrix 规范没有分块/追加式上传端点（异步上传
  MSC2246 只是轮询完成，不改变"一次性 PUT 完整 body"；`m.upload`
  可恢复上传仍是草案且服务端未实现）。→ 真正的"边加密边分块上传"
  需要自建上传网关并自定义客户端-网关协议，超出当前基础设施。
- **客户端 SDK**：`matrix` 0.34.0 的 `MatrixFile.encrypt()` /
  `Room.sendFileEvent` / `Client.uploadContent` 均为整缓冲 API，无流式
  入口、无进度回调、无取消令牌。改造需 fork SDK 或绕过
  `sendFileEvent` 重写事件构造（易出规范偏差，风险大于收益）。
- **可行的渐进路径**（记录备查）：
  1. 上传进度：自定义 http client 包装（统计已写字节）只能在
     `http.Client.send` 层近似，SDK 不透出该口子；
  2. 取消：`http.Request.abort`（http 1.x）可中断进行中的请求，但 SDK
     不暴露 request 句柄；
  3. 若未来升级 SDK/服务端支持流式上传或分块，`video_send_stage.dart`
     的阶段枚举已预留插入真实上传进度的位置。

## 4. 取消上传的边界（当前实现）

- **可取消**：选择待发后、点击"发送"前（移除待发条目）；
  转码阶段本身支持 `VideoCompress.cancelCompression`（尽力而为）。
- **不可取消**：点击发送后的加密/上传/发送事件（SDK 无取消口子；
  中途杀进程会留下发送中占位事件，由 SDK 重试/失败状态收敛）。
- UI 与守卫：`_cancelPendingVideo` 在 `videoSend.busy` 时禁用取消按钮，
  避免状态撕裂。

## 5. 真机验证清单（待人工，不标完成）

1. 拍摄/相册选 >20MB 视频：转码百分比推进 → "加密中" → "上传中" → 发送成功；
2. 弱网（限速）下观察"上传中"持续展示、失败后待发条保留可重试；
3. 大图（>10MB）发送路径回归（缩略图透传无拷贝后内存峰值对比）。
