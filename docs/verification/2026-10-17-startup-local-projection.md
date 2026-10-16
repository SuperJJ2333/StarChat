# 冷启动本地首屏投影验证（进行中）

用户四项要求已明确授权。2218安装事实保留，但S1体验FAIL_USER_REPORT；候选0.4.50+2219原生合成验收包已构建、保数据安装并通过测试；普通main已保数据安装，但实际账号冷启动录像FAIL_PERCEIVED_LOADING，继续修正独立缓存架构。工作树interactive-cache-startup；规格/计划0e1f3ad3，版本元数据61909dbf。

## 必须证明

1. 真实生产main入口经过必要安装/身份/密钥检查后，在完整SDK恢复被显式持有时显示真实有界缓存列表，可切tab/入房。
2. SQLCipher初始投影至多40房间，Room对象及页面不被完整恢复替换；房间头40、滚动锚点与待发txid保留。
3. 本地文字持久入队时网络派发0，完整初始化及既有权限链就绪后同txid派发一次。
4. 账号/代次/退出/销毁/失败状态不接收晚到结果，不暴露旧账号或开放未就绪派发。
5. 合成Android原生入口测试独立于真实账号数据；最后安装普通main Debug并实测冷启动，不把am start与缓存可交互首屏混为一谈。

## 当前证据

- 版本三方一致性6PASS，version-contract.log/version-parity.log；lock未变。
- 产品02c76dcc冻结；SDK与真实main行为RED均已取得。review-1的重试与锚点两项已修复，review-fix1 SPEC / QUALITY PASS，最终专项186PASS。
- 全量Flutter6093PASS/9SKIP/0FAIL、full analyze无问题，flutter-full-2219，24分24.476秒；移动边界377PASS23SKIP、UI契约34components/540screens PASS。
- 原生合成入口native-entry-2219-2 PASS：真实SQLCipher/Olm及生产main，持有SDK恢复时列表/入房/滚动/持久入队；恢复后同页、同txid、可见锚点8dp内、一次网络发送。报告中的8978/22105ms包含夹具准备，不是生产首屏耗时。
- 原生包重建验签通过：debug-native-2219/final.apk，SHA6b246e91ec70d40fdc7f0b6503e195541c0384accdf9c74cbc25dd4403418a7a，127310170bytes。第一次流式install超时且设备仍2218；第二次--no-streaming -r成功，UID10090与firstInstall2026-09-26不变。普通main包构建中。
- .env缺失，完整verify.ps1预检不满足；未将其记为通过。

证据根：artifacts/2026-10-17/startup-local-projection。详细阶段日志progress.md，研究research.md，任务task-1-brief.md。root负责最终填入精确输入/日志/退出码、构建安装签名哈希、耗时、真实未通过项。

## 2219 真冷启动反例与修正决定（2026-10-17）

普通 main 0.4.50+2219 已保数据安装，成品 SHA256 283cbcf18f90e1dbd81c65edb19154f11693e84789057d07d0b8fea1a258066b，固定 75b31 签名，UID10090/firstInstall 不变。但实际账号冷启动录像 main-cold-video-2219 明确 FAIL_PERCEIVED_LOADING：仍出现启动、本地聊天及本机会话加载页面。6093PASS/9SKIP 与原生合成入口 PASS 均不覆盖该性能反例，不能记作用户目标完成。

Ruling: 采用独立有界 AEAD 首屏缓存，替代首屏依赖整库 SQLCipher 查询。用户四项明确授权支持此修正。保留原整库 preflight、SDK、业务认证与发送权限链在后台；本地展示能力不能充当通信权限。先冻结存储/失效/接口边界并独立领域与质量安全审查，再实施及真冷启重验。详见 task-3-diagnosis.md。下一步：独立缓存设计审查与行为 RED（持有整个原整库 preflight，而非仅 device-key 恢复）。

