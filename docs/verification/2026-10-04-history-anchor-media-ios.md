# 历史消息、旧媒体与 iOS 恢复连续性验证

候选源码 `df61718772b4c82f3063f1034a93e2c028160735`，版本 `0.4.30+2199`。这是 Android 模拟器调试交付和同源 iOS 验证，不含本轮正式 APK/IPA 发布。

## 用户要求与修复

| ID | 问题与根因 | 修复及验证 |
| --- | --- | --- |
| H1 | 五天前搜索命中无法跳到气泡；本地持久事件仍为密文，过早按 Message 类型过滤 | SDK 对本地/网络单事件统一恢复会话和解密后再检查可见性；真实 keyed SQLCipher 重开、native Olm、五天前文本锚点 RED→GREEN |
| H2 | 昨日及更早图片视频占位；媒体加载只查当前 timeline 窗口 | 按事件 ID 解析旧事件，使用已验证媒体来源和账号/房间范围缓存；旧图片/视频实际加密缩略图及附件 RED→GREEN |
| I1 | 预防 key loading 导致 iOS L04/L07；首次 generation 使 owner 失效，设备采纳超时使内存与数据库身份分裂，Olm 标签仍为旧设备 | 撤销并等待真实写入后绑定已验证 generation；仅持久化前采纳失败回滚完整凭据与异常重试上下文；持久成功后更新同用户原 Olm manager 设备标签，保留原账户/指纹 |

未扩大 72 小时后台加载范围或 1000 条 live timeline 窗口。撤回/隐藏、错误账号/房间/发送密钥/会话、坏媒体密钥、缺密钥重试、迟到读取及 revoked-owner 拒绝均保留。没有清除数据、重置密钥、降低 E2EE 检查或改变资金状态。

## 可复核证据

- 三次独立有序审查：规格/领域后质量/安全；Task1 条件接受后，由 Task2 真实启动用例关闭 owner 阻塞。最终源码及最终 Android 包均接受，无 P0–P2。
- 245 项相关测试通过，无跳过；真实 SDK、SQLCipher、Olm 的九个初始化/轮换/异常场景保留原指纹和旧加密历史。Task1 手动采纳捷径已移除。
- 最终全量 Flutter **5419 passed / 9 skipped / 0 failed，exit 0**，3m53s；analyze **0 issues，exit 0**，27.7s。mobile Python **307 passed / 23 skipped，exit 0**，61.54s。
- 首次全量 **5417 passed / 9 skipped / 2 failed，exit 1** 保留；仅公告测试替身漏 native `session_id()`，补齐接口后原安全断言不变，聚焦 7 项与最终全量通过。
- `verify.ps1` 未启动：`.env` 和 `local.env` 缺失，配置 render 需要 `.env`。未导入生产配置，不宣称整库脚本通过。
- 1867 移动输入 manifest SHA256 `8348714a26860fba2dabf32483822b1bdb352dc0a173dd927456b4776867945b`，构建前/后及独立复验一致。锁文件未变。
- 公告 fixture 的 mixed CRLF/LF checkout hash 与 Git LF blob 经换行归一化完全一致，详见交接报告澄清。

Android：源码构建 → Apktool 2.12.1 → zipalign 36/P16 → 用户固定签名 → 独立复解包验包。final.apk **135721187 bytes**，SHA256 `e3923bc093c6a1850129086571785935e7465316799408f6e6f4e5780a815122`，证书 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。标准 x86_64 debug 包名 `com.liuhetong.mobile.debug`。旧2198最终包 SHA `6fa18013…`保持。

工件位于 [本轮目录](artifacts/2026-10-04/history-anchor-media-ios/)，测试输入见 `candidate-inputs.json`；包目录 `android-debug/run-20261004-184915/`，各命令真实退出码见 `steps.tsv`。目录还包含未发布的本机 synthetic 失败残留，不应整体复制或分发。

## 平台与交付状态

同源码 [iOS native run 37196458099](https://github.com/SuperJJ2333/StarChat/actions/runs/37196458099)：完整 production 原生编译、iOS 18、iOS 26 全部三个 job success，且两端 host/seed/verify 关键步骤均 success，head SHA 与 df617187 一致。现有同 Bundle ID/模拟器 seed → terminate → verify 保留 Keychain/SQLCipher，验证阶段先 peek 原 key 再初始化，不能用新库代替原库；scanner 的原有模拟器架构排除不代表完整 scanner 运行验收。

模拟器已 install-r 2199，UID10090、首次安装时间2026-09-26 04:06:20保持；157秒启动观测进程23425保持、该进程原生crash buffer无崩溃标记；不作为真实账户历史恢复成功证据。真实用户五天前气泡/媒体、Android 真机和 iPhone 企业签名覆盖升级仍需设备反馈，合成原生/加密用例不能代替这些验收。预防的是本轮密钥加载方式引起的身份持续失效；真正损坏或外来账号/密钥仍应拒绝，不能保证所有原因的 L04/L07 永不出现。

本轮没有更改生产服务或正式更新设置。18:37 只读正式版本为 Android0.4.27+2196/iOS0.4.25+2194。

自动审批拒绝失败 synthetic 目录清理及 build junction 切换，原因仅 `blocked by policy`，均未执行。保留忽略目录与原 junction，复用此前命名 disposable build cache，并将最终包/证据放入本轮新目录；不绕过删除，原正式/调试成品保持。

本地main已快进集成，原current-state修改无冲突恢复，1372既有trackedWIP内容hash保持。最终远端身份、公共工件清单与本轮branch清理见工件integration-result.json；收尾仅文档，不改变df617187移动源码或已验APK。
