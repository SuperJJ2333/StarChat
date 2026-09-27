# 无用户信息的请求失败诊断与服务端关联

## 授权及目标

用户在前一回复中接受“补充不含用户信息的错误细分类及请求阶段，再关联服务器时间线定位”。本设计落地该方向，沿用已有鉴权、8秒默认请求预算、重试、诊断上传频率和16KiB上限。源码/测试/只读服务器调查已授权；新的服务候选需完成后按服务发布流程单独交付。本任务不发布正式移动版本、不改Matrix/E2EE或金融状态。

现2184安全摘要只能确认58次超时/15次粗分类异常，缺少请求标识和阶段；新字段不能补造过去的缺失证据。既有历史时间线有保留缺口时报告未知，不推断手机断网。本文及后续计划是用户接受方向的细化，不重复索取已给出的代码实施授权。

## 选择

采用闭合、可选的每请求失败记录与随机请求头，保留既有聚合。仅增加错误总数无法定位阶段；替换HTTP传输或主动重做DNS会改变网络行为，故沿用当前传输，只观察其公开边界。新字段遇旧接收端422时分层禁用，继续原有events/frames/networks。

## 客户端字段及边界

每次实际请求独立UUIDv4，通过X-ChatFlow-Request-Id发送；401刷新重试使用新ID。原X-ChatFlow-Performance-Id仍关联父操作，X-Trace-Id审计域保持独立。只对当前业务API源启用，只在诊断会话活动时收集，上传诊断自身排除。所有原始URL、host、query、path、headers、exception文本/堆栈、账号/设备持久标识、请求/响应正文禁止进入记录。

可选network_requests列表每批最多8条，计入既有16KiB及20个事件/操作总记录预算。独立等待队列最多64条，满时丢弃新项并记录固定丢弃计数；重试保留原request_id，成功202才确认。同账号范围spool保留，换账号/登出/迟到callback按现generation隔离。

固定记录键：request_id、version、platform、target=primary_api、network、method、endpoint_category、started_at、elapsed_ms、phase、reason；可选operation_id、headers_ms、http_status、timeout_budget_ms、timeout_lateness_ms。UUID须为v4，UTC采用既有闭合语法，所有耗时整数0..3600000，budget1..3600000、http_status100..599。headers_ms不得超过elapsed_ms，超时附加字段仅reason=timeout可用。

phase：awaiting_headers / reading_body / response_complete / unknown。reason：timeout / socket / tls / http_transport / aborted / unexpected / http_5xx。method：GET / POST / PUT / PATCH / DELETE / HEAD / OPTIONS / OTHER。endpoint_category：auth / profile / contacts / media / finance / settings / support / other；从固定规则映射，输出仅枚举，禁止自由文本。

收到响应头前是awaiting_headers；收到头后及读取响应期间为reading_body；读完5xx可为response_complete。共享HTTP接口不能准确划分DNS/TCP/首字节，不伪造这些阶段。SocketException、HandshakeException、HttpException/http.ClientException、RequestAbortedException、未知异常分别转闭合类别；不解析异常文字。Future.timeout记录实际预算及回调超出预算的单调时钟时间，不能称其全部是主线程卡顿。迟到响应不重复计数，不取消原HTTP或增加重试。

## 服务端契约及时间线

既有认证/client-diagnostics入口增加可选network_requests，旧请求仍合法；严格extra=forbid、长度/总预算/重复ID/类型/时序校验。原服务端限流、鉴权和安全错误保持，禁止新增未登录接收入口。

tracing middleware只接受UUIDv4请求头。对于有效头生成闭合终态时间线：request_id、server UTC起点、单调耗时、固定method/endpoint_category、已验证静态route template、响应头/末块准备/最后ASGI send返回时刻及complete/cancelled/exception终态，实际收到响应头前不伪填500。send返回只代表ASGI下游接受，不证明手机收到数据。保持DBscope后台隔离和既有performance视图。

日志输出必须使用有界非阻塞队列和全局限额，并保留固定drop计数/覆盖说明，不在请求路径同步等待stdout、不记录任意异常或audit/session上下文。无有效头时维持原行为；请求ID不授予权限。重启/队列丢弃/日志留存缺口都使关联覆盖不完整。

## 采集与归因

原始服务器日志留在服务器。闭合collector验证并仅导出上述客户端/服务端记录与采集覆盖元数据；精确按request_id关联，不靠客户端墙钟做跨主机耗时。输出服务端完成/处理超预算/取消或异常/只有客户端/只有服务端/覆盖不足，各自保留unknown。没有API记录不能证明DNS或断网。

## 验证及交付

先失败用例，再覆盖headers/body timeout、具体异常、迟到响应、401实际重放ID、上限、非法/私有字段、spool/422兼容、generation隔离、ASGI流式/取消/send异常、队列满及collector关联。先规格后安全，执行适用focused/analyze及一次完整verify；输入未变不重复门禁。服务候选基于当时live保留PHONE/S3/诊断，不夹带未批准startup route。新客户端只有随新Debug/正式包实际安装后才产生字段，旧73条不能追溯补填；iOS原生/分发按环境单列。
