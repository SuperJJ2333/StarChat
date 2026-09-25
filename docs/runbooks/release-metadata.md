# Android / iOS 轻量发布门禁（2026-09-20，用户批准）

本流程取代历史“公网完整下载 APK/IPA → 再解包/验签/哈希”步骤。发布阶段不从公网下载安装包；保留构建阶段已有门禁和上传完整性控制。HEAD 只能证明可访问和大小，不证明包内容/签名有效。**2026-09-24 补充：** 企业回签会替换候选 IPA 的实际签名；最终回签包须在本地运行 `scripts/verify_ios_enterprise_ipa.py`。发布器会从服务器本地已上传的同一 IPA 重新提取身份/权益，并将它与 CI 原始 IPA 做非签名内容比对，核对两份 SHA256；不从公网回拉完整包。重签前 CI 结果或交接确认人文本不能代替最终包检查。

## 单一发布记录

保存 UTF-8 JSON（本地放 docs/verification/artifacts/<日期>/<任务>/release.json）：

```json
{
  "platform": "ios",
  "version": "0.3.102",
  "build": 2144,
  "artifact_url": "https://www.liuhetong888.com/downloads/ChatFlow-0.3.102-build2144-ios.ipa",
  "artifact_bytes": 44218488,
  "bundle_id": "com.liuhetong.liuhetongMobile",
  "ios_ci_candidate_sha256": "填写 CI 原始 IPA 的 64 位小写 SHA256",
  "signing_confirmed_by": "填写实际交接确认人"
}
```

以上大小仅是原2144包示例，重签包大小须由交接方提供，不照抄。Android platform=android、URL为不可变APK；bundle_id仅iOS必填。signing_confirmed_by记录实际签名交接，不允许空值。`ios_ci_candidate_sha256` 来自 CI 产出的**原始 IPA**，要在企业回签前记录；不得用回签包的 SHA 代替。iOS 发布记录还必须包含检查器输出的 `ios_ipa_evidence` 对象（**最终回签 IPA** 的 SHA256、字节数、Bundle ID、version/build、实际企业 Team、profile/Runner 已签 App ID、Keychain groups、APNs、get-task-allow、ProvisionsAllDevices）；从**真机当前已安装旧包**核验的 `ios_upgrade_from` 对象（旧版 version/build、Team ID、已签 App ID、Keychain groups）；以及 `ios_upgrade_test` 对象（`candidate_sha256`、`old_version`、`old_build`、带时区的 `performed_at`、非空 `performed_by`、`installed_without_uninstall=true`、`pre_upgrade_healthy=true`、`chat_history_preserved=true`、`login_preserved=true`、`keychain_preserved=true`、`background_notifications_confirmed=true`）。这里 `ios_upgrade_test.candidate_sha256` 指真机**实际安装的最终回签 IPA**，必须等于 `ios_ipa_evidence.sha256`，与 CI 原包 SHA 是两个不同值。升级测试须在原版可登录、持有旧聊天数据的 iPhone 上直接覆盖安装此最终 SHA 的包；身份记录和测试必须对应同一旧版。不要手写或复用另一包的检查器证据；记录 `artifact_bytes` 必须是同一文件的字节数。不改变既有安装包ID或最低支持版本。

### 最终回签 IPA 交接门禁

在本地取得**最终**企业回签 IPA 后、生成发布记录及上传前运行：

```powershell
python scripts/verify_ios_enterprise_ipa.py <最终IPA绝对路径> --bundle-id com.liuhetong.liuhetongMobile --version <版本> --build <构建号> --team-id <实际企业TeamID> --output docs/verification/artifacts/<日期>/<任务>/ios-ipa-evidence.json
```

脚本必须以退出码 0 产生证据；把 JSON 对象原样放入发布记录的 `ios_ipa_evidence`。它从最终 IPA 读取 Info.plist、企业描述文件 CMS 和 Runner Mach-O 实际签名权益，默认要求 App ID 为 `<实际企业TeamID>.com.liuhetong.liuhetongMobile`、企业分发、`get-task-allow=false` 和生产 APNs。允许与历史不同的企业 Team，但**保留旧数据覆盖升级**还须核对真机当前已安装包的 Team/App ID 与 Keychain 默认/历史组；仅新包内部一致不证明可覆盖升级。若 Team/App ID 与旧包不同，普通重签应停止发布，除非取得 Apple 特殊迁移权益及对应真机验证。其他仅前台测试包在用户明确接受后可使用 `--allow-no-apns` 与 `"ios_allow_no_apns": true`；**本次沿用旧 App ID 的 0.4.7/2173 恢复更新禁止该例外，必须具备生产 APNs 并完成后台提醒验收**。检查器读取签名元数据并验证 profile CMS 内容签名，但不替代 Apple 证书链、设备安装或覆盖升级测试。错误 IPA 应保留为证据，不修改 plist 伪装为通过。

从 CI 下载原始 IPA，保留 CI 构建产物与其 SHA256；将原包、最终回签 IPA 和发布记录一起送到发布服务器本地。可在本地先运行 `python scripts/compare_ios_ipa_payload.py --candidate <CI原始IPA绝对路径> --final <最终回签IPA绝对路径> --json-out <证据目录>/ios-payload-comparison.json`。只有退出码 0、报告 `status=pass` 且 `differences=[]` 才能继续。该比对只排除受识别的代码签名数据；新增 dylib、Mach-O 非签名代码或加载命令、资源、Info.plist 变化均失败，不为签名工具注入内容设置豁免。发布器会在服务器上实际重跑比对，单独提交一份报告不能取代它。

