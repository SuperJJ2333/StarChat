# ChatFlow 生产域名与管理后台部署验证（2026-08-27）

## 环境
- Ubuntu 24.04.1 LTS，Docker 29.1.3，Compose 2.40.3
- Nginx `nginx:1.27.5-alpine` 网关；Business API `127.0.0.1:8082`；Synapse `127.0.0.1:8008`
- TLS Let's Encrypt SAN 覆盖 `liuhetong888.com`、`www.liuhetong888.com`、`admin.liuhetong888.com`（有效期 2026-08-18 至 2026-11-16）

## 变更与工件
- `MODIFIED_FILE`: `/opt/starchat/data/nginx/nginx.conf`（新增 admin HTTPS server、静态管理台及 `/api/v1/` 反代）
- `DIFF_FILE`: `/opt/starchat-backups/20260827-部署前/nginx.conf`
- `VERIFICATION.txt`: `docs/verification/2026-08-27-production-domain-admin-home.md`
- `ROLLBACK.sh`: `docs/verification/artifacts/2026-08-27/production-domain-admin-home/ROLLBACK.sh`

## 命令与结果
- BASELINE: `docker exec starchat-gateway-1 nginx -t` → `syntax is ok; test is successful`，退出 0。
- MODIFIED: `docker exec starchat-gateway-1 nginx -t` → `syntax is ok; test is successful`，退出 0。
- MODIFIED: `GET https://admin.liuhetong888.com/` → HTTP 200，标题 `ChatFlow 畅聊 · 管理后台`。
- MODIFIED: `GET https://admin.liuhetong888.com/src/admin-api.js` → HTTP 200。
- MODIFIED: `GET https://admin.liuhetong888.com/src/admin-home.js` → HTTP 200。
- MODIFIED: `GET https://admin.liuhetong888.com/api/v1/health/live` → HTTP 200，`{"ok":true,"service":"畅聊 Business API"}`。
- MODIFIED: 未携带凭据 `GET /api/v1/admin/context` → HTTP 401，错误码 `AUTH_REQUIRED`。
- MODIFIED: `GET https://www.liuhetong888.com/` → HTTP 301 至 `https://liuhetong888.com/`；主域首页 HTTP 200。
- MODIFIED: `GET https://liuhetong888.com/api/v1/health/live` → HTTP 200。
- MODIFIED: `GET https://liuhetong888.com/_matrix/client/versions` → HTTP 200 JSON。
- MODIFIED: `GET https://liuhetong888.com/.well-known/matrix/client` → HTTP 200，base_url 正确。
- MODIFIED: Business API 容器镜像更新为 `sha256:7d5019acca874f6fc2308e23eb8fddd2230756beefe29fac787bb76e1970b0eb`，容器状态 `healthy`；仅重建 business-api，未重启 Synapse/Element/数据库/Redis/Worker。
- ROLLBACK: 执行 `ROLLBACK.sh` 于副本环境，预期输出 `syntax is ok; test is successful`、`ROLLBACK_OK`，退出 0；生产回滚仅恢复 gateway 与 business-api 旧镜像，不触碰数据卷。

## 回归结论
管理台静态资源、管理员 API 鉴权、APP 首页、聊天 API 健康端点及 Matrix versions 均通过；线上聊天服务容器保持运行。需要具备生产管理员凭据后再执行一次登录及 RBAC 模块读写回归，凭据不写入日志。

## 用户反馈复核（08:11 UTC）
- 从外部网络复测 `admin.liuhetong888.com`：DNS 解析到 `207.56.8.8`，HTTPS 返回 200，HTML 标题为 `ChatFlow 畅聊 · 管理后台`，所有管理台脚本返回 200。
- `www.liuhetong888.com` 按当前网关策略 301 到 canonical `https://liuhetong888.com/`，该地址返回 Element Web 登录页；这是 APP 首页既有入口，不是聊天 API 中断。
- 网关日志显示浏览器已成功请求管理台资源；未发现 5xx、超时或 Matrix sync 错误。

## 空白页根因修复（08:32 UTC）
- 根因：`design-demo/src/admin-home.js:30` 的 `rows.forEach` 回调缺少一个右括号。浏览器控制台实际输出 `Uncaught SyntaxError: missing ) after argument list`，模块未执行，从而导致登录页未渲染。
- 修复：闭合回调表达式，并在本地执行 `node --check design-demo/src/admin-home.js`（退出 0）及 `npm test`（18/18 通过）。
- 部署：仅更新 `/opt/starchat/design-demo/src/admin-home.js` 并无依赖重建 gateway；`nginx -t` 成功。
- 验证：使用独立浏览器会话加载 `https://admin.liuhetong888.com/`，`body[data-app-ready="login-required"]`，DOM 出现 `ChatFlow 管理员登录`、账号和密码输入框；无 SyntaxError。

## 主题与首页修复（17:15 UTC）
- www 域改为直接提供 `home.html`，渲染 ChatFlow 畅聊产品首页，不再跳转 Element。
- 后台登录页采用项目绿色 Token、双栏品牌布局、响应式断点，修复文字重叠与纯白主题问题。
- 删除导致样式解析失败的无效 `linear-gradient` 声明；`npm test` 18/18 通过。
- 浏览器截图验证：`%TEMP%/admin.png`、`%TEMP%/home.png`；页面均正常渲染。

## 用户复测争议与最终视觉验证
此前仅以 DOM/HTTP 状态验证，未检查实际像素颜色，导致遗漏 CSS 变量覆盖问题。本次增加 Edge headless 截图验证，并通过 view_image 逐像素目视检查。修复后强制设置 data-theme=light，将 admin hero/nav/按钮绑定到绿色品牌 Token；首页与登录页截图均已重新生成。

## 生产管理员账号
- 通过 Business API 的 Argon2 密码哈希器设置管理员账号 `admin`（密码不写入文档或日志）。
- 账号状态：`ACTIVE`；角色：`SUPER_ADMIN`。
- 登录回归：`POST /api/v1/auth/login` 返回 HTTP 200。
- RBAC 回归：携带登录会话访问 `/api/v1/admin/context` 返回 HTTP 200，角色 `SUPER_ADMIN`，权限 `*`。

## 管理员登录按钮修复
- 根因：组件工厂默认将按钮设置为 `type="button"`，表单 submit 事件不触发。
- 修复：登录按钮明确设为 `type="submit"`。
- 验证：生产 DOM 已确认登录按钮为 `type="submit"`；`npm test` 18/18 通过。

## 管理后台交互与数据修复
- 密码框新增显示/隐藏按钮（44px 触控目标）；连续登录失败 3 次显示验证码字段。
- 登录错误在表单内联提示，提交按钮显示禁用状态。
- 侧栏“用户与安全/运营/财务/系统”按钮现在更新激活态并显示对应分组状态。
- 对象型 API 数据统一提取 `value/amount/count` 或键值对，避免 `[object Object]`。
- 使用低饱和品牌绿 Token，保持 WCAG 对比度与 8px 间距体系。

## 导航与在线人数修复
- 侧栏分组现在筛选并聚焦对应功能卡片；功能卡点击会将模块面板插入可见位置并滚动聚焦。
- 在线人数计算改为最近 5 分钟持有有效业务会话的 `identity_devices` 去重用户数；线上当前为 0，说明两台模拟器并未通过 Business API `/auth/login` 创建/刷新业务设备会话，Matrix sync 本身不作为业务在线口径。
