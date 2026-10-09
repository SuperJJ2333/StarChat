# 已发布iOS2213启用普通更新弹窗

用户在官网指定包分发后明确授权“好的，请你推送IOS更新弹窗”。使用已发布精确SHA9e5d3582…bc8a21的0.4.44+2213，不重建/替换IPA，不把签名失败视为通过。

1. 读取实时十设置、已发布三静态和IPA SHA/大小、公网元数据、运行容器。绑定上一官网发布receipt，未知漂移拒绝。
2. 复用未变release_settings.py的PostgreSQL十键事务CAS和SettingService审计，仅改iOS latest_version/build；更新说明、最低支持3、HTTPS安装页和Android五设置全部保持。
3. SPEC→QUALITY审查发布脚本；共享发布锁、唯一trace空审计前态、0700持久备份。先preflight再apply，不对结果不明的DB操作盲目重试。
4. 检查两条审计、实际路由两平台/legacy投影、未授权401、公网下载入口和原服务身份保持；更新任务/索引，提交文档。真机弹窗/安装反馈单独记录。
