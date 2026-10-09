# 2026-10-09 Android2209 朋友圈闪照与官网测试候选

授权：用户要求更新官网测试包，并明确朋友圈相册大图无需闪照。属于有界修复；精确需求即验收设计，直接实施，不引入新产品能力。旧2208只有x64 debug，官网手机候选需要同源ARM64 release构建。暂定0.4.40+2209，构建前核对实时正式与候选版本。

1. 修复拥有 image_picker_page.dart、moment_composer_page.dart、moment_comment_composer.dart及测试：相册提供默认true聊天兼容的flash能力参数；朋友圈发帖与评论false，预览无闪照操作，编辑/选择仍可用，提交保持flash:false和原拒绝防御。RED→GREEN、相邻测试、analyze，SPEC→QUALITY。
2. root拥有版本元数据和候选构建/分发脚本、frontend/download.html及本任务文档。复用2208维护/资源/差分实现及输入绑定证据；新共享改动需最终Flutter全量门禁，相关现有失败保留基线说明。full verify缺.env仅阻断依赖检查，不引入生产秘密。
3. 正常pubget固定lock，冻结源码输入，构建standard ARM64 release、Apktool2.12.1重建、zipalign16KiB、稳定75b31签名、完整语义/资源/清单/ABI门禁。只生成测试候选，不启用全量更新弹窗。动态资源不公开上传，静态fallback保留。
4. 实时获取下载页、CloudFront、正式设置、alias、runtime；仅替换现有android-test-candidate section。不可变APK单一路径，经CloudFront installer-hong-kong精确路由和官网备用。保留旧候选及正式2206/iOS2205；未授权改正式更新弹窗/DB设置/资源授权范围。
5. 测试页RED→GREEN/旧正式下载回归、独立SPEC→QUALITY，上传SHA一致、CAS替换页面/CF、Deployed/HEAD/实际网页SHA与平台设置/runtime保持，不回拉公网整APK。任务备份/回退CAS保持。
6. 保存阶段时刻、各输入hash/命令退出码与明确限制。先前历史首个百万陌生ID准确查重约5sec/100room恢复2.4sec仍限制；本次闪照修复不宣称解决全部历史性能。
