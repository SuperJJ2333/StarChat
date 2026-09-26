# 香港核心、广州入口与区域媒体分发评估

日期：2026-09-24，Asia/Hong_Kong。范围：用户授权只读检查207.56.8.8与架构建议；没有部署、重启、DNS修改或资源购买。

## 本次证据

按admin-production-workflow，通过scripts/starchat-server.ps1与既有jumper连接。服务器记录UTC 2026-09-23 20:30:26至20:31:57（北京时间次日04:30:26至04:31:57）；随后补充正确健康路径检查。

- 用户确认现生产为香港机房、5Mbps套餐；广州8.163.93.151为干净服务器、10Mbps峰值。这两项为用户提供，未通过供应商控制台验证。
- 生产x86_64、8逻辑CPU、7900MiB内存、2325MiB available，无swap；load 0.42/0.37/0.37；根盘218G、已用57G、可用150G。这是非压测时点，不能证明千人容量。
- Synapse主进程、sync worker、两套PostgreSQL、两套Redis、business API/worker和coturn均在同机，另有其他项目和测试恢复容器。本次未停止任何容器。
- Matrix Redis容器约4.2MiB、business Redis约3.7MiB，是容器瞬时RSS指标，不是峰值缓存容量指标。
- server_name=matrix.localhost；public_baseurl=https://liuhetong888.com/；媒体目录/data/media_store；storage_provider_count=0；Synapse配置max_upload_size=50M。这个上限不代表每种业务或客户端都允许50M。
- enable_authenticated_media字段缺省（null）不能推断实际媒体API免鉴权。
- TURN共用liuhetong888.com，3478 UDP/TCP、5349 TLS；relay端口49160–49200。端口数不等于通话数。
- 公网443为Caddy，Nginx按路径分发业务API和Synapse/sync；sync关闭buffering、read timeout600s。
- 服务器解析liuhetong888.com到207.56.8.8。服务器自身HTTPS请求Matrix versions为200、TTFB约109ms；不代表大陆或东南亚路径。
- 初次猜测/api/health、/health/ready、/api/health/ready均404；读取路由后确认/api/v1/health/ready返回JSON ok=true、database=ready，curl fail模式exit0。错误路径不构成服务故障。
- 5秒net1样本RX69802/TX92831字节，仅说明采样时流量，不代表高峰、套餐上限或丢包率。docker NetIO累计值未当作带宽。

现场配置记录：`docs/verification/artifacts/2026-09-24/regional-network-assessment/production-readonly.txt`（原主工作树的忽略归档，不随 Git 交付）。路径探测记录：`docs/verification/artifacts/2026-09-24/regional-network-assessment/health-readonly.txt`（原主工作树的忽略归档，不随 Git 交付）。硬件与容器采样、最终正确健康JSON另见本任务工具输出，未伪称全部存在这两个原始文件中。

## 推荐

1. 保留香港统一聊天/业务核心与同区域数据库、Redis；保留Matrix逻辑身份。广州仅试点HTTPS消息入口，直连香港作为经过验证的备选路径；广州到香港路径未通过实际晚高峰测试前不全量切流。不能跨广州/香港/新加坡部署依赖频繁远程SQL/Redis的worker。
2. 香港5Mbps是潜在明显容量约束，不是本次已测得饱和。20MB文件理论独占传输32秒；100人各取一次是2GB，5Mbps下总出口至少约53分钟。先拆文件流量，核心可按20–50Mbps持续可用出口作首轮测试预算，不称该值为已验证千人容量。
3. 私有S3保存客户端加密的媒体，CloudFront受控分发；新上传应适配客户端加密直传与服务端提交校验，避免经香港5Mbps或广州10Mbps出口转存。保留mxc、访问/删除、媒体完整性语义。仅安装Synapse存储provider不等于完成直传或CDN下载。
4. S3香港桶作为初始候选，与新加坡桶对比真实上传。新加坡支持Transfer Acceleration，香港不在当前官方支持列表；不能据此预断新加坡更快。大文件分片重试、完成确认、孤儿上传清理需配套开发。
5. 大陆与东南亚先分别测CloudFront。大陆效果不达标时，评估符合接入条件的大陆CDN及可交付的跨境回源/上传加速服务。大陆缓存未命中、消息、上传仍有跨境链路；广州普通VPS和自建隧道不会自动获得优质跨境带宽。不可通过广州10Mbps代理全部媒体。
6. 新加坡应用入口不是必买；东南亚直连香港达到目标时省掉这一跳。若实时音视频较多，独立新加坡/香港TURN更有明确用途，按实际relay吞吐定容，不经过CloudFront。发送视频文件不需要TURN。
7. 多入口不等于核心容灾。备份/恢复与主备切换单独建设，防双写；核心故障不能自动让广州离线收单、独立写账本或另建同身份homeserver。

## 未验证与下一步

没有广州服务器登录信息或东南亚真实客户端探针，未连接广州、未新建新加坡节点；没有三网晚高峰和千人混合负载数据，没有测量公网5Mbps是否饱和。下一步对大陆三网直连香港、经广州到香港、东南亚直连香港进行真实HTTPS/消息P95/P99、成功率对比，另测媒体上传/冷缓存/热缓存，不以ping替代应用验收。生产变更需另行实施计划与授权。

## 官方依据

- [CloudFront中国交付与跨境边界](https://aws.amazon.com/cn/developer/application-security-performance/articles/content-delivery-in-china/)
- [S3 Transfer Acceleration支持区域](https://docs.aws.amazon.com/AmazonS3/latest/userguide/transfer-acceleration.html)
- [AWS GA终端类型](https://docs.aws.amazon.com/global-accelerator/latest/dg/introduction-how-it-works.html)
- [Synapse复制机制](https://element-hq.github.io/synapse/latest/replication.html)
- [CloudFront签名URL](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-signed-urls.html)
