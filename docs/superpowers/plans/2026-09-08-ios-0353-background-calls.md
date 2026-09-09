# iOS 0.3.53 后台来电实施计划

> **For agentic workers:** Use subagent-driven-development for bounded native and gateway work, then specification review before quality/security review. 用户已确认2026-09-08设计，继续执行无需重复确认。

**Goal:** 正式0.3.53源码同步到iOS，接通APNs消息、真实VoIP唤醒、CallKit和后台音频，提供系统支持的视频画中画并交付TestFlight实测候选。

**Architecture:** 独立发布worktree。普通消息保留Sygnal APNs。独立最小来电网关使用现有Matrix访问令牌向固定Synapse验证身份、设备及加密双人房成员，只中转通话标识，不接收密钥/媒体/SDP。Swift负责立即上报CallKit及系统音频，Flutter按Matrix callId匹配动作和信令。

**Tech Stack:** Flutter3.44.9、Swift/CallKit/PushKit/AVKit/WebRTC、Python3.12/FastAPI/httpx/APNs ES256、SQLite仅保存设备路由及短期通话状态。

工作区：docs/verification/artifacts/2026-09-08/ios-0353/source。证据在其上一级，避免提交临时输出。

## 1. 发布基线（root）
- [x] 对正式0.3.53清单1102文件验SHA256，无差异。
- [x] 建立codex/ios-0353-background隔离worktree，合入正式5个发布文件及原签名分支iOS5个修复文件。
- [ ] 核对Dart APNs注册接线、构建版本与各后端URL，保留原SQLCipher链接验证。

## 2. 最小来电网关（gateway implementer）
文件：services/ios-call-gateway/下app、tests、锁版本依赖、Dockerfile、README及独立Compose文件；不修改business-api、钱包或现有部署。
- [ ] 先写HTTP行为测试：无效令牌/设备拒绝、非双人加密房拒绝、只对注册iOS设备VoIP、重复呼叫去重、取消/过期、账户解绑、APNs拒绝移除失效token、载荷无明文。运行pytest保存red。
- [ ] 实现固定上游Matrix鉴权和成员校验，设备路由绑定whoami设备，SQLite事务去重、每人限流、30秒呼叫有效期。
- [ ] 契约：公网前缀/ios-call，内部PUT/DELETE /v1/devices/ios，POST /v1/calls，POST /v1/calls/end，POST /v1/calls/answer。Authorization为已有Matrix Bearer。注册body={voip_token,apns_token?,registration_id}，DELETE携带X-Registration-ID。呼叫body={room_id,call_id,recipient,video}。结束/应答body={room_id,call_id}。返回状态不泄露他人设备token。
- [ ] VoIP APNs payload={aps:{},call_id,room_id,video,expires_at}，topic固定bundle+'.voip'、type=voip、priority10、expiration有效期。取消/其他设备应答只可发普通APNs后台事件，不伪造新VoIP来电。
- [ ] HTTP测试green、依赖固定、无敏感日志、规格复核及安全复核，再由root部署独立服务并验证健康和拒绝路径。

## 3. Swift原生通话（native implementer）
文件：ios/Runner下Swift桥、SceneDelegate/AppDelegate及Info.plist、project.pbxproj；原生单测与构建说明。
- [ ] 测试先行验证载荷/UUID/过期、重复上报、动作callId绑定与队列清理；原生Swift测试在macOS运行，Windows仅静态检查不得声称编译通过。
- [ ] PushKit在应用启动注册；立即CallKit上报后完成PushKit回调；过期/无效VoIP也按Apple要求完成上报和结束，不等待Flutter。系统重置、音频中断、超时清理完整。
- [ ] 通道chatflow/ios_calls：start/getTokens/stop，tokensChanged={voipToken,apnsToken}；incoming payload与answer/end/mute动作携带callId和roomId。Dart->native showIncoming/reportState/endCall/getPending/ready，状态包括callId、roomId、phase、video。单独通道不扰Android native_call。
- [ ] Cold start需确保同一Flutter engine可后台启动并可由Scene接管；接听动作等待相同Matrix会话。CallKit音频激活/停用联动WebRTC RTCAudioSession。
- [ ] 视频PiP仅渲染真实远端视频track，通过现有flutter_webrtc原生流查询接入，支持恢复App、退出与不支持设备反馈。真实通话audio/voip后台模式，不添加伪保活。
- [ ] 普通APNs前台提示、通知权限读取/设置入口及后台取消事件处理保持本地通知插件兼容。

