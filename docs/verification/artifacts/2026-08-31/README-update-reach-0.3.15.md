# 2026-08-31 更新触达修复与 0.3.14+17 发布（现场问题跟进）

## 用户反馈的两个问题与结论

1. **"官网下载版本还是 0.3.5"**：服务端实测下发的就是 0.3.13/0.3.14
   （https://www.liuhetong888.com/ 返回链接 ChatFlow-0.3.14-arm64.apk、
   Cache-Control: no-store、APK 下载 200）。服务端无问题。
   最可能原因：浏览器/入口缓存了旧页面，或访问了旧书签。
   指引：强刷新（Ctrl+F5）或清除浏览器缓存后访问 https://www.liuhetong888.com ；
   或直接使用直链
   https://www.liuhetong888.com/downloads/ChatFlow-0.3.14-arm64.apk
2. **"APP 上没有推送消息"**：更新检查此前只在 App 冷启动时执行一次——
   长期驻留、点过"稍后再说"、或运行的是更新检查功能上线前的老版本，
   都会收不到提醒。
   修复：新增回到前台自动补检查（30 分钟节流，lifecycle observer）。

## 修复与发版

- app_home.dart：WidgetsBindingObserver + resumed 触发更新检查
  （30 分钟节流，dispose 移除观察者）；冷启动检查保持不变。
- 0.3.14+17 发布：三架构签名 APK 上传（arm64 SHA256
  14AD355FAF669622C7BDBC43D6C25A4B26E5110C310F7FEDDAE0FF4E6FB73CB1，服务端比对一致）；
  更新设置（幂等键 app-update-publish-0.3.14-20260831）确认下发；
  外部验证全 PASS。
- 回归：客户端 439 项全过、flutter analyze 零问题。

## 升级路径说明（触达链路）

- 0.3.9+ 及以上设备：App 启动或回到前台会自动提示 0.3.14；
- 更老设备（无更新检查逻辑）：需从官网 https://www.liuhetong888.com 手动下载一次；
- 提示弹窗点"稍后再说"仅压制当前启动会话，冷启动/回前台会再次提醒。


## 追加（同日）：语音消息三项修复 + 转文字 + 0.3.15+18

- 关于畅聊：设置页"关于畅聊"改为动态版本号（V + 运行时版本）并接通跳转（此前 detail 固定"1.1"、onTap 空）。
- 按住说话：长按手势改为 Pointer 事件——按下瞬间即渲染覆盖层并开始录音（无长按识别延迟）；
  底部目标区上移至距底 150px。
- 时长与播放：语音事件携带真实时长（info.duration 毫秒），气泡显示真实秒数；
  播放态显示动态波形条（AnimationController），停止恢复听筒图标。
- 转文字：新增 VoiceTranscriber 接口 + speech_to_text（系统识别）实现，
  录音期间并行识别，滑到右下角松手即把识别文本作为文字消息发送（不可用/为空则提示并取消）。
- 阻塞修复：speech_to_text 7.0.0 的 Android 构建脚本引用已关闭的 jcenter()，
  在 pub 缓存内移除该行以完成构建（上游升级时移除本补丁）。
- 发布：0.3.15+18（arm64 SHA256 fcce61cf9ce2c1806f7600bd2ef96bb94b82a0bdc139c098189b6112894d10f9），
  latest-*.apk 符号链接已指向 0.3.15；更新设置下发 LATEST=0.3.15/18；外部验证 PASS。
- 回归：客户端 439 项全过、analyze 零问题。
