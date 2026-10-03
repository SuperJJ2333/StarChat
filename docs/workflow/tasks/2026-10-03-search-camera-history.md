# 搜索、系统相机与三天历史任务

启动可靠观察2026-10-03 23:08:16+08；记录2026-10-03T23:14:02.877150+08:00。用户报告正式Android0.4.27/2196：搜索加载文字抽动，一天前点击加载失败，要求去年消息可跳转；MagicOS8.0/荣耀50Plus/Android14拍摄/录像显示拍摄失败；新设备/同设备切账号加载最近三天群聊/私聊并正确解密。此前自主ADR/计划、debug安装、main集成授权保持。新设备是否完成密钥恢复的可选问题待答，不阻塞独立工作。

状态：调查/计划；基线main c69d07cf，已交付2197debug尚不含此三项修复。主仓1387项既有WIP保持；新managedworktree/branch codex/search-camera-history-20261003干净。产品code仅声明任务领取后改。计划../../superpowers/plans/2026-10-03-search-camera-history.md；规格../../superpowers/specs/2026-10-03-search-camera-history-design.md；证据../../verification/artifacts/2026-10-03/search-camera-history/。

初步证据：chat_search_page._historyChanged将history全部当安全失效并clear/restart；room_page._scrollToMessage仅openAnchor当前窗口后反复loadEarlier；SDK已有日期context却无显式事件locator。相机manifest无IMAGE_CAPTURE/VIDEO_CAPTURE queries；固定plugin grantUriPermissions依赖queryIntentActivities逐个grant且启动Intent不带通用URI flags。Matrix同步只sync/uploadPending，未看到72h全部房间hydrate。均为待行为复现的候选根因，不把源码推断当真机结论。

验收ID S1搜索/旧anchor，C1系统拍摄，H1三天历史+密钥恢复，D1相关最终门禁与实际debug安装。每项分别记录实现/测试/发布/物理验证。E2EE保护ADR设计及双审必做；无用户密钥不能保证历史解密，保持缺密钥状态。

下一步Task1独立规格/领域、质量/安全复核，修正重要发现后转交Task2相机；Task3 ADR设计已通过有序复审，源码尚未启动。root不编辑转交源码、不并发Flutter/Gradle。

## 调查更新

用户明确新设备“没有恢复步骤或尚未完成”；现有MatrixSecurityPage无实际导航引用，恢复按钮只unlock/maybeCacheAll而未loadAllKeys。Task3范围增加可达且完整的用户密钥恢复入口、真实匹配备份版本和恢复后重试，SAS现有不完整UI不得当作已可用转移。ADR设计正在独立审查。Task1实际SDK/Widget RED证明3次查询而应1次、旧事件anchor返回false；同组原有日期20case通过，task-1-red.log实际exit1。

2026-10-03 23:45:34+08：Task1源码提交6df1fc376c54e413a168ec6a96097bf1e5673df4，25文件聚焦224PASS、14改动文件analyze零问题；最终输入hash和实际失败迭代保留task-1-report.md。23:51+08进入独立审查，尚未称真机修复或构建新包。Task1释放Flutter/Gradle和源码所有权。

Task3设计ADR SHA256 9e831d5f7767b1ad773f108456bf2c4887e1ed44e2b49504ec57f74170d090c4 已通过领域/规格再质量安全审查。recent-history-design-review.md §6记录另一个既有问题：创建按钮仅创建秘密存储，首次在线房间密钥备份不完整。无现成密钥时不能声称恢复完成；新备份/SAS额外路径需先补具体保护设计并审查，不能替换未知或已存在备份。旧手机/现有恢复材料的可选问题保持待答，不阻塞Task1/2或既批密文补齐与真实密钥导入工作。
