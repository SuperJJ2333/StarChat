# 财务修复合入 main、生产与 Mi 6 交付

授权：用户明确要求将上一轮修复合入 main、部署并安装到 Mi 6。继承 F1–F6/N1–N2，不自行发布 Android/iOS 正式更新或执行资金写入。

1. Astra 冻结 main/任务工作树，保存重叠文件原文和 SHA；Terra 在独立 scratch 三方整合冲突，保留钱包/客服/补录已有未提交修改。只将本任务提交合入 main，其他未提交改动保留。
2. Astra 检查实际合并结果、重跑集成 Flutter/前端/合约与相关 API；此前未改变输入的长门禁按 mobile-delivery-workflow 复用，任何失败如实处理。
3. Terra 只读生产/设备预检并准备精确发布清单。Astra 核验当前镜像、schema、Compose、文件差异，基于当前生产镜像增量候选；备份/回退准备完成后只替换 business-api，不改账本、schema、个推、E2EE 或更新设置。
4. 冻结版本与源码：ARM64 debug 源码构建→Apktool 2.12.1→zipalign36→固定签名→语义/代码/资产/证书验证。ADB 保留数据覆盖安装 Mi 6，再拉回核对 SHA 与版本，不执行用户功能测试。
5. 记录 main commit、生产镜像/健康/401/哈希、最终 APK SHA/签名/安装版本、未验证项与时间。执行代理明确指定 gpt-5.6-terra，最多两个；Astra 主审。

所有临时文件归 docs/verification/artifacts/2026-09-13/finance-six-release/。部署源使用与线上合成的精确清单，不能整树覆盖现网；本地其他任务变化不能默认为待发布后台。
