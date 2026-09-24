# Android / iOS 轻量发布门禁（2026-09-20，用户批准）

本流程取代历史“公网完整下载 APK/IPA → 再解包/验签/哈希”步骤。发布阶段不从公网下载安装包；保留构建阶段已有门禁和上传完整性控制。HEAD 只能证明可访问和大小，不证明包内容/签名有效。**2026-09-24 补充：** 企业回签会替换候选 IPA 的实际签名；最终回签包须在本地运行 `scripts/verify_ios_enterprise_ipa.py`。发布器还会从服务器本地已上传的同一 IPA 重新提取身份/权益，并核对交接证据及 SHA256；不从公网回拉完整包。重签前 CI 结果或交接确认人文本不能代替最终包检查。

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
  "signing_confirmed_by": "填写实际交接确认人"
}
```

以上大小仅是原2144包示例，重签包大小须由交接方提供，不照抄。Android platform=android、URL为不可变APK；bundle_id仅iOS必填。signing_confirmed_by记录实际签名交接，不允许空值。iOS 发布记录还必须包含检查器输出的 `ios_ipa_evidence` 对象（SHA256、字节数、Bundle ID、version/build、实际企业 Team、profile/Runner 已签 App ID、Keychain groups、APNs、get-task-allow、ProvisionsAllDevices）；从**真机当前已安装旧包**核验的 `ios_upgrade_from` 对象（旧版 version/build、Team ID、已签 App ID、Keychain groups）；以及 `ios_upgrade_test` 对象（`candidate_sha256`、`old_version`、`old_build`、带时区的 `performed_at`、非空 `performed_by`、`installed_without_uninstall=true`、`chat_history_preserved=true`、`login_preserved=true`）。升级测试须在持有旧数据的 iPhone 上直接覆盖安装此 SHA 的候选包；身份记录和测试必须对应同一旧版。不要手写或复用另一包的检查器证据；记录 `artifact_bytes` 必须是同一文件的字节数。不改变既有安装包ID或最低支持版本。

### 最终回签 IPA 交接门禁

在本地取得**最终**企业回签 IPA 后、生成发布记录及上传前运行：

```powershell
python scripts/verify_ios_enterprise_ipa.py <最终IPA绝对路径> --bundle-id com.liuhetong.liuhetongMobile --version <版本> --build <构建号> --team-id <实际企业TeamID> --output docs/verification/artifacts/<日期>/<任务>/ios-ipa-evidence.json
```

脚本必须以退出码 0 产生证据；把 JSON 对象原样放入发布记录的 `ios_ipa_evidence`。它从最终 IPA 读取 Info.plist、企业描述文件 CMS 和 Runner Mach-O 实际签名权益，要求 App ID 为 `<实际企业TeamID>.com.liuhetong.liuhetongMobile`、企业分发、`get-task-allow=false` 和默认生产 APNs。允许与历史不同的企业 Team，但**保留旧数据覆盖升级**还须核对真机当前已安装包的 Team/App ID 与 Keychain 默认/历史组；仅新包内部一致不证明可覆盖升级。若 Team/App ID 与旧包不同，普通重签应停止发布，除非取得 Apple 特殊迁移权益及对应真机验证。缺 APNs 只有用户明确接受**仅前台功能**时才可同时加检查器 `--allow-no-apns` 和发布记录 `"ios_allow_no_apns": true`；此时后台来电/消息提醒不得验收。检查器读取签名元数据并验证 profile CMS 内容签名，但不替代 Apple 证书链、设备安装或覆盖升级测试。错误 IPA 应保留为证据，不修改 plist 伪装为通过。

## 三个命令

1. 本地生成：`python scripts/release_metadata.py prepare release.json --root frontend --output docs/verification/artifacts/<日期>/<任务>/staged`。从一份记录生成首页文案、下载页、电脑IPA链接、使用plistlib序列化的manifest及该平台settings.json；不联网、不改生产。
2. 检查线上：`python scripts/release_metadata.py check release.json`。只做APK/IPA HEAD和≤256KiB元数据GET；校验大小、XML解析、清单身份/URL/版本、MIME/no-store、官网文案及安装入口。
3. 发布：通过既有jumper将 `release_metadata.py`、`verify_ios_enterprise_ipa.py` 和 record 上传到同一服务器release目录，再运行 `python3 release_metadata.py publish release.json --root /opt/starchat/frontend --output /opt/starchat/docs/verification/artifacts/<日期>/<唯一发布目录>`。必须用全新备份目录；脚本在宿主执行，Settings通过docker exec和公开SettingService更新。服务器需要 Python 3.11+ 和 OpenSSL。

发布前包已上传到不可变URL。iOS `publish` 先核对升级真机记录、`ios_ipa_evidence` 与发布记录、服务器本地 IPA SHA256/大小，并从该 IPA 重新解析并比较签名身份/权益；不一致时不写静态或设置。随后才做 HEAD、保存静态/双平台设置0700备份、拒绝build回退、生成并原子替换静态；公网元数据验证通过后再次检查 IPA，然后写唯一平台的版本/build/下载URL及审计。更新说明和最低支持版本原样保留，需另行变更时使用有审计的后台。iOS弹窗URL固定HTTPS安装页，不能填IPA直链或itms-services。Android直链APK，另一端设置逐键校验不变。

页面门禁失败自动回退本次已写且未再变动的文件，不发布弹窗。数据库写入结果不确定时保留已验证页面及before.json，不盲目回滚/重放；先检查审计和现值，再用新备份目录重试。同值不重复写审计。源码静态页面也须随本次生成结果提交，避免后续站点部署复活旧文案。

## CI / 旧入口

`.github/workflows/release-metadata.yml` 自动运行门禁回归；手动输入release_record做只读线上检查，不触发构建或发布。
`release.ps1` / `release_ci.ps1` 只允许 `-SkipPublish` 准备包，结尾改HEAD；旧publish_app_update.py拒绝发布。GitHub Android/iOS构建Action仅提供候选；企业重签后的确认属于最终交接，不能用重签前CI结果替代。服务器下行拉取包用于部署仍是必要传输，和已取消的重复公网回拉验包不同。

## 完成口径

记录本地最终 IPA 门禁结果、SHA256、METADATA_CHECK_PASS/PUBLISH_PASS、所用JSON、审计/备份路径。元数据通过不等于真机安装通过；设备反馈单独记录。不得删除历史审计/已发布证据，也不得复用“完整验包通过”的旧措辞。
