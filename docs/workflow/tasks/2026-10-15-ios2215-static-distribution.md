# iOS2215回签包仅静态分发：签名核验阻断

用户于2026-10-15提供9w6mt9j32dyjldij_signed (2).ipa，要求推送更新但暂不启用更新弹窗；按静态官网/OTA更新理解，保留app_ios_*与Android配置。本任务仅拥有本记录和ios2215-static证据目录；没有修改生产。

最终文件37250414字节，SHA256 4087d408f5e294fe2482a6ccebef65bc0aeb73123cab25fb5a4547ad8ebd7aba。Info.plist版本0.4.46/2215，Bundle=com.liuhetong.liuhetongMobile。

严格verify_ios_enterprise_ipa.py拒绝：profile Team不是用户确认的HY9Q7Q35S5。实际profile与Runner已签权益均Team7XL5R8V6RC，application-identifier=7XL5R8V6RC.com.qiming.newhqzl299，aps-environment=production，get-task-allow=false，企业profile2027-05-18到期。仅production字段不能使不同Team/AppID匹配既有APNs身份。

compare_ios_ipa_payload.py对原包SHA137e4477…2713d7比对失败：新增flag与ozycorLdbovhmw.dylib，多项Mach-O报invalid __LINKEDIT segment range；暂不能从解析失败直接断言每项二进制损坏或恶意，只能判定纯重签验证未通过。没有篡改验证器或将旧2213例外套用新包。

证据：docs/verification/artifacts/2026-10-15/ios2215-static/{actual-identity.json,strict-check.log,payload-comparison.json,comparison.log}。诊断profile提取首次因路径少斜线失败，补斜线后成功，不涉及任何源包修改。开始精确时间未记录。

下一步：签名方按既定HY9Q7Q35S5/com.liuhetong.liuhetongMobile生产APNs身份重新签名并保持原Payload；或用户明确变更推送身份方案并提供匹配的新Team/实际AppID的服务端授权配置，先核验真实通知，再决定分发。当前未上传、未切换下载/OTA、未启用弹窗；旧包签名身份与此包相同不等于符合本次沿用现有生产推送身份的要求。
## 后续明确授权与发布完成

用户获知检查结果后明确要求“就是按照该签名包推送，因为上一个公开版本的IPA包也是该签名”。此前阻断已被本次精确文件分发授权解除，保留失败事实且不放宽通用验证器。

2026-10-15 21:17:48+08 STATIC_IOS_DISTRIBUTION_PASS；官网/下载页/OTA切换0.4.46+2215，URL https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.46-2215-enterprise-4087d408.ipa 。服务器完整SHA匹配4087d408…bd7aba/37250414字节；工作站直接HTTPS HEAD200/同长度，三静态GET完整SHA匹配receipt，manifest实际解析2215/正确URL。

Android/iOS共十项更新设置完全不变：Android0.4.46+2215，iOS0.4.44+2213，minimum均3。因此未启用2215更新弹窗，既有旧版更新逻辑保持。所有容器ID/image保持，不重启服务、不执行迁移。旧IPA保留。

复用2213已验证静态发布机制，仅替换本次版本/SHA/字节数/授权/当前三静态基线；5专项全部通过，独立规格→质量审查通过。备份 /opt/starchat/docs/verification/artifacts/2026-10-15/ios2215-4087d408-static 为0700。第一次调用在import缺release_settings.py时停止，尚未写入；补依赖后一次成功。工作站临时SSH代理启动命令被自动审批策略拦截，无具体理由；改直接HTTPS全部成功，无遗留隧道。按现行用户批准轻量发布规则未重复公网回拉整个IPA，未采纳审查建议中的过期全量下载步骤。

源码移动端未变，不重复构建/全量测试；未把服务器页面整体覆盖本地前端源文件，避免覆盖其它未合改动。后续前端整包部署应保留本次receipt的iOS链接和版本。真机安装、保数据覆盖、APNs后台到达仍未验证，不作为本次发布成功口径。证据在ios2215-static目录result.json/public-verification.json/upload-integrity.log及各静态快照。
