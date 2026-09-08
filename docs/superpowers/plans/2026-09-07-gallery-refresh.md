# 最近图片刷新修复计划

用户2026-09-07授权修复并debug覆盖Mi6；延续room-flow独立分支，不混入钱包未提交改动。

1. 根因：进程级FilterOptionGroup实例在首次创建时固定create/update截止时间；重扫缓存仍使用旧截止时间。
2. 回归：真实PhotoManager MethodChannel调用参数，首次访问后等待、新图片时间点后再次扫描；检查最近/视频/文件夹三个查询的两个时间条件均包含新时间且倒序。
3. 最小修复：筛选构造改getter，每次原生索引查询创建新实例；保持权限、预览缓存、分页与刷新事件逻辑。
4. 运行相册/选图/视频回归、analyze与仓库verify；按既有APK规范重建、同debug签名、实际设备versionCode递增、-r保留数据覆盖与启动验证。
