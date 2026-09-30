# Android 正式更新及弹窗发布计划

用户明确授权：推送Android版本更新、更新弹窗。沿用已批准的账号/好友/视频/诊断方案和固定Android重建签名流程，不新增产品行为。

所有权：root移动版本两文件、构建工件、发布记录/任务与下载静态；版本工具agent仅bump脚本及专项测试；发布预检agent仅只读服务器证据。复用friend-video-followup隔离工作树，不覆盖并行服务端/S3任务。

1. 读取当前版本/build、网站、双端设置与实际运行API。预检固定密钥/工具/磁盘及锁；选择未占用且递增版本。
2. 修复版本工具对compiledBuildNumber的兼容（red/green），同步pubspec/app_config，运行版本及更新流程专项。仅提交范围内移动源码以冻结干净输入，保留backend/frontend工作。
3. 复用相关输入不变的4775 Flutter、analyze和仓库门禁；版本增量单独验证。正常恢复生成文件，HTTPS三项配置和性能监控enabled=true；构建standard ARM64 release，常规Apktool重建、zipalign、固定签名、独立语义/资源/清单/ABI门禁。
4. 独立规格核对后做质量安全发布核对。生成唯一release.json，从当前网站静态生成Android发布稿；保持更新说明和最低支持版本，iOS设置原值保留。
5. 上传最终重建APK至任务0700目录，检查上传SHA，再以不可变文件发布。fresh漂移检查后切Android最新别名、下载静态，通过公开SettingService更新Android版本/build/URL及审计与弹窗。不部署新API/worker或迁移；签名材料不离开本机。
6. 严格TLS两侧HEAD/小型元数据、API平台投影/401、审计/设置读回、iOS不变与旧包回退检查。发布阶段不完整回拉APK，不把HEAD当验签或真机安装。回填范围内版本和静态，更新任务及恢复索引。

实际版本、源码与工件SHA、阶段起止、真实退出/警告、回退和下一步在任务记录中更新；无需重复已经授予的Android发布授权。
