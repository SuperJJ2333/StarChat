# iOS 企业回签 IPA 发布门禁验证（2026-09-24）

## 结果边界

本任务只修改本地发布校验源码、测试和操作手册，没有制作新 IPA、安装 iPhone 或写入生产。现有 0.4.7/2172 回签 IPA 在显式允许缺少 APNs 的条件下仍以退出码 1 被检查器拒绝：`profile or signed application-identifier does not match bundle identity`。它不能作为已验证可覆盖升级的包发布。生产此前由另一并发流程部分指向该包，本任务没有执行那些写入；并发流程的暂停完成通知尚未收到。

## 存档包对照

| 包 | 来源与 SHA256 | 已签 App ID | 签名/权限 |
| --- | --- | --- | --- |
| 0.3.96/2134 | 服务器不可变发布包，`60a09413d7604cb950354bcff9ee7f40a96b2748ee01eeeda50943700129a78f` | `ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext` | Team `ZXB3TS7QD4`、企业证书 SHA256 `26c4398b38d79a389509237d02fee6133755c4c3d786179aa4c43f3142b46b22`、Keychain `[ZXB3TS7QD4.*, com.apple.token]`、生产 APNs |
| 0.3.102/2144 | 服务器不可变发布包，`48721e9c2e566a0404d17e25178c2c77de81cc46fb414afc02e7dc058afc4e13` | 与 2134 相同 | 与 2134 相同的 profile UUID、证书、Keychain 组及生产 APNs |
| 0.4.7/2172 | 用户回签包，`12258dac74ace99c7d462b5a50ec99122b5d45861e753715e27c26fc6c0b53f2` | `ZXB3TS7QD4.cn.edu.buaa.bhpan.fileProvider` | 与旧包相同证书/Team/Keychain 组；换了 profile UUID，缺生产 APNs |

旧两包的已签 App ID 后缀同样不同于 `CFBundleIdentifier=com.liuhetong.liuhetongMobile`。这些是归档包事实，并非当前 iPhone 实际已装包的身份证明。用户设备记录确认 iPhone 曾运行 0.3.96，未记录精确 build/包哈希。2144 的一次安装失败发生于 manifest XML 错误、设备未请求 IPA 的阶段，不能归因于签名。

Apple [TN2319](https://developer.apple.com/library/archive/technotes/tn2319/_index.html)记录了升级 App ID 不一致被拒绝的情况；[QA1710](https://developer.apple.com/library/archive/qa/qa1710/_index.html)说明 App ID 应基于 Bundle ID 正确生成。同证书和 Keychain 组不足以证明覆盖升级保留数据，最终必须在持有旧数据的 iPhone 上不卸载旧应用测试。

## 源码与测试证据

- 新增 `scripts/verify_ios_enterprise_ipa.py`：读取同一份 IPA 字节快照中的 Info.plist、profile CMS、Runner Mach-O 已签权益；核对版本、Bundle ID、实际企业 Team、App ID、Keychain、企业分发及 APNs，输出 SHA256/字节数证据。默认需要生产 APNs；仅明确前台使用时可显式 `--allow-no-apns`。此检查不替代 Apple 证书链、完整 code signature 或设备安装。
- `scripts/release_metadata.py` 发布前在锁内比对最终包证据、旧版升级基线、绑定候选 SHA 的真机覆盖记录、服务器本地 IPA 字节数/SHA256，并从该 IPA 重新解析签名身份/权益；在写入设置前二次核对，阻止同路径换包。Android 路径不要求 iOS 证据。
- 测试先红：新增同字节快照、已签 Team 缺失及证据大小错配三项，`py -3.12 -m pytest tests/mobile/test_verify_ios_enterprise_ipa.py tests/mobile/test_release_metadata.py -q --tb=short` 退出码 1，`3 failed, 59 passed`。此前新门禁和旧版连续性测试也各自先红，记录于任务台账。
- 首轮源码修正后同命令退出码 0，`62 passed in 1.41s`。随后质量审查指出发行脚本可被同一记录中的伪造权益证据绕过，并缺少设备覆盖记录；新测试先红：伪造 IPA 与缺失/错包/数据丢失覆盖记录共 6 例失败。再修正后 71 项通过。最终复审另发现畸形 XML plist 会泄露 Python traceback，新增三例先红转绿；缺少操作人名称也被一例先红揭出。最终两文件命令退出码 0，`76 passed in 1.88s`。真实 2172 IPA 用 `--allow-no-apns` 仍因 App ID 错配退出码 1。
- `py -3.12 -m pytest tests/mobile -q --tb=short`：退出码 0，`170 passed, 1 skipped in 19.59s`；`py -3.12 scripts/verify_ui_contract.py`：退出码 0，32 components/429 screens；仓库策略和部署策略各退出码 0。`git diff --check`、Python 两个发布脚本编译均退出码 0。
- `scripts/verify.ps1` 两次均主动停止：第一次在业务 API/Worker 约 10% 时因质量审查要求源码返工；第二次在该阶段约 2% 时，依据[项目变更影响复用规则](../runbooks/mobile-delivery-workflow.md)停止重复的约 28 分钟后端批次。不能把两次中止称为完整门禁 PASS。已过的仓库策略、模板、基础设施、Getui、Matrix Bot 有日志 `docs/verification/artifacts/2026-09-24/ios-enterprise-ipa-validation/verify-final2.log`。今天 09:18 HKT 的[前一功能任务完整门禁记录](2026-09-24-me-invitations-moments-interactions.md)为后端/Worker 2763 通过、77 跳过；`git diff e7ba46a4..HEAD` 加当前未提交差异对 business-api、business-worker、对应测试及 OpenAPI 导出脚本均无改动。本任务只复跑移动/发行及相关策略门禁，不重复无变化的后端输入。
- 工具：Windows PowerShell 7.6.5、Python 3.12.10；本任务源码在工作树 `D:\pythonProject\outsource\StarChat\.worktrees\online-room-refresh`。最终脚本 SHA256：检查器 `a55bde063bbbdf3189846520b0b5f8058ab30a98ec8544589e6563d0b4a85243`；发布器 `a4dac87ff4d6b481a7e1278f1fe1016c5c40f6abaa90a96e4cddd3706d9e9f18`。本任务文档相对链接检查退出码 0；`current-state.md` 的全文件历史链接扫描仍报 16 个既有失效目标，本次新增三条链接均可解析。
- Git：源码 `b5ec43a0`、记录 `1e967709` 已推送 `origin/codex/online-room-refresh`；尚未合入 main，也未将新脚本部署到服务器。

## 待完成验收

- 当前 2172 IPA 需要重签为与应用及已安装旧版兼容的身份。不同 Team 或 App ID 不得仅凭源码声明数据可保留；签名方/设备必须提供覆盖安装及聊天数据、登录状态仍在的结果。发行记录中的真机验收字段仍是操作人声明，不能由服务器自动证明设备事实。
- 生产部分发布状态必须在用户确认并发发布流程暂停后重新读取并处理。现有快照不是可直接回滚的实时前态。
- 后台消息/来电需要生产 APNs；缺失 APNs 的包不能通过这两项真机验收。
