# MI 6 相册保存、视频遗漏与二维码提示

## 原因证据

1. MI 6 为 API 28。旧 APK 声明 READ_EXTERNAL_STORAGE 且 granted=true，却用 manifest merger 移除了 WRITE_EXTERNAL_STORAGE。读取并发送已有图片可用，不代表能够创建媒体库文件。photo_manager 3.12.0 的 PermissionDelegate23 只在 manifest 声明 WRITE 时检查该权限；以前读取过程可以通过，实际写入仍失败。修复为 maxSdkVersion=28，并在保存时走显式权限申请。Android 10+ 不申请旧存储权限。
2. 只读查询设备 MediaStore：6 张图片、2 段 MP4。两段视频 duration 分别为 2265/2070ms，但 width/height 均为 NULL。按插件默认条件 `width >= 0 AND height >= 0` 查询得到 0 段；去除宽高约束得到 2 段。不是没有视频，也不是普通视频权限被拒。videoOption 改为 ignoreSize=true，保留类型及时间排序，不从缩略图缺失推断文件无效。
3. 二维码：再次只读查询生产 business-api 容器 OpenAPI，仅有隐私自动入群开关与 groups/auto-join，没有 join-tokens 签发/兑换/撤销接口。之前仅更新 APK，没有部署本地群令牌接口及迁移。提示中的“管理员”指项目维护方，容易误导为群管理员；改为“群二维码服务尚未部署，暂时无法生成”。实际服务仍待部署，未伪称修复生成能力。

## 修改及审查

- 相册写权限只限定 Android <=28；保存前判断系统版本，旧系统请求 storage，iOS 请求 add-only，新 Android 通过 MediaStore 写自己的媒体。用户拒绝时停止保存，不用 adb 自动授权。
- 不再把下载失败、磁盘或插件写入失败都显示为相册权限问题；权限拒绝使用专门提示，其他失败保留一般保存错误。
- 图片和视频共用 `ViewerStatusHint`，圆角、背景、白字、字号及位置一致。
- 保持 Matrix E2EE、业务接口与金融逻辑不变。没有上传用户相册内容到业务 API，没有改动生产数据库。设备诊断仅查询媒体类型/时长/宽高，没有输出文件名或内容。
- 沿用用户此前授权的暂不更新 Figma；不编辑设计账本或伪造 Figma 验证。未动其他任务的统计助手 HTML。

## 验证

目录 `artifacts/2026-09-05/gallery-save/`：

- red.log：旧系统写权限缺失、默认视频宽高过滤两个断言失败。
- green.log：图库分页/缓存、图片/视频交互、二维码错误提示等 33 项通过。
- permission-test.log：补充 Android 28 申请、Android 33 不申请、拒绝抛出专用异常；共 3 项通过。
- analyze.log：Flutter analyze 无问题。
- ui-contract.log：17 components/330 screens drift PASS；不代表完成 Figma 更新。
- build.log：standard flavor、arm64、debug 源码构建通过。aapt 确认最终 APK 的 WRITE_EXTERNAL_STORAGE maxSdkVersion=28。
- install.log：MI 6 覆盖安装 Success，已启动，未卸载或清数据。设备查询 versionCode2039；READ/WRITE_EXTERNAL_STORAGE 均 granted=true，未用 adb grant。实际点击保存及视频显示交由用户复测，未宣称完成真机媒体写入验收。
- 总验证 verify.log：业务 API/Worker 311 passed、19 skipped；移动边界 47 passed、4 failed，仍是此前已在基线复现的通话布局/native action 源码字符串检查，总验证退出 1。后续步骤未执行，不能宣称项目全绿。

测试 APK：`artifacts/2026-09-05/gallery-save/ChatFlow-0.3.36-arm64-debug-gallery-fix.apk`。

SHA256：`3301587EE6AEF37544F7AB53282DA1F2A1AC8F0DB8BB70075B1C3F8389729D7A`。
