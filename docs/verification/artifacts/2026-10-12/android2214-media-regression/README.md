# Android2214媒体发送回归：真实模拟器RED→GREEN

修复：先打开startup generation/ready，再绑定连接及媒体outbox；只改启动顺序，保留账号、代际、E2EE、权限与重试保护。

- 未修复0.4.45+2214真实main debug：相册合成JPEG红叹号；H264 MP4提示暂无法发送；queue.active=false。见baseline-runtime-receipt.json。
- 修复0.4.46+2215真实main debug：保数据覆盖同一emulator-5556（Android9/API28/x64，UID10090），JPEG m.image/synced/serverID=true，原图13K展示；MP4播放器实际帧/进度0→2秒，重启进程后m.video/synced/serverID=true，queue.active=true。见fixed-runtime-receipt.json与fixed-process-restart-receipt.json。
- debug包：fixed-main-debug-2215/final.apk，125901146B，SHAe3bd89359c3822e54dc6c6daa28d12c0117ff6f25f7c7a968eb03416d507ac2a；固定75b31签名，常规重建与严格语义比较PASS。
- 真实会话仅自己一名成员、零邀请且已加密；实际SDK创建、公共App路由进入普通RoomPage，再通过真实相册UI发送，没有transport/codec/HTTP替身。VM只用于安全隔离房间与读脱敏状态，不导出token/key/正文。
- 原始截图/APK在本机不入Git，JSON仅含合成目标与布尔状态。截图名completed只代表拍摄顺序，画面实际为0:02/0:03，未宣称完整播放完毕。
- 早期工具诊断（DPAPI密文换行、旧工具失效、未固定pub host的构建被拒、VM无编译服务/URI轮转）保留，不作为产品通过证据。没有把raw Gradle包当最终交付。

范围：一台API28 x64模拟器，不能代表全ROM/ARM64真机/16KiB环境、独立第二接收端或弱网压力；正式ARM64包另行验证与发布。共享5965PASS/9SKIP/0FAIL、analyze无问题和Python401PASS/1SKIP证据在相邻media-2215-final-gates。全仓verify缺本地.env实际阻断，未导入生产秘密。
