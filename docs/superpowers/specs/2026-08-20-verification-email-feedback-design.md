# 验证邮箱页面交互反馈设计

## 目标

优化 Flutter 验证邮箱页面的错误反馈与验证按钮按压反馈，确保验证码错误时用户能立即理解并修正，同时保持验证操作始终可用。

## 交互方案

### 验证码错误提示

- 错误提示显示在验证码输入框上方，使用独立的浅红色背景和红色文字。
- 文案为“验证码错误，请重新输入”，字号 14px（Flutter `fontSize: 14`）或更大，字重 600，满足醒目和可读性要求。
- 输入框本身在错误状态使用错误边框颜色，提示区域提供语义化 Key 供测试和辅助定位。
- `RegistrationController.verifyCode` 捕获 `EMAIL_VERIFICATION_CODE_INVALID`、`EMAIL_VERIFICATION_INVALID` 等验证码错误，将错误写入 `state.fieldErrors['code']`，页面显示该字段错误。
- 验证码文本发生变化时立即清除 `code` 字段错误；清除只影响错误提示，不禁用验证按钮。
- 空验证码仍可点击验证按钮，由服务端/控制器返回字段错误；按钮不因本地错误状态永久失效。

### 验证按钮按压动效

- `验证并继续` 使用可复用的按压状态包装器，按下时缩放到 `0.98`，抬起、取消或滑出后恢复到 `1.0`。
- 动画时长约 150ms，曲线使用 `Curves.easeOut`。
- 动效只改变视觉变换，不延迟或拦截原有 `onPressed` 回调；点击响应沿用现有异步验证流程。
- 包装器使用 Flutter 手势/按钮状态回调，兼容触摸屏、鼠标和键盘激活。

## 文件边界

- `apps/mobile_flutter/lib/features/auth/registration_controller.dart`：集中处理验证码错误状态与输入变化后的错误清除。
- `apps/mobile_flutter/lib/features/auth/verification_page.dart`：渲染输入框上方错误提示、监听验证码变化，并接入按压动效。
- `apps/mobile_flutter/lib/ui/components/modern_action_button.dart` 或新增同目录小型组件：实现通用 150ms 按压缩放，不改变按钮业务回调契约。
- `apps/mobile_flutter/test/features/auth/registration_controller_test.dart`：增加验证码错误映射和输入清除测试。
- `apps/mobile_flutter/test/features/auth/auth_pages_test.dart`：增加上方错误提示、实时清除和按压状态 widget 测试。

## 验证标准

1. 验证接口返回验证码错误时，页面在输入框上方显示“验证码错误，请重新输入”，红色文字字号至少 14px。
2. 修改任意验证码字符后，错误提示立即消失，按钮仍可点击。
3. 按下验证按钮时缩放约 0.98，150ms ease-out 后恢复，回调不被动画阻塞。
4. 现有认证、Flutter analyze 和仓库完整验证继续通过。
