# iOS 0.3.102/2144 权限不弹窗调查

## 结论
已确认 CocoaPods 的 permission_handler_apple 权限能力未启用，且通话权限检查存在请求后永久拒绝不跳设置的问题。此次仅检查与记录，没有修改运行代码、重打包或发布。

## 输入与证据
用户反馈：拍照/录音/通话完全不弹系统授权框，消息通知中的通话权限检查也无法正常跳转。当前 main 060097ef 有其他任务未提交修改，未覆盖。
本地已有 IPA：`.worktrees/ios-distribution-2144/docs/verification/artifacts/2026-09-20/ios-distribution-2144/public-2144.ipa`。没有重新下载线上安装包。SHA256 `48721e9c2e566a0404d17e25178c2c77de81cc46fb414afc02e7dc058afc4e13`，CFBundleShortVersionString=0.3.102、CFBundleVersion=2144。用户之后确认已解决签名；本次本地包是之前留存2144，不能等同于重新核验用户当前签名包。
只读 ZIP/plist/原生符号检查结果：`artifacts/2026-09-20/ios2144-permissions/package-evidence.json`。

- Info.plist 中相机、麦克风、相册读写用途说明仍在，未被登录修复删除。
- 2144 源码7d1f15b5及当前 Podfile post_install 仅调用 flutter_additional_ios_build_settings，没有 PERMISSION_CAMERA=1 / PERMISSION_MICROPHONE=1 / 相册与通知相关编译定义；CI 未额外注入这些定义。
- 锁定插件 permission_handler_apple 9.6.1 的 PermissionHandlerEnums.h 默认把这些宏设为0。AudioVideoPermissionStrategy.m 在关闭分支仅实现空类，继承 UnknownPermissionStrategy：查询返回denied，请求直接返回permanentlyDenied，不调用系统授权。
- 现有2144原生二进制保留 AudioVideo/Photo/NotificationPermissionStrategy 类符号但无这些类的方法符号，UnknownPermissionStrategy 的查询/请求方法存在，与禁用实现一致。配置、锁定依赖源码及二进制证据相互印证。其他插件直接调用系统的相机/录音/推送路径需分别测试，不能据此断言所有系统通知能力都被关闭。
- call_permission_readiness.dart:109仅处理请求前的permanentlyDenied；117请求后只对通知做失败跳转，122对麦克风/相机无条件return true。因此禁用插件每次查询denied、请求permanentlyDenied后，页面既不弹授权也不跳设置。

## 是否由上一轮修复引入
上一轮会话保存修复2d463207位于独立分支，未合入2144对应源码，且未改Podfile、Info.plist和权限请求代码；不是这轮重启登录修复引入。
Podfile于2026-09-18的c6b6f755作为模板首次纳入版本库时就缺权限宏；通话改用permission_handler的代码可追溯到2026-09-04的d5e8cf25。缺少更早安装包/当时生成Podfile证据，不能断言所有旧版均正常，也不能把首次引入时间武断归到2144或某一次修复。

## 后续修复与验收范围
最小修复应为实际使用的权限启用Pod编译定义，保留用途说明；请求后permanentlyDenied时跳系统设置，restricted给出实际限制提示。补原生编译配置门禁及真实插件集成测试，避免仅mock权限结果的Dart单测遗漏。
重新生成同签名渠道覆盖升级候选后，在iOS16.7.16检查首次授权弹窗、拒绝后设置跳转、已有授权读取、麦克风/视频通话/拍摄/相册保存。无需为了诊断卸载或清除聊天数据。
调查时间：2026-09-20，精确主动耗时未记录。检查命令退出0，未运行全量测试（运行代码未改变），未声称修复或真机验收完成。
