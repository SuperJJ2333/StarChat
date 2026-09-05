# 图库视频与后台视频来电修改审计

审计日期：2026-09-05。范围：v0.3.36 至当前 b80049b 的 Android/Flutter 图库和通话相关改动及当前调用链；不是对 b80049b 全部财务/后端修改的安全签核。开始审计时工作区干净。本次未修改产品源码、未构建或部署修复版；新增独立审计测试与证据。

## 版本辨识

此前交付的无混淆测试包准确来自 v0.3.36（1879a0d），关闭混淆并不包含 e7bd02e/b80049b 后续图库与原生来电修复。版本名仍为 0.3.36，不能凭版本名确认已安装这些修复。

## 发现（按优先级）

### P1：现代 Android CallStyle 分支漏设 fullScreenIntent

`apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/call/CallNotificationManager.kt:142–153`：API31+ 且 PhoneAccount 成功注册时只 setStyle；setFullScreenIntent 仅在 else 分支设置。CallStyle 是通知样式和动作模板，不会自动生成打开 CallActivity 的 fullScreenIntent。后台 startActivity 又可能受系统限制，因此该正常分支缺少锁屏全屏通知入口。旧验证报告“CallStyle 自带全屏呈现”不成立。

修复方向：在共同 builder 路径配置展示 Activity 的 fullScreenIntent，保留 CallStyle；依据 canUseFullScreenIntent、通知渠道和权限提供正常降级。不得把正文点击改为自动接听。Android 14+ 权限和厂商限制仍适用，不能承诺任意状态强制弹出。

### P1：回前台只取消通知，不恢复来电页面（失败测试实证）

`lib/features/matrix/call_ui_manager.dart:101–105` 的 handleAppResumed 仅 hideIncoming。后台 ringing 时未压入 Flutter route；用户回前台但 phase 未变化，不会触发 _handleCallState 补页。AppHome 的生命周期代码确实调用该方法，结果是通知被移除而接听页仍缺失。连接中/已连接无新状态事件时也应核验恢复逻辑。

独立测试模拟后台视频响铃 → resumed=true → handleAppResumed：期望 isIncomingPageOpen=true，实际 false。日志 `artifacts/2026-09-05/gallery-call-audit/resume-red.log`，测试退出码 1，失败原因为业务断言，不是环境或编译问题。现有回前台测试通过手动触发状态处理，不能证明真实生命周期入口正确。

修复方向：生命周期恢复时按当前非终态重做呈现决策，尊重主动呼叫页和现有路由幂等性，页面恢复成功后再交接通知。

### P1：视频流变化没有独立触发画面绑定

`call_page.dart:78–87` 仅 renderer 初始化结束和 controller 通知时执行 _updateStreams；`matrix_call_adapter.dart:189` 只监听通话状态，没有转发 SDK onStreamAdd/onStreamRemoved 或 WrappedMediaStream.onStreamChanged。若流在最近一次状态通知之后到达或重建，srcObject 可一直停留在 null/旧流，直到下一次控制器事件。计时器 setState 也不调用 _updateStreams。该异步时序是静态代码确认的缺口，尚无 K80 摄像头日志证明它就是此次设备故障根因。

还需防护 renderer 初始化与 dispose 的竞争、初始化未完成时的绑定。建议通过可注入媒体源/renderer 的延迟流测试验证，不仅测试按钮是否调用 switchCamera。

### P2：视频等待页使用远端 renderer，UI 与所述目标不一致

`call_page.dart:253` 在视频来电/连接等待状态直接渲染 _remoteRenderer，尚未接通时远端通常无可用画面，因此会出现黑色区域而非与语音来电一致的头像/状态。`call_page.dart:358–375` 把本地画中画夹在两个 Spacer 之间，Align(topRight) 只能在自身布局范围内对齐，无法达到注释所说的屏幕右上角定位。

按用户要求的微信式交互，建议：来电未接听采用统一的头像、昵称、邀请类型和红/绿按钮；用户接听且页面进入可用前台后申请/使用摄像头；本地前置画面与远端流就绪状态分别呈现；接通后远端主画面、本地右上角镜像预览及切镜头/静音/免提/挂断。此为建议，未声称已观察或复刻当前微信版本的全部界面。

### P2：视频封面字节损坏后禁用重试

`image_picker_page.dart:841` 的 Image.memory errorBuilder 使用 showRetry=false；非空但不可解码的首帧数据会一直使用已完成 Future 和缓存，用户只能看到占位且没有重试按钮。当前“损坏缓存能恢复”的描述不完整。该问题仅能解释部分视频封面不显示，不能解释所有视频条目消失。

## 图库问题的已确认与未确认部分

- 当前清单包含 READ_MEDIA_VIDEO，权限请求使用 RequestType.common，不能再笼统归因为没声明视频权限。
- v0.3.36 后确实修复了 common/video 共用相册缓存、相册切换请求互相覆盖、视频抽帧失败永久缓存及并发控制；这些后续修复未进入刚才的无混淆包。
- common/video 缓存混用能导致“本地视频”筛选错误，但 common 本来包含图片和视频，不能单凭这个缺陷声称解释全部视频不可见。
- Android 14+ 允许只授权用户选定的照片/视频。当前代码只有 full/limited 汇总状态，未给用户一个明确的“仅部分媒体可见/重新选择视频”入口；还需在 K80 核查真实权限、MediaStore 查询数量和加载阶段错误。
- 必须区分：没有视频条目、条目存在但封面黑、点击后预览失败。这三者分别涉及媒体权限/索引、首帧解码、视频取文件/转码/播放器，不能用一个权限修改统一解释。
- SDK 的默认摄像头约束已经是 facingMode=user（matrix 0.34.0 UserMediaConstraints）；不是未指定前置摄像头。尚未观察真实 K80 camera track/getUserMedia 错误，不应断言硬件调用已经修复。

## 验证

- Flutter --no-pub 定向运行 device_gallery_source、image_picker_page、call_page、call_controller、call_ui_manager、native_call_coordinator 六个测试文件：69 passed，退出码 0。
- 新增只读审计复现：1 failed，准确证明 handleAppResumed 未恢复来电页；测试副本位于 artifacts，不混入正式测试集。
- 连接设备只读识别：MI 6（API28）、ASUS_AI2501_A 和 API28 模拟器；没有 Redmi K80。未查看用户照片/视频内容、未发起真实通话、未修改设备权限。API28 环境不能验收 API31+ CallStyle 或 API34+ 全屏/相册权限。
- 未修改 Flutter/HTML/Figma，未完成 Figma 视觉复核。代码修复及界面交付须遵守现有 figma-ui-delivery 规则；当前没有可调用的 Figma 工具。此审计不构成 UI 交付完成声明。

## 官方参考

- Android CallStyle 通知模板：https://developer.android.com/develop/ui/compose/notifications/call-style
- 全屏通知创建：https://developer.android.com/develop/ui/compose/notifications/create-notification
- Android 14+ 全屏意图授权：https://source.android.com/docs/core/permissions/fsi-limits
- Android 部分照片/视频访问：https://developer.android.com/about/versions/14/changes/partial-photo-video-access?hl=zh-CN
- 后台摄像头与前台服务限制：https://developer.android.com/about/versions/14/changes/fgs-types-required

结论：现有修改方向部分正确，尚不能通过两条流程的完整验收。已有单测通过不能证明锁屏唤起或真实摄像头/图库正常。优先修复两个明确的来电呈现缺陷，再以实际修复基线构建并在 K80 复测；不能继续将旧标签的无混淆包当作修复版。
