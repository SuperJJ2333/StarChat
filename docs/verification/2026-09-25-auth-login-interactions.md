# 登录与注册交互修复：2178 验证记录

## 范围与源码身份

用户提出六项修复：登录限流倒计时、点击空白收起键盘、手机号错误位置、取码按钮轮廓和按压反馈、深色认证背景、非法手机号也能点击取码并立即校验。用户此前已要求完成后将 Debug 保留数据安装到 MI 6；本次不发布正式包、iOS 或生产服务。

隔离分支 `codex/auth-login-2178` 从 MI 6 已装的 2177 源码后续提交 `c000ebc1` 建立，合入主线账单与钱包的四笔提交，再合入六项认证修复 `03c851a5`。2177 的验证码已通过后补填邀请码 ticket、一次性验证码不得重放、Matrix 设备会话处理与性能诊断保留。版本递增至 `0.4.13+2178`。主工作区的未提交并行改动没有被复制进此候选。

## 根因与改动

| 问题 | 根因 | 修复 |
| --- | --- | --- |
| “登录频繁”秒数不动 | 429 的 `retryAfterSeconds` 丢失在控制器转文案过程中；页面未按截止时间刷新 | 保留 typed 秒数；页面用截止时间、逐秒 timer 和前台恢复重算，过期不自动登录 |
| 点击空白键盘不收 | 认证脚手架无空白点击失焦 | 共用脚手架点击背景时 `unfocus`，输入框正常响应 |
| 手机格式错误在主按钮附近 | 手机验证复用了整页错误 | 字段下单独显示错误与格式正确反馈，编辑后同步更新 |
| 取码按钮缺少触感 | 原按钮无明确轮廓与按压处理 | 共用描边按钮、按压缩放、44px 触摸目标；减少动态效果时不缩放 |
| 深色背景仍亮 | 固定浅色 landing 图像无暗色处理 | 登录、注册、验证码的共用背景加暗色遮罩，表单卡片保持可读 |
| 非法手机号无法点取码 | 有效号码被写入按钮可用性条件 | 非忙碌且非冷却时允许点击；先本地格式校验，不发短信 |

合并复核额外修正：手机号注册建立会话后，号码只读但重发按钮仍可在冷却结束后点击；登录 429 元数据不会被 OTP 冷却 ticker 覆盖。HTML 演示的 OTP 冷却也改用绝对截止时间，后台标签恢复后重算。

## UI 演示与契约

视觉审查入口：`frontend/index.html?screen=phone-login-phone-default-dark`、`?screen=phone-registration-phone-default-dark`、`?screen=auth-registration-default-dark`、`?screen=auth-verification-code-dark`。在本地浏览器查看了深色手机号登录及验证码页，手机号为空点击取码后错误显示在手机号字段正下方，按钮描边可见。Figma 同步已由项目 UI 流程退役。

`packages/ui-contracts/changliao-component-registry.json` 复用现有颜色、间距和动效 token，登记新的认证按钮及只读手机号目的地状态；总数 32 组件、433 页面。没有新增独立视觉 token。

## 已完成门禁

| 命令/场景 | 结果 | 退出码 |
| --- | --- | ---: |
| 注册会话冷却后重发专项，修复前 | 只读/可点或实际重发断言失败；[红测日志](artifacts/2026-09-25/auth-2178/phone-resend-red.log) | 1 |
| 同一专项，修复后 | 点击按钮后 `requestRegistrationOtp` 第二次执行；[绿测日志](artifacts/2026-09-25/auth-2178/phone-resend-green.log) | 0 |
| Flutter 认证聚焦四文件 | 62 通过；[日志](artifacts/2026-09-25/auth-2178/flutter-focused-rerun.log) | 0 |
| `flutter analyze --no-pub lib test`，重发修复后 | No issues found；[日志](artifacts/2026-09-25/auth-2178/flutter-analyze-final.log) | 0 |
| `flutter test --no-pub`，重发修复后 | 4316 通过、9 跳过；[日志](artifacts/2026-09-25/auth-2178/flutter-full-final.log) | 0 |
| `flutter test --no-pub test/features/matrix` | 2108 通过、9 跳过；[日志](artifacts/2026-09-25/auth-2178/flutter-matrix.log) | 0 |
| `npm test`，最终 HTML | 311 通过；[日志](artifacts/2026-09-25/auth-2178/frontend-final.log) | 0 |
| `py -3.12 -m pytest tests/mobile -q` | 108 通过、1 跳过 | 0 |
| `py -3.12 scripts/verify_ui_contract.py` | 32 组件、433 页面 | 0 |

`scripts/verify.ps1`、固定签名 APK 构建和 MI 6 安装正在执行，完成后补入实际退出码及身份信息。

## 安全与限制

本次不改服务端鉴权、短信供应商、限频阈值或 Matrix 协议。非法号码、未同意协议和重发冷却不会触发短信请求。2177 的邀请码续行仅在服务端签发 ticket 后生效；倒计时到期不能重放已消耗验证码。测试使用模拟手机号和模拟 API；未申请真实短信、未输入账号凭据。Debug 性能数据只能代表测试机，不能推断 Release 的性能分位数。
