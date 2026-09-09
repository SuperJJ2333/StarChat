# iOS 0.3.53 通知与后台来电设计

状态：新增来电链路设计待用户确认；现有版本同步和调查已授权。不得将此文档称为已实现功能。

## 已核实基线

Android 正式0.3.53/build55使用 docs/verification/artifacts/2026-09-08/wallet-activation-address/release/source，基于dbcec9e加已验收的官方地址只读改动。根工作区仍为0.3.47且混有未发布钱包改动，不能直接作为同步来源。同步须校验该发布源码清单，保留官方资金关闭策略，再合入本任务已验证的iOS APNs、签名和SQLCipher链接修复。

iOS 0.3.47（7）已成功上传TestFlight，但本会话尚无该版本真机首屏通过反馈。现有iOS仅有普通APNs和audio/remote-notification后台模式；未实现PushKit/CallKit。来电本地通知实现偏Android，不能据权限声明推断iOS后台来电完成。

## 方案比较

1. 仅同步版本和普通通知：改动少，但无法满足锁屏系统接听页，本需求不采用。
2. 普通APNs消息 + 独立真实来电PushKit/CallKit + 后台音频：推荐。需原生、Flutter和服务端端到端接通，支持系统接听/拒接及音频会话联动。
3. 通知扩展本地解密后通过Apple E2EE VoIP接口上报：可研究，但涉及扩展共享密钥、额外entitlement申请及保护边界评审，不能当作立即可用的版本配置。

## 推荐行为

- 普通消息：APNs通用文案、声音、角标；前台按现有用户开关呈现，后台及锁屏由系统通知承载。用户拒绝授权时如实显示状态，可跳系统设置。推送不带聊天明文或密钥。
- 真实来电：调用方建立Matrix加密呼叫后，独立鉴权的来电唤醒链路发送最小标识。服务端校验呼叫方、接收方与有效通话关系，限流、去重、短有效期；不得将所有m.room.encrypted事件标记成VoIP。客户端接收PushKit后及时向CallKit上报，不能等待Flutter登录/解密才上报。
- 接听/拒接：原生动作与Matrix呼叫ID绑定并排队，处理冷启动、超时、取消、重复推送、多设备应答和退出登录；只有有效的加密会话才接通媒体。系统来电显示通用名称，真实身份由本地会话验证。
- 铃声与音频：CallKit管理来电铃声与系统页面；音频会话激活/释放联动WebRTC，验证扬声器、耳机、蓝牙、中断和锁屏持续通话。普通消息提示音与通话铃声独立，避免双重响铃。
- 后台：按真实通话开启音频和VoIP能力，不使用无声播放、定时器或伪造通话无限保活。待机依赖推送，正在进行的语音通话维持音频会话。
- 悬浮显示：App内使用现有通话小窗；跨App视频使用系统视频通话画中画，在支持设备/系统上实现与验证。语音使用系统通话状态入口；不承诺Android式任意跨App悬浮按钮。
- 系统控制：锁屏样式、横幅/全屏来电呈现、专注模式、静音、音量和用户通知开关由系统及用户决定。正常提醒按这些设置运行，不承诺绕过静音/专注模式。

## 保护边界和范围

通话媒体、Matrix信令与密钥保持现有加密策略。新增唤醒接口仅处理路由/通话标识，不接收SDP、恢复密钥、房间密钥或明文消息。实现前需形成准确接口契约及安全评审；如发现必须改变E2EE或认证边界，遵循仓库ADR及双评审要求，不能隐式扩大授权。

文件预计归属：隔离发布快照中的iOS Runner原生桥/配置、Flutter通话桥与推送注册、必要的独立来电唤醒模块及测试、签名工作流、验证记录。不得覆盖根工作区并发钱包修改。涉及实际Flutter视觉变更按项目Figma交付规则执行；系统CallKit页面由iOS绘制。

## 验收与交付

先做行为测试红绿证据和Swift/macOS编译，再签名上传0.3.53候选；版本号由发布源确认，iOS构建号保持唯一递增。实际IPA必须通过SQLCipher加载顺序、签名、APNs、后台能力及权限检查。

同一iPad测试：保留数据升级正常首屏；前台/后台/锁屏消息提示与点击定位；前台/后台/锁屏来电响铃和接听拒接；App冷启动来电；对端取消/超时去重；接听后切后台和锁屏双向音频；结束后无残留铃声；视频画中画及返回；拒绝权限、静音/专注模式、网络重连与退出登录。每项记录实测证据，未完成项标明未验证，不能宣称全部正常。

官方依据：
- https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit
- https://developer.apple.com/documentation/xcode/configuring-background-execution-modes
- https://developer.apple.com/documentation/avkit/avpictureinpicturevideocallviewcontroller
- https://developer.apple.com/documentation/callkit/sending-end-to-end-encrypted-voip-calls
