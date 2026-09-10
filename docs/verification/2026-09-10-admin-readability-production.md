# 后台可读性更新生产部署证据 — 2026-09-10

用户明确授权按 docs/runbooks/app-release-deployment.md 发布。维护步骤及回退见 docs/runbooks/admin-readability-deployment.md。

## 已部署

- 仅重建 business-api：旧 sha256:0d330c6e2172c637b28fca9d788ea511b718af6698cbf904570257dfe6f4a839 → 新 sha256:f62cd9d02c402cd6d86058951652c29cf588483f0b8f821ace2e9e3dedc9901f。
- 17 个静态文件已逐文件原子安装；admin.html 最后安装。生产后台 https://admin.liuhetong888.com/。
- 实际 API 环境、命令、入口、挂载、网络、健康检查、日志与隔离配置与发布前一致。最终 healthy、restart_count=0。所有其他运行容器 ID 保持不变，包括 Worker。
- 数据库版本0059_chat_payment_pin；无迁移，无资金控制操作，无移动端更新设置操作。download.html、index.html、admin-session.js哈希保持不变。

## 发布前验证

本地功能验收见 2026-09-10-admin-readability.md。上传发布包SHA256为29ec87a06859065a10dc65108d3afd35df5a90665222e5a7a7a2fe5f8f7b4828，服务器校验通过。发布包包含17个静态文件及4个API只读投影文件，未包含测试浏览器目录或本地运行数据。

生产AST差异检查：admin.py仅create_admin_router及其module_data改变；supply_reports仅_item/issuance_page/issuance_detail及新增actor关联函数改变；没有新增金融写路径。共享tokens.css仅将既有后台颜色token适用范围扩展至凭证弹窗。admin-home生产差异不涉及首页下载内容。

数据库备份2426663字节，SHA256 f57f165092d5b25f96e48e49bb6c522f765536d71a061ea735b2aef5a7e94f92。备份在独立--network none PostgreSQL中成功恢复，版本与生产一致。候选/回退容器create-only配置比对通过，未启动连接生产；候选断网导入通过。演练容器及恢复卷已由带归属检查的脚本移除。

完整备份和生产配置只保存在服务器0700发布目录/opt/starchat/releases/admin-readability-20260910/，未复制到工作区。

## 审查及故障测试

独立审查确认仅API重建、Worker不停止；发现静态回退异常会跳过API回退，已改try/finally并做4项离线测试全部通过。新增静态文件回退后保留但旧HTML不引用；仅当其哈希等于本次清单时允许再次部署，未知漂移继续阻断。已有静态文件恢复后核验旧哈希。未在生产主动触发回退。

## 发布后验证

- 服务器及工作站分别从admin域名读取全部17个静态文件并校验SHA256，通过。
- 容器内4个API文件哈希与清单一致。
- 服务器及工作站分别验证主域名health/ready为JSON200且database=ready；未登录/admin/modules/security及/app-updates/latest为JSON401/AUTH_REQUIRED。
- 通过实际生产数据库SET TRANSACTION READ ONLY，校验两条用户记录及下一页无交叉、畅聊号搜索命中；两条发行记录及凭证明细通过新Pydantic契约校验。只输出检查计数，未导出账号、邮箱、余额或凭据。
- Chrome打开真实后台登录页，Logo正常加载、favicon引用正确，无页面脚本错误；截图production-login.png。未获取管理员令牌，未执行生产封禁或发行操作；登录后的交互由前一轮本地真实页面合成API测试覆盖。
- nginx -t通过；最终再次执行static_release.py verify通过。

最初工作站静态探针误用了API主域名，返回404。检查实际nginx路由后改用admin.liuhetong888.com，最终全部通过；没有为探针改动网关。

脱敏工件：docs/verification/artifacts/2026-09-10/admin-production/。公网页面/健康结果见public-verification.json及server-public-postflight.json；运行结果见postdeploy-summary.json。

“blocked by policy”是工具执行层的通用拒绝，不是服务器部署报错。此前浏览器启动和临时目录清理命令被拒绝，工具未提供细分规则，不能据此断言用户权限或服务器防火墙错误。本次SSH、上传、候选演练、发布和验证均成功执行。
