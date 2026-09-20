# Android / iOS 轻量发布门禁（2026-09-20，用户批准）

本流程取代历史“公网完整下载 APK/IPA → 再解包/验签/哈希”步骤。发布阶段不下载安装包、不重复验包；保留构建阶段已有门禁和上传完整性控制。HEAD 只能证明可访问和大小，不证明包内容/签名有效；不得将确认记录写成机器验签证据。2144 签名不匹配按用户确认已解决，不重新下载验证。

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

以上大小仅是原2144包示例，重签包大小须由交接方提供，不照抄。Android platform=android、URL为不可变APK；bundle_id仅iOS必填。signing_confirmed_by记录实际签名交接，不允许空值，不代表脚本已验签。不改变既有安装包ID或最低支持版本。

## 三个命令

1. 本地生成：`python scripts/release_metadata.py prepare release.json --root frontend --output docs/verification/artifacts/<日期>/<任务>/staged`。从一份记录生成首页文案、下载页、电脑IPA链接、使用plistlib序列化的manifest及该平台settings.json；不联网、不改生产。
2. 检查线上：`python scripts/release_metadata.py check release.json`。只做APK/IPA HEAD和≤256KiB元数据GET；校验大小、XML解析、清单身份/URL/版本、MIME/no-store、官网文案及安装入口。
3. 发布：通过既有jumper上传脚本和record到本次服务器release目录，然后在服务器运行 `python3 release_metadata.py publish release.json --root /opt/starchat/frontend --output /opt/starchat/docs/verification/artifacts/<日期>/<唯一发布目录>`。必须用全新备份目录；脚本在宿主执行，Settings通过docker exec和公开SettingService更新。

发布前包已上传到不可变URL。publish先HEAD；保存静态/双平台设置0700备份；拒绝build回退；生成并原子替换静态；公网元数据验证通过后再写唯一平台的版本/build/下载URL及审计。更新说明和最低支持版本原样保留，需另行变更时使用有审计的后台。iOS弹窗URL固定HTTPS安装页，不能填IPA直链或itms-services。Android直链APK，另一端设置逐键校验不变。

页面门禁失败自动回退本次已写且未再变动的文件，不发布弹窗。数据库写入结果不确定时保留已验证页面及before.json，不盲目回滚/重放；先检查审计和现值，再用新备份目录重试。同值不重复写审计。源码静态页面也须随本次生成结果提交，避免后续站点部署复活旧文案。

## CI / 旧入口

`.github/workflows/release-metadata.yml` 自动运行门禁回归；手动输入release_record做只读线上检查，不触发构建或发布。
`release.ps1` / `release_ci.ps1` 只允许 `-SkipPublish` 准备包，结尾改HEAD；旧publish_app_update.py拒绝发布。GitHub Android/iOS构建Action仅提供候选；企业重签后的确认属于最终交接，不能用重签前CI结果替代。服务器下行拉取包用于部署仍是必要传输，和已取消的重复公网回拉验包不同。

## 完成口径

记录METADATA_CHECK_PASS/PUBLISH_PASS、所用JSON、审计/备份路径。元数据通过不等于真机安装通过；设备反馈单独记录。不得删除历史审计/已发布证据，也不得复用“完整验包通过”的旧措辞。
