# 红包与转账支付密码

客户端先查询`GET /api/v1/payment-pin/status`；未设置时通过登录密码确认本人，并两次输入六位ASCII数字。`POST /payment-pin/setup`不能覆盖既有凭据。PIN使用独立Argon2id盐值/哈希，不在客户端持久化。

`POST /payment-pin/authorize`接收PIN和完整业务意图，返回300秒有效的不透明授权；绑定账号、登录会话、设备、凭据版本、业务动作、规范化参数和业务幂等键。创建红包/转账时传`payment_authorization`及同一`Idempotency-Key`。错误、过期、跨会话或不同参数不可支付。成功创建后仅重试Matrix引用发送，不重新创建。

连续五次错误锁定15分钟，按账号持久化；辅以账号/会话/IP限流。不要用删除凭据、清除失败次数或关闭验证处理用户报错。首次设置接口不是重置接口，当前没有新增忘记密码或管理员重置入口。

## 兼容与发布

- 新增迁移`0059_chat_payment_pin`；先备份并演练恢复，再升级。
- `BUSINESS_PAYMENT_PIN_REQUIRE_ALL=false`为兼容期默认。仅未设置账号可继续使用旧客户端；一旦设置，所有发送接口必须校验，旧`/ledger/transfers`入口被阻止。
- 新客户端无论全局开关如何，都先设置并校验PIN。状态服务失败不得绕过。
- 全局强制开关置true前须先发布兼容正式客户端并验证；本次Redmi Debug安装不触发Android正式更新或iOS发布。
- 候选镜像从当前生产不可变摘要叠加已审查文件；核对原有钱包、朋友圈及iOS接口均保留。比较Compose环境、挂载、网络和启动项，不输出秘密值。
- 回退不得撤掉已设置账号的校验。优先向前修复；不能降级到没有支付密码校验的旧API镜像。

## 验证与观测

隔离账号执行错误/锁定、并发设置、单票双提交、交易回滚、备份恢复；真实Redmi账号不用于资金测试，也不能替用户设定永久PIN。审计只记录动作、结果和业务标识，不记录PIN、登录密码或授权票据。HTTP请求日志不得包含body/header。

维护契约`packages/api-contracts/openapi/liuhetong-v1.yaml`及`wallet_release_preflight.py`当前head；详细本次证据见`docs/verification/2026-09-09-payment-pin-redmi.md`。

## 真机测试隔离规则

禁止使用真实应用包名执行`flutter drive --use-application-binary`：当前Flutter工具结束时会自动卸载包，安装失败重试也可能卸载已有包，不能把它当成保留数据的升级工具。

测试入口必须使用独立包名；若系统拒绝新包安装，停止并请求用户在设备确认，不能回退到真实包名。普通升级仅使用明确的`adb install -r`并检查结果，不允许自动卸载兜底。确需附加到已运行测试应用时先核对Flutter工具的`--use-existing-app`和`--keep-app-running`行为，并确认其清理路径不会卸载真实包。
