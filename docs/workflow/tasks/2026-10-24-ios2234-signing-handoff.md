# iOS 2234 未签名企业交接
## 恢复入口
- 用户授权：2026-10-24更新IPA交给用户企业签名，回传后再分发；明确批准修复统计助手注入后打包。
- 计划：[ios2234-signing-handoff](../../superpowers/plans/2026-10-24-ios2234-signing-handoff.md)。
- 工作树 C:/Users/Administrator/.codex/worktrees/maintenance-completion/StarChat，分支 codex/ios-history-ipa-2234-20261024，基线 b89f0c43。
- 当前阶段：未签名候选交接，等待用户企业签名及真机。候选0.4.65+2234；未发布，官网iOS2215保持。
- 文件所有权：统计助手HTML/Dart、统计安全测试/原生测试、pubspec/app_config、unsigned CI版本及测试目标、本任务文档。
- 主树509项历史文件删除与无关调查记录保留。
## 验收台账
|ID|验收|状态|
|---|---|---|
|SEC1|输入/缓存HTML不执行|原始lastInput 4RED→4GREEN；review发现缓存二次入口，1RED→5GREEN|
|SEC2|本地资产导航/桥接|Android固定路径、iOS bundle路径及首次URL绑定；纯Dart覆盖；原生WKWebView PASS|
|BUILD|未签名完整设备IPA与身份|设备作业120835603035成功；IPA 35141025B，SHA5cb97209…71768b1288；本地验包PASS，Bundle ID保持|
|GATE|共享Flutter/移动边界/原生|移动404PASS/1RubySKIP，macOS Ruby2PASS；共享首轮54目录错误，环境补齐后55PASS闭合；合并6382PASS/9SKIP。原生5目标22PASS，Outbox2项MEDIA_STORAGE_UNAVAILABLE未验收；整体CI FAIL，历史同形失败及模拟器能力限制见报告|
|SIGN|回签无额外代码、签名一致|等用户回签，不能提前标记通过|
|DEVICE|旧数据覆盖升级与推送|待真机；旧包AppID/Team不同，不能承诺保数据升级|
## 已知基线
远端main=b89f0c43；39902309601生产signed compatibility成功。39902309606设备生产编译成功，但macOS宿主video_playback_extension三项失败：预期quota-v1.sqlite，实际quota-v1.dirty/UnimplementedError；原失败保留，未改媒体/资金代码。此次独立unsigned pipeline会验证iOS26存储/SQLCipher/通知/outbox及新增统计安全。
## 证据与复用
证据主目录 docs/verification/artifacts/2026-10-24/ios2234-handoff/。
昨日maintenance完整verify退出0；本轮services/infra/生产依赖/verify脚本未变，按交付规则复用未受影响部分，补跑tests/mobile及Flutter共享/原生。不把复用称为本轮再次执行完整verify。
Flutter3.44.9/Dart3.12.2；pub get --enforce-lockfile，锁不变。从项目归档仅提取此前验证的libolm/libsqlcipher到证据native目录，SHA一致；未提取配置/用户数据。
## 时间
前置调查精确起点未记录；17:02:36+08完成干净工作树分支建立；17:09:54+08查看门禁进度。工具完整时刻见回执。
## 下一步
用户企业签名后回传；先按payload清单与Mach-O比对附加代码，再核对Bundle/AppID/Team/Keychain/profile/APNs；真机验收媒体Outbox、保数据覆盖、登录聊天及推送后再按授权分发。无运行中本任务CI/本地测试；没有改线上。

## 候选身份
构建源码 e25b664f29b88a50377b8cc739ad30214ec90acb，run40081418873/attempt1。详见[交接验收报告](../../verification/2026-10-24-ios2234-signing-handoff.md)。下载目录副本与证据delivery目录SHA一致；未签名，不可直接安装。
