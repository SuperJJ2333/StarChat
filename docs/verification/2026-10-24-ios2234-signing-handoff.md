# iOS 0.4.65 (2234) 企业签名交接

## 身份与范围

- 用户批准：修复统计助手 HTML 注入后生成 IPA，用户企业签名，回传再验包与分发。
- 源码：`e25b664f29b88a50377b8cc739ad30214ec90acb`，分支 `codex/ios-history-ipa-2234-20261024`。
- [构建 40081418873](https://github.com/SuperJJ2333/StarChat/actions/runs/40081418873)，attempt 1；设备作业 `120835603035` 成功。
- 包：`ChatFlow-0.4.65-build2234-unsigned.ipa`，35,141,025 字节。
- SHA-256：`5cb972096c2331574133812b386b2b86fb94befb09f07e12e9a34c71768b1288`。
- Bundle ID：`com.liuhetong.liuhetongMobile`；arm64，最低 iOS 16.0；待企业签名，不能直接安装。
- GitHub ZIP 工件 `12555581915` SHA：`dd27a5ccda0fa07846686a3e29c89804b36b58360989215985596f3bd2da5bc7`。ZIP 与内含 IPA 的 SHA 不同。
- 没有修改钱包、认证、资金、E2EE 逻辑；没有更新生产分发。Android2233/iOS2215 发布身份保持。

## 修复与审查

统计助手最后输入改为文本节点，缓存恢复只接受合法号码/数值，丢弃非法记录批次；限定本地资产导航并绑定首次完整 URL，状态注入、桥接、退出读回检查 URL。

原输入 4 项 RED→GREEN；缓存二次入口 1 项 RED→最终 5 项 GREEN。独立规格审查后质量/安全审查通过，首轮三项问题已关闭。原生测试增加恶意缓存文本和 about:blank 导航的阻断/允许正对照，避免 DNS 失败冒充阻断成功。

## 验证

| 检查 | 结果 |
|---|---|
| Python3.12 依赖、stdin、配置导入 preflight | PASS，临时 `.env.example` 副本哈希核对后删除 |
| 移动端 Python 边界 | 404 PASS / 1 Ruby 条件 SKIP；macOS 实际 Ruby hook 2 PASS / 0 SKIP |
| Flutter analyze | PASS |
| Flutter 全量首轮 | 6328 PASS / 9 既有 SKIP / 54 ERROR，退出1；全部错误为3个历史临时目录缺失 |
| 环境补齐后5个失败文件复跑 | 55 PASS，退出0；逐套件/完整测试名/次数匹配关闭54项错误 |
| 合并同源证据 | 6382 PASS / 9 SKIP / 0 未解决失败；两次均源码哈希稳定，不宣称首轮退出0；9项为未启用 ANNOUNCEMENT_DIAGNOSTICS 的条件用例 |
| 完整 verify | 复用2026-10-23退出0的未变服务/infra/锁/脚本部分；本次补跑移动与Flutter，未冒称重新跑完整verify |
| macOS 设备编译及验包 | PASS；完整生产插件、SQLCipher导出、权限实现、锁、Payload/CRC/统计资产验证 |
| iPhone15/iOS26 原生门禁 | 作业120835603290结束FAIL：统计1、通知1、时间线13、SQLCipher6、Keychain1共22PASS；Outbox2ERROR，保留未验收 |

原生模拟器使用独立诊断宿主，仅因 MLKit 无 arm64 模拟器切片排除 mobile_scanner 6.0.11；设备 IPA 保留全部生产插件。模拟器证据不等于生产扫码、企业签名或物理设备升级验收。`native-ci-tail-2.log` 已记录统计安全用例 `00:22 +1: All tests passed!`。

工具链：Xcode26.3(17C529)、Flutter3.44.9、Dart3.12.2、Python3.12.10、Ruby3.3.12、CocoaPods1.17.0。Windows测试只从受限项目归档恢复两个既有哈希的 Olm/SQLCipher DLL，没有提取用户配置或数据；短盘符V由本任务创建并已撤销。

另有已知 main macOS 宿主视频缓存3项基线失败（39902309606），预期 `quota-v1.sqlite`，实际 `quota-v1.dirty` / `UnimplementedError`；没有通过改业务代码或删除测试掩盖，也不称所有历史平台CI均通过。

## 包内核对与回签要求

本地重新校验 CRC、480 个文件、Info.plist、设备架构/最低OS、加载目标和全部 framework 二进制哈希；统计 HTML SHA `109c333113b8c2b2fa273f3aa17358e2628ec2b240e4d171069c10c5ca40b961` 与源码相同。Runner 无 embedded.mobileprovision / _CodeSignature；未含旧公开包附加的 `ozycorLdbovhmw.dylib` 或 `flag`。这不等于对所有运行行为或证书有效性的保证。

回签只允许必要签名变化，不植入动态库/SDK/壳或改变业务资源；Bundle/AppID/Team/Keychain/profile/production APNs 必须一致，权限最小化。最终回签 IPA 须按未签名清单逐文件和 Mach-O 比对。旧2215签名身份不一致，保数据升级需在已有数据的真机上不卸载验证，不能凭相同Bundle ID承诺。

未完成：用户企业签名、最终回签差异与权益核验、真机安装/升级/登录/聊天/推送，以及两种冷打开顺序的媒体Outbox原生验收；实际分发须等这些依赖步骤。

原生Outbox两项在 PendingMediaDirectory.directory 阶段报 MEDIA_STORAGE_UNAVAILABLE，尚未进入scope/数据库；无连接重试或硬超时。相关 Swift、策略 XCTest、Dart store、集成测试相对79e08436和本轮基线均无diff；运行时为iOS26.2/23C54，与[历史验收记录](2026-10-16-mobile-experience-2216.md)相同，旧run38817420484也有同样两项失败。历史独立探针38821916056曾确认该模拟器Data Protection读回nil；本轮通用错误没有细分内部分支，不能将历史探针当作本次精确原因，更不能据此断言真机成功。保留严格拒绝策略，不扩大业务代码修改、不靠跳过制造全绿。本次可交付待签名候选，不是正式发布批准。

## 证据和时间

证据位于主工作区 `docs/verification/artifacts/2026-10-24/ios2234-handoff/`：`review.md`、`mobile-final.log`、`verify-preflight.log`、`shared-full.log`、`shared-receipt.json`、`recovery-full.log`、`recovery-receipt.json`、`shared-combined-summary.json`、`device-ci.log`、`delivery/build-manifest.json`、`delivery/local-verification.json`、`delivery/payload-sha256.json`、`SIGNING-INSTRUCTIONS.txt`。

前置调查起点未精确记录。17:02:36+08建立候选分支；17:13:09–17:24:09+08共享全量；17:25:00–17:25:29+08目录补齐后复跑；17:25+08设备作业完成。CI与本地并行，不能简单相加为总工时。原生目标09:27:08Z开始，完整退出记录见native-exits.jsonl；总CI最终failure（仅Outbox2项）。以日志记录各阶段，不将等待计作主动开发。

原生完整证据：native-evidence.zip（工件12555732957，SHA d70b2fd5434101b2bd566ca0e1f221567ec5bc725e2d0c8e0ff492e6c039a928），展开目录 native-evidence/，包含6目标完整日志、退出记录与模拟器身份。

交付文件：C:/Users/Administrator/Downloads/ChatFlow-0.4.65-build2234-unsigned.ipa；签名说明 C:/Users/Administrator/Downloads/ChatFlow-2234-signing-instructions.txt。副本SHA与上述IPA一致。

最终交接规格→质量复核通过：明确仅企业签名候选、保留CI失败和待验收项；无阻断候选交接的问题，不批准生产发布。此复核只审报告一致性，未冒称独立重跑CI。
