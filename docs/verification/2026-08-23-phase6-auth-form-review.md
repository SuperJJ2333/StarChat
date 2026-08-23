# 阶段六认证与表单 UI/Figma 审查记录

## 范围

- 登录、注册、验证码页面的错误反馈一致性。
- `AuthTextField` 的占位文字、内边距、圆角和字号 Token。
- 协议勾选框和认证错误反馈的语义 Token。

## 结论

| 检查项 | 结果 | 证据 |
|---|---|---|
| 错误反馈组件 | PASS | 登录、注册、验证码均使用 `AuthErrorMessage` |
| 表单字段 | PASS | `AuthTextField` 使用 tokenized `callout` 字号和认证字段内边距 |
| 认证状态 | PASS | 覆盖 default、disabled、field-error、server-error、loading |
| 聚焦回归 | PASS | `flutter test test/ui/auth_surface_card_test.dart test/features/auth/auth_pages_test.dart` → 27 passed |
| 静态分析 | PASS | `flutter analyze` → `No issues found!` |

## Figma 导出账本

- ID：`phase6-auth-form-feedback`
- 文件：`design-demo/artifacts/figma-state.json`
- 三方注册表：`packages/ui-contracts/changliao-component-registry.json`
- 当前环境未调用实时 Figma API；审查基于版本化导出账本和契约校验。