## 4. Flutter集成（root）
文件：lib/features/matrix/ios_call_coordinator.dart、call_wakeup_client.dart及test同目录、matrix_call_adapter.dart、app_home.dart（最小接线）、必要调用参数。
- [ ] 先测试通话ID严格绑定、接听先于Matrix到达排队、过期拒绝、退出清空、用户动作恰好一次、token轮换注册和设备解绑。
- [ ] 后端暴露活跃callId/roomId及状态事件；主叫invite真正发送后调用最小网关唤醒，所有平台主叫可唤醒iOS；挂断/应答发送对应元数据。已接通的媒体不依赖网关；新的接听校验故障必须失败关闭并结束旧call，404仅兼容明确不存在的旧客户端唤醒记录。
- [ ] iOS建立专用coordinator，避免Android原生协调器误接管。Matrix响铃和native动作严格关联callId；前台采用CallKit，抑制重复应用铃声。
- [ ] 原生token注册使用当前Matrix已验证会话；首次unlock后后台密钥可用策略不得未经评审更改。按实际运行结果处理，不将Keychain错误吞掉。
- [ ] Dart focused red/green、flutter analyze、全Flutter测试和scripts/verify.ps1；失败按变更范围定位。

## 5. 评审、部署和候选交付（root）
- [ ] 规格审查后质量/安全审查；新增网关鉴权属于复用既有Matrix身份验证，形成ADR记录并审查，不改现有登录/RBAC/资金策略。
- [ ] 独立容器/路径上线，不覆盖正在运行的业务版本；服务器密钥只读挂载现有APNs文件，权限保持严格。
- [ ] macOS Swift检查和签名IPA构建；actual IPA校验SQLCipher、APNs、iPad权限、后台模式、版本0.3.53，成功后上传TestFlight。
- [ ] 真机保留数据升级；消息前后台锁屏、来电前后台锁屏、取消/超时/冷启动/多设备、后台双向音频、PiP、静音/专注/拒绝权限逐项记录。没有证据的项目明确未验证。

## 当前执行记录

实现与评审已完成；最新Flutter1333tests、Analyze、仓库verify通过，网关53tests通过且生产健康/鉴权烟测通过。Mac原生核心测试通过，正在等待IPA归档与导出验证。具体证据见docs/verification/2026-09-08-ios-0353-readiness.md。未勾选的交付/真机条目仍需实际验证。

最终状态：IPA0.3.53（58）构建及实际校验通过，TestFlight上传成功；独立服务已部署并通过烟测。真机步骤等待用户在iPad升级执行，未标记通过。

## 7. iOS 语音播放回归修复（2026-09-08，沿用继续修复授权）
- 用户确认背景来电已正常；新录音产生语音气泡，既有/新语音播放失败。
- root owns voice_playback_controller.dart, its source/controller tests and iOS workflow; native audit read-only.
- 真机诊断 AVFoundation -11828 / DarwinAudioError source load failure。M4A 的 BytesSource 临时文件没有扩展名及 MIME。
- [x] red: MP4/AAC MIME 两项失败，原生错误流未捕获一项失败。
- [x] 最小修复：依据文件头传容器 MIME，消费播放器错误流；保留录音、转写、CallKit。focused 14 tests pass.
- [ ] 规格审核后质量审核，analyze/full tests/repo verify。
- [ ] 签名候选验证后上传 TestFlight，旧语音/新录音/转写/通话真机复测。
- [x] 语音候选规格/质量审核、1337 Flutter tests、analyze、repo verify PASS。
- [x] iOS 0.3.53(59) 签名包验证通过，TestFlight 上传任务 34178747782 success。
- [ ] 用户在 iPad 更新59后复测旧语音、新录音回放、转写及通话；未声称真机问题已解决。
