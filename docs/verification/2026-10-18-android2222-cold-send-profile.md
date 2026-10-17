# Android 2222 冷启动发送计时与群资料修正

## 实测范围

2026-10-18（香港时间）在 emulator-5556 / API28 x86_64 上，强制停止后启动普通 main Debug 0.4.53+2222，打开已有“测试群”并发送用户授权的真实测试文字。没有清数据或卸载。可靠样本为 r5、r6-http；两轮同设备、同群、同网络，不代表全部设备或房间。

原安装 APK SHA256：`0ca7e72dd909e9c4cbb1a8f5ce1022d282ab156a3c29a454e2ea1bfb71382298`。产品来源 b53e7387，诊断起点 6d6b5302。

## 时间与结论

| 阶段 | r5 | r6 | 时钟及解释 |
| --- | ---: | ---: | --- |
| 缓存内容首帧 | 1754ms | 1687ms | 从 Dart main_entry，不包含原生/引擎启动 |
| SDK 恢复完成 | 5489ms | 5140ms | 同 main_entry 时钟；比首缓存帧晚3735/3453ms |
| 打开房间至本地时间线准备好 | 241ms | 236ms | conversation trace，不含自动化查找点击 |
| 点击发送至持久排队 | 56ms | 136ms | message_send trace |
| Matrix sendEvent 整段 | 1516ms | 1236ms | 含本地事件处理/排队/加密/HTTP/成功事件回写 |
| 其中实际加密事件 HTTP PUT | 未采 | 245.603ms | r6 dart:io HTTP profile，200；仅这一请求 |
| 点击发送至确认完成 | 1597ms | 1495ms | message_send trace |
| 自动化冷启动请求至观察到发送完成 | 14812ms | 13234ms | 含XML查询、控件定位、输入、探针往返；不是纯APP耗时 |

关键延迟有两个层次。冷启动内容已展示后，完整身份/数据库检查及 SDK 恢复还需约3.5秒，早期文字可以先持久排队，通信准备好后才派发。完整检查 fullPreflightBegin→identityPreflightComplete 为2521/2157ms，之后至fullSdkReady为755/742ms；这些是现有阶段跨度，不能据此擅自跳过身份或密钥校验。本次自动化输入较慢，发送发生于SDKready后，不能把恢复余量说成本次实际发送的额外等待。

发送阶段的大头是 SDK `Room.sendEvent`，而非开房间。r6 Matrix跨度1236ms减去事件HTTP245.603ms，约990ms在该HTTP之外。源码中该调用前后各await一次_handleFakeSync（本地回声和成功状态），并包含发送队列和encryptGroupMessagePayload；现有计时尚未区分这些子阶段，不能把整段都称网络延迟，也不能声称已精确测出数据库或加密各耗时多少。并行 /sync longpoll 2962ms不是发送阻塞的直接证据；本样本未观察到key query/claim/share请求类别。

## 群头像与人数根因

2222为了保留缓存气泡，把room display head的有效期延长至SDK恢复之后。但`MatrixRoomLease.roomInfo`仍无条件优先选择该头，并返回空members。结果canonical群成员已经恢复，页面仍拿不到头像和成员数。好友头像可由业务联系人回退，非好友依赖Matrix成员头像，问题因此更明显。真实画面出现“（0）”；发送造成缓存失效后“测试群”变为7人，和源码链一致。

窄修正保持timeline缓存，只在pending阶段用缓存成员展示姓名/头像；恢复后roomInfo使用canonical成员。缓存最多9位、isJoined=false/powerLevel=0/canMentionAll=false，不能作为完整人数、红包收件人或管理权限。未知人数省略“（0）”，canonical人数到来后原页更新。refresh参与者完成后，重验lease/client/Room身份及撤销状态，淘汰本房间两份成员投影。SDK Room.setState会发状态事件，显式淘汰是refresh返回的一致性保障，不是断言SDK没有通知。

还将群聊显式排除单聊好友门，避免缓存仅含一位非好友时被误判为单聊。未更改E2EE、业务鉴权、金融状态或正式版分发。

## 验证状态

RED `member-red-valid.log`：5失败/5通过，新增SDKready空成员、pending空成员、refresh投影滞后、异步替换Room返回与真实首帧“（0）”失败，取消lease原已通过。GREEN-r1：9通过/1失败，失败为既有第五头像场景首次审计前只等任一图片、却要求全部图片的precondition竞态，发生在解除SDK前；同输入隔离第五通过。测试只加强解除前全部图片已绘制的前提，保留交接期间每帧全部头像、同State及同URI的严格断言。

最终专项、冻结共享门禁、Android运行及交付收据待追加。原2222计时不会被新包结果覆盖。聚合verify.ps1因本地缺.env不能完整运行；不导入生产密钥。iOS真机不在本次Android实测范围。

## 证据与隐私

证据位于 `artifacts/2026-10-18/android2222-cold-send-profile/`。r1没有发送；r2/r3已发送但VM采集失败，不能把55秒观察超时称消息失败；r4扩展未注册，未发送；r5/r6可靠，共4条已授权测试消息。性能记录只保留阶段、时长、HTTP固定类别/方法/状态；未持久化正文、URL、凭据或解密内容。截图仅本地。自建ADB forward在finally清理，HTTP profile开关恢复原值。

任务与恢复入口：[任务记录](../workflow/tasks/2026-10-18-android2222-cold-send-profile.md)。