历史 0.3.102/2144 的实际已签 App ID 为 `ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext`，与 Bundle ID 不一致；这是已安装旧包的身份基线，并非推荐给新安装的标准签名。若签名方沿用**这一精确 App ID**、Team `ZXB3TS7QD4`、旧 Keychain groups 且有生产 APNs，可在本地检查命令加 `--expected-legacy-application-identifier ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext`，发布 JSON 同时加入 `"ios_legacy_application_identifier": "ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext"`。检查器和发布器只对这一已取证的值开放例外；仍必须使用持有旧聊天数据、可正常登录的 iPhone 对**最终同一 SHA** IPA 做不卸载覆盖并证明数据保留。故障机的旧账号 L07 或删除 App 后重装不能替代该验收。[Apple TN2319](https://developer.apple.com/library/archive/technotes/tn2319/_index.html)说明已签 `application-identifier` 与旧应用不同会拒绝升级；即使字面相同，静态检查也不能保证旧包的异常签名在真机可覆盖。

## 三个命令

1. 本地生成：`python scripts/release_metadata.py prepare release.json --root frontend --output docs/verification/artifacts/<日期>/<任务>/staged`。从一份记录生成首页文案、下载页、电脑IPA链接、使用plistlib序列化的manifest及该平台settings.json；不联网、不改生产。
2. 检查线上：`python scripts/release_metadata.py check release.json`。只做APK/IPA HEAD和≤256KiB元数据GET；校验大小、XML解析、清单身份/URL/版本、MIME/no-store、官网文案及安装入口。
3. 发布：通过既有 jumper 将 `release_metadata.py`、`verify_ios_enterprise_ipa.py`、`compare_ios_ipa_payload.py`、CI 原始 IPA 和 record 上传到同一服务器 release 目录；最终回签 IPA 已在服务器不可变下载路径。iOS 运行 `python3 release_metadata.py publish release.json --root /opt/starchat/frontend --output /opt/starchat/docs/verification/artifacts/<日期>/<唯一发布目录> --ios-candidate <服务器本地CI原始IPA绝对路径>`。Android 不用 `--ios-candidate`。必须用全新备份目录；脚本在宿主执行，Settings 通过 docker exec 和公开 SettingService 更新。服务器需要 Python 3.11+ 和 OpenSSL。

发布前包已上传到不可变 URL。iOS `publish` 先核对升级真机记录、`ios_ipa_evidence` 与发布记录、服务器本地最终 IPA SHA256/大小，重新解析签名身份/权益，再检查 CI 原包 SHA 与 `ios_ci_candidate_sha256`，逐文件比对两包非签名内容；任一不符时不写备份、静态或设置。随后才做 HEAD、保存静态/双平台设置 0700 备份、拒绝 build 回退、生成并原子替换静态；公网元数据验证通过后**再次核验两包与内容比对**，将通过报告写入备份目录 `ios-payload-comparison.json`，然后写唯一平台的版本/build/下载 URL 及审计。更新说明和最低支持版本原样保留，需另行变更时使用有审计的后台。iOS 弹窗 URL 固定 HTTPS 安装页，不能填 IPA 直链或 itms-services。Android 直链 APK，另一端设置逐键校验不变。

页面门禁失败自动回退本次已写且未再变动的文件，不发布弹窗。数据库写入结果不确定时保留已验证页面及before.json，不盲目回滚/重放；先检查审计和现值，再用新备份目录重试。同值不重复写审计。源码静态页面也须随本次生成结果提交，避免后续站点部署复活旧文案。

## CI / 旧入口

`.github/workflows/release-metadata.yml` 自动运行门禁回归；手动输入release_record做只读线上检查，不触发构建或发布。
`release.ps1` / `release_ci.ps1` 只允许 `-SkipPublish` 准备包，结尾改HEAD；旧publish_app_update.py拒绝发布。GitHub Android/iOS构建Action仅提供候选；企业重签后的确认属于最终交接，不能用重签前CI结果替代。服务器下行拉取包用于部署仍是必要传输，和已取消的重复公网回拉验包不同。

## 完成口径

记录 CI 原始 IPA SHA256、最终 IPA 门禁结果及 SHA256、两包比对报告、METADATA_CHECK_PASS/PUBLISH_PASS、所用 JSON、审计/备份路径。元数据通过不等于真机安装通过；设备反馈单独记录。不得删除历史审计/已发布证据，也不得复用“完整验包通过”的旧措辞。

## 2026-09-25 iOS 2173 官网链接单独发布记录

用户明确要求官网 iOS 下载/安装链接更新到 0.4.7/2173，同时保持应用内更新检查设置不变；随后明确接受既有企业签名服务的两库、`flag` 与 Runner 加载命令注入，要求直接发布。此**单次、精确 SHA** 例外详见[任务](../workflow/tasks/2026-09-25-ios2173-link-only-distribution.md)及[证据](../verification/2026-09-25-ios2173-link-only-distribution.md)，不改变上面的常规纯回签与真机覆盖门禁。

本次使用 `scripts/publish_ios_static_links.py`，而非会写 `app_ios_*` 的 `release_metadata.py publish`。它要求最终 IPA 签名权益证据、CI/最终双 SHA、固定四项差异、官网三静态文件 SHA 前态、Android/iOS 共十项设置完整前态；在共享发布锁内重检并写 0700 备份，只落不可变 IPA、安装清单、下载页和首页 iOS 文案，再检查公网小元数据及十项设置未变。已发布 IPA 的哈希不等于真机覆盖升级、旧数据保留或注入代码运行安全的证明；仍须单独收集设备结果。
