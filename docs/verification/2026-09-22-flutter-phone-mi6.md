# Flutter UI 与 Mi 6 debug 交付

已安装 `com.liuhetong.mobile` 0.3.103+2157 debug 到 Mi 6（cbd0156b），保留登录与聊天数据。启动 Status: ok，进程存在；真机打开账号与隐私→绑定/更换手机号，鱼骨步骤条与表单显示正常，未请求验证码。

## 实现
- 手机登录接入原业务域/Matrix 登录协调；注册复用原注册/验证页，丢失验码响应后查状态，不盲目重发。
- 手机换绑使用已有身份验证→新手机号验证的真实 API；与注册验证直接调用原钱包 `walletStepIndicator`，无复制组件。
- 人民币计价模式充值复用原钱包页面，显示官方客服、人工申请、申请记录；参考汇率按页面进入加载，过期与不可用如实显示，最终结算以服务端为准。
- 红包沿用原详情页，展示服务端费用、群主收益及减免；群红包不再承诺所有发送者固定收手续费。
- 群主转让沿用成员选择页的中性卡片；仅后端 COMPLETED 显示换主，处理中/待核对保留状态并可刷新，不允许直接改 Matrix 绕过。

## 验证
- Flutter 全量最终 3732 passed，exit 0；analyze 无问题。首轮旧固定费率源码断言失败已修正，失败日志保留。
- Auth 73、wallet 116、group/redpacket 65 专项通过，包含新的失败恢复测试。
- 前端 245 passed，UI 契约 PASS（32 components / 398 screens）。注册表 packages/ui-contracts/changliao-component-registry.json 已记录页面映射。
- 原独立 mobile/infra 226 passed / 2 failed 原因为旧屏数 375；更新为已验收 398 后对应 3 tests passed，完整 verify 仍单独运行。
- APK：Apktool 2.12.1 重建、zipalign 36.0.0、固定签名核验通过；ARM64、debuggable、2157、包名均一致。27317 类重解包一致，339 个原生库/Flutter 资源 SHA 全部一致，清单语义一致。
- APK SHA256：416c41166b19f7a2fa208fb1a18bd2ed11470ef6f88e77d8a461e25dc6b5b205，145346859 bytes。
- APK/日志/截图/源码 hashes 位于 artifacts/2026-09-22/flutter-phone-mi6。截图 mi6-phone-steps.png 是实际 Mi6 页面。

## 边界
本次未部署后端、未开启生产转让协调、未发真实短信、未进行充值/转账/出款。新服务端能力未发布时客户端如实显示不可用或保持现有能力，不能视为线上全链路已通过。充值申请目前提交金额，可选凭证/备注尚未加输入入口；客服联系方式复用复制操作。

运行 pub get 时 Linux 平台 record_linux 从 2.1.1 解析为 2.1.2；不进入 Android ARM64 原生库，但锁文件保留真实测试/构建解析版本。托管源 URL 恢复仓库既有 pub.dev，包版本/内容 SHA 未变。

## 完整仓库门禁
scripts/verify.ps1 已运行，后台进度及真实退出码见 verify-full.log / verify-exit.txt；当前此节待最终更新，未宣称 PASS。后端有其他任务的 8 项内容变化，未复用旧后端全量证据。

### 真机与门禁追记
Mi6于20:07安装成功，20:09实际进入换绑页并截图确认鱼骨步骤条，页面零自动发码。完整后端门禁出现一项旧邀请码时钟测试失败：test_public_phone_flow_registration_login_rebind_and_privacy 复用2026-09-21固定时钟邀请码而HTTP路由使用真实时钟。已改为该HTTP用例独立创建有效邀请；整个test_phone_review.py 12 passed。此修复仅测试数据，不改生产认证规则。原完整门禁仍保留运行日志，不能将修复后专项通过写成完整verify退出0。
