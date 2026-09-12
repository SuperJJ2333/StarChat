# 历史检索、滚动与群聊接收延迟实施计划

> 执行使用 subagent-driven-development，Astra 定位/设计/实际差异审查；明确 gpt-5.6-terra 实施与针对测试。复用当前独立工作树，不覆盖根工作区现有改动。

目标：修复日期搜索串行历史扫描与历史窗口滑动卡死，定位50人群发时接收延迟，按证据修复；不把模拟测试宣称真机/生产压测。
架构：Matrix保留E2EE与本地历史权威。日历从已有本地日期元数据首显，旧历史扩展有界且可取消；可见窗口滚动校正不抢占手势。接收链路分解HTTP/sync存储解密/UI投影耗时，先定位后改造。
技术：Flutter/Dart、vendored Matrix SDK、本地SQLCipher/SQLite；无业务金融/API/schema变更。

- [x] I0 对齐实际2096基线：设备已确认0.3.87-debug/2096，root main=f6405c04，其merge d145父6db66f0c+aac3d806未包含401b3938。当前新分支codex/history-latency-20260912从401建立，merge main；唯一冲突contacts_page.dart由Terra逐块合并，保留双方presence三态/并发保护、离线开会话、请求节流和朋友圈预览。Astra审查stage1/2/3与最终调用链；contacts/profile定向回归。不得整文件ours/theirs，不自动push。
- [ ] H1 日期：已证实ChatSearchPage打开立即loadCalendarMonth→loadThrough(月初)→串行60条SDK本地/网络历史；全量allMessages转搜索模型并重新汇总日期。先写实际入口held-history失败测试，已知日期不等待网络，禁止一打开日历就整月回溯。具体索引/旧日期扩展方案在读SDK公开存储能力后细化；不以永久禁用未知日期或隐藏历史伪修复。允许room_page日历区、chat_search_page日历区、独立日期摘要组件、必要公开capability及测试；与H2共享room_page修改必须串行。
- [x] H2 历史滚动（局部24项及analyze通过，最终H1整合回归待V/D）：沿room_page _onMessageScroll/_prefetchHistory/_shiftWindow→TimelineScrollAnchor→RoomTimelineViewport/Controller，复现五天前定位、上滑再反向下滑。重点验证自动/程序滚动误触发双向换窗、无进展重复prefetch、锚点校正取消拖动及异步旧请求。先真实Flutter可滚动多高度历史回归，检查多次双向滑动、两端边界、迟到加载/新消息、定位取消；保持200可见模型上限/稳定消息key/本地数据。
- [ ] H3 接收延迟：用户确认“别人已发出很久才收到”，尚无准确时间/群名。Astra只读跳板检查当前健康、资源、限流配置及脱敏汇总耗时，不造生产用户/消息、不读正文/密钥、不部署重启。核对SDK sync/历史/解密/数据库与通知监听串行阻塞；用50+不同sender事件的本地受控测试分开传输/处理/展示，指标不含消息正文。只有有证据的缺陷交Terra改；没有历史遥测的50秒精确归因列待验证，不猜设备或服务器。
- [ ] V/D：Astra先规格再质量/安全审查；相关RED/GREEN、全量Flutter/analyze/mobile/UI契约与基线失败身份比较；verify环境预检/证据复用。需要新包时核对版本高于设备2096，固定APK重建/签名/哈希/保留数据安装Mi6，用户真机自测。禁止生产发布、push、数据库迁移、手机断网/清数据测试。

证据只docs/verification/artifacts/2026-09-12/history-latency/。每批文件所有权/命令/exit/时间/下一步记任务记录。目标指标：已缓存日历首显不依赖网络；双向滚动不出现程序换窗循环且窗口≤200；接收分层时间可测，实际恢复/接收P95目标≤3秒需真实负载验证，不能用测试机时长冒充Mi6结果。

## 架构细化 / 审查门槛

### I0 输入缺陷
合并新输入的MomentPreviewCache不能跨账号复用，也不能仅靠前台resume配置fetcher。使用随API/会话所有者释放的实例/弱引用作用域，组件自身配置数据源；同作用域TTL去重，切换API/用户取消旧监听，迟到响应只进原缓存。已撤权限立即隐藏，不能保留旧授权预览。增加真实组件冷启动入口与A/B账号相同好友、迟到响应、隐私失效回归。只改moment_preview_cache、moment_profile_preview、app_home相应预取和对应tests，保留2096的无闪烁缓存体验。

### H1 日期读取与定位
首显读取已载本地消息时间元数据，避免先为全部消息构造带媒体/成员的搜索模型；月切换不得为了显示网格启动整月网络扫描。未知过去日期保留可查询入口，不能把未加载当作无记录。显式选择日期后才定位：公开Matrix timestamp_to_event→带分页token的context→SDK按原E2EE流程解密→只在账号/lease/请求generation仍有效时采用；错误/取消保留旧timeline。先查已有本地数据，断网时可定位已有记录，缺失时明确提示未缓存。
context必须独立保留连续性与双向token：向旧页走prevBatch，向新页走nextBatch，不得把不连续的context和latest直接拼接。回最新时恢复live timeline，发送/接收/已读与媒体使用原公开lease接口。局部窗口仍≤200；日期切换和迟到响应、空日/状态事件/撤回/本地隐藏/时区边界、上下翻页和回最新均需用真实SDK适配fixture验证。服务端不支持/不可达必须明确错误或有界可继续查询，不能退回自动整月死循环。

### H3 可证实范围
不修改E2EE/device keys流程来掩盖接收延迟。先使用真实SDK数据库和50个合成sender事件量化批处理的消息ID列表写放大，重开数据库验证事件集合与顺序；记录固定历史规模、主机模式和阶段耗时，不当作Mi6/生产压测。若优化事务内同key中间写，必须保持put/delete/clear顺序、同事务读可见性、失败回滚、事务外写与账号隔离，且不动账本schema或密码/密钥。另需有受控sync处理与清理阶段的数值测量，实际50秒事件无对应日志则保留未验证。

