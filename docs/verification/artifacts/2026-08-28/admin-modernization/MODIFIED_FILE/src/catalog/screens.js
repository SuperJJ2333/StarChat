const definitions = [];

const rendererFiles = Object.freeze({
  foundation: "feedback",
  auth: "auth",
  messages: "messaging",
  chat: "messaging",
  calls: "calls",
  contacts: "contacts",
  friend: "contacts",
  discovery: "moments",
  moments: "moments",
  profile: "profile",
  caibi: "finance",
  redpacket: "finance",
  wallet: "finance",
  feedback: "feedback"
});

function semanticTags(state) {
  const tags = ["screen"];
  if (/loading|syncing|uploading|processing|submitting|allocating|confirming|broadcast/u.test(state)) tags.push("loading");
  if (/empty|no-result/u.test(state)) tags.push("empty");
  if (/error|failed|invalid|insufficient|denied|expired|removed|unavailable|busy|no-answer|disconnected|unknown/u.test(state)) tags.push("error");
  if (/offline|reconnecting|restored|weak-network/u.test(state)) tags.push("network");
  if (/success|completed|credited|confirmed|published|sent|added/u.test(state)) tags.push("success");
  if (/confirm|sheet|dialog|menu/u.test(state)) tags.push("overlay");
  return tags;
}

function register(module, page, states, options = {}) {
  for (const item of states) {
    const [state, title, customHeight] = item;
    const definition = {
      id: `${module}-${page}-${state}`,
      module,
      page,
      state,
      theme: "light",
      title,
      width: 393,
      height: customHeight ?? options.height ?? 852,
      tags: Object.freeze([...semanticTags(state), module, page]),
      component: null
    };
    definition.component = async () => {
      const renderer = await import(`../screens/${rendererFiles[module]}.js`);
      return renderer.renderScreen(definition);
    };
    definitions.push(Object.freeze(definition));
  }
}

register("foundation", "tokens", [
  ["overview", "Foundations / 语义 Token / 浅色", 1180]
]);
register("foundation", "components", [
  ["catalog", "Components / 完整组件库 / 浅色", 2400]
]);
register("foundation", "icons", [
  ["catalog", "Icons / 完整图标库 / 浅色", 1440]
]);

register("auth", "login", [
  ["default", "登录 / 默认"], ["filled", "登录 / 已填写"], ["submitting", "登录 / 提交中"],
  ["error-required", "登录 / 字段缺失"], ["error-credentials", "登录 / 凭证错误"], ["error-network", "登录 / 网络错误"]
]);
register("auth", "registration", [
  ["default", "注册 / 默认"], ["invitation-required", "注册 / 邀请码缺失"], ["field-errors", "注册 / 字段错误"],
  ["submitting", "注册 / 提交中"], ["failed", "注册 / 失败"], ["completed", "注册 / 完成"]
]);
register("auth", "verification", [
  ["code", "邮箱验证 / 验证码"], ["link", "邮箱验证 / 验证链接"], ["countdown", "邮箱验证 / 倒计时"],
  ["resend-ready", "邮箱验证 / 可重发"], ["verifying", "邮箱验证 / 验证中"], ["success", "邮箱验证 / 成功"],
  ["code-error", "邮箱验证 / 验证码错误"], ["expired", "邮箱验证 / 已过期"], ["resend-failed", "邮箱验证 / 重发失败"]
]);
register("auth", "layout", [["keyboard", "认证 / 键盘布局"], ["reduced-motion", "认证 / 减少动态效果"]]);

register("messages", "inbox", [
  ["default", "消息 / 默认"], ["syncing", "消息 / 同步中"], ["empty", "消息 / 空状态"],
  ["offline", "消息 / 离线"], ["reconnecting", "消息 / 重连中"], ["sync-failed", "消息 / 同步失败"]
]);
register("messages", "conversation", [
  ["direct", "会话单元 / 单聊"], ["group", "会话单元 / 群聊"], ["support", "会话单元 / 官方客服"],
  ["muted", "会话单元 / 静音"], ["pinned", "会话单元 / 置顶"], ["unread-one", "会话单元 / 未读 1"], ["unread-max", "会话单元 / 未读 99+"]
]);
register("messages", "network", [["offline", "网络胶囊 / 离线"], ["reconnecting", "网络胶囊 / 重连"], ["restored", "网络胶囊 / 已恢复"]]);
register("messages", "new", [["conversation-sheet", "消息 / 新建会话面板"]]);

register("chat", "room", [
  ["mixed", "聊天 / 混合消息"], ["text", "聊天 / 文本消息"], ["continuous", "聊天 / 连续消息"],
  ["cross-day", "聊天 / 跨日时间戳"], ["reply", "聊天 / 回复"], ["redacted", "聊天 / 撤回提示"],
  ["message-sending", "聊天 / 消息发送中"], ["message-sent", "聊天 / 消息已发送"],
  ["message-failed", "聊天 / 消息发送失败"], ["message-retry", "聊天 / 点击重试"],
  ["empty", "聊天 / 空会话"], ["history-loading", "聊天 / 历史加载"], ["history-failed", "聊天 / 历史加载失败"]
]);
register("chat", "composer", [["text", "输入区 / 文本"], ["attachment", "输入区 / 附件"], ["voice", "输入区 / 语音"], ["keyboard", "输入区 / 键盘"]]);
register("chat", "voice", [
  ["recording", "语音 / 录制"], ["slide-cancel", "语音 / 上滑取消"], ["cancel-zone", "语音 / 取消区"],
  ["too-short", "语音 / 不足 1 秒"], ["limit", "语音 / 60 秒上限"], ["preview", "语音 / 本地试听"],
  ["delete-confirm", "语音 / 删除确认"], ["sending", "语音 / 发送"]
]);
register("chat", "attachment", [
  ["image-picker", "附件 / 选择图片"], ["file-picker", "附件 / 选择文件"], ["permission-denied", "附件 / 权限拒绝"],
  ["unsupported", "附件 / 格式不支持"], ["oversize", "附件 / 超过大小"], ["uploading", "附件 / 上传中"],
  ["upload-failed", "附件 / 上传失败"], ["retry", "附件 / 保留并重试"], ["sent", "附件 / 发送完成"]
]);
register("chat", "redpacket", [
  ["available", "红包消息 / 可领取"], ["claimed", "红包消息 / 已领取"], ["exhausted", "红包消息 / 已领完"],
  ["expired", "红包消息 / 已过期"], ["withdrawn", "红包消息 / 已撤回"]
]);
register("chat", "details", [["members", "聊天详情 / 成员入口"]]);

register("calls", "audio", [["calling", "语音通话 / 呼叫中"], ["incoming", "语音通话 / 来电"], ["connected", "语音通话 / 已连接"], ["weak-network", "语音通话 / 弱网"], ["ended", "语音通话 / 结束"]]);
register("calls", "video", [["calling", "视频通话 / 呼叫中"], ["incoming", "视频通话 / 来电"], ["connected", "视频通话 / 已连接"], ["camera-off", "视频通话 / 摄像头关闭"], ["microphone-off", "视频通话 / 麦克风关闭"], ["camera-switch", "视频通话 / 镜头切换"], ["permission-denied", "视频通话 / 权限拒绝"]]);
register("calls", "permission", [["request", "通话 / 权限请求"], ["denied", "通话 / 权限拒绝"], ["settings", "通话 / 系统设置入口"]]);
register("calls", "result", [["busy", "通话 / 对方忙线"], ["no-answer", "通话 / 无人接听"], ["connection-failed", "通话 / 连接失败"], ["disconnected", "通话 / 网络中断"], ["reconnecting", "通话 / 正在恢复"]]);

register("contacts", "index", [["default", "通讯录 / 默认"], ["grouped", "通讯录 / 拼音分组"], ["overlay", "通讯录 / 字母索引浮层"]], { height: 1040 });
register("contacts", "friends", [["default", "新的朋友 / 列表"], ["empty", "新的朋友 / 空"], ["loading-failed", "新的朋友 / 加载失败"]]);
register("contacts", "request", [["pending", "好友申请 / 待处理"], ["accepting", "好友申请 / 接受中"], ["rejected", "好友申请 / 已拒绝"], ["added", "好友申请 / 已添加"], ["failed", "好友申请 / 操作失败"]]);
register("contacts", "groups", [["default", "群聊 / 列表"], ["empty", "群聊 / 空"]]);
register("contacts", "tags", [["default", "标签 / 列表"], ["empty", "标签 / 空"]]);
register("contacts", "official", [["default", "公众号与官方客服 / 列表"], ["empty", "公众号与官方客服 / 空"]]);
register("contacts", "search", [["default", "通讯录搜索 / 默认"], ["results", "通讯录搜索 / 结果"], ["no-result", "通讯录搜索 / 无结果"]]);
register("contacts", "state", [["loading", "通讯录 / 加载"], ["empty", "通讯录 / 空状态"], ["error-network", "通讯录 / 网络错误"]]);

register("friend", "profile", [["default", "好友主页 / 默认"], ["support", "好友主页 / 官方客服"]], { height: 980 });
register("friend", "message", [["creating", "好友主页 / 创建会话"], ["failed", "好友主页 / 创建失败"]]);
register("friend", "more", [["default", "好友更多 / 默认"]]);
register("friend", "remark", [["edit", "好友更多 / 编辑备注"], ["saved", "好友更多 / 备注已保存"]]);
register("friend", "tags", [["select", "好友更多 / 选择标签"], ["create", "好友更多 / 新建标签"]]);
register("friend", "privacy", [["sheet", "好友更多 / 朋友圈权限"]]);
register("friend", "blacklist", [["add-confirm", "好友更多 / 加入黑名单确认"], ["added", "好友更多 / 已加入黑名单"], ["remove", "好友更多 / 移出黑名单"]]);
register("friend", "delete", [["confirm", "好友更多 / 删除确认"], ["success", "好友更多 / 删除成功"], ["failed", "好友更多 / 删除失败"]]);

register("discovery", "home", [["default", "发现 / 默认"], ["moments-new", "发现 / 朋友圈有新内容"], ["recommended", "发现 / 推荐入口"], ["loading", "发现 / 加载"], ["error-network", "发现 / 网络异常"]]);

register("moments", "timeline", [["default", "朋友圈 / 时间线"], ["loading", "朋友圈 / 加载"], ["empty", "朋友圈 / 空"], ["refresh-failed", "朋友圈 / 刷新失败"], ["pagination-failed", "朋友圈 / 分页失败"]], { height: 1280 });
register("moments", "media", [["text", "朋友圈动态 / 纯文字"], ["single", "朋友圈动态 / 单图"], ["two", "朋友圈动态 / 双图"], ["four", "朋友圈动态 / 四图"], ["nine", "朋友圈动态 / 九图"]], { height: 980 });
register("moments", "actions", [["menu", "朋友圈 / 操作菜单"], ["liked", "朋友圈 / 已点赞"], ["comment", "朋友圈 / 评论输入"]]);
register("moments", "visibility", [["public", "朋友圈 / 公开"], ["friends", "朋友圈 / 好友"], ["partial", "朋友圈 / 部分可见"], ["excluded", "朋友圈 / 不给谁看"], ["private", "朋友圈 / 仅自己"]]);
register("moments", "governance", [["uploading", "朋友圈 / 上传中"], ["reviewing", "朋友圈 / 审核中"], ["published", "朋友圈 / 已发布"], ["limited", "朋友圈 / 部分可见"], ["removed", "朋友圈 / 已下架"], ["failed", "朋友圈 / 发布失败"]]);
register("moments", "recommendation", [["recommended", "公开时间线 / 推荐"], ["latest", "公开时间线 / 最新"], ["personalization-off", "公开时间线 / 关闭个性化"]]);
register("moments", "composer", [["text", "发布朋友圈 / 纯文字"], ["images", "发布朋友圈 / 图片"], ["location", "发布朋友圈 / 位置"], ["mention", "发布朋友圈 / 提醒谁看"], ["visibility", "发布朋友圈 / 可见范围"], ["disabled", "发布朋友圈 / 发布禁用"], ["uploading", "发布朋友圈 / 上传中"], ["upload-failed", "发布朋友圈 / 上传失败"]], { height: 980 });
register("moments", "composer-sheet", [["leave-confirm", "发布朋友圈 / 离开确认"], ["location", "发布朋友圈 / 位置面板"], ["mention", "发布朋友圈 / 提醒好友面板"], ["visibility", "发布朋友圈 / 可见范围面板"]]);
register("moments", "detail", [["default", "动态详情 / 默认", 1180], ["comment-reply", "动态详情 / 回复评论", 1180], ["comment-delete", "动态详情 / 删除评论确认", 1180]]);
register("moments", "search", [["default", "朋友圈搜索 / 默认"], ["results", "朋友圈搜索 / 结果"], ["filters", "朋友圈搜索 / 筛选"], ["no-result", "朋友圈搜索 / 无结果"], ["permission-filtered", "朋友圈搜索 / 无权限过滤"]]);
register("moments", "notifications", [["default", "朋友圈互动通知 / 列表"], ["empty", "朋友圈互动通知 / 空"]]);
register("moments", "settings", [["default", "朋友圈设置 / 默认"], ["strangers", "朋友圈设置 / 陌生人查看"], ["range", "朋友圈设置 / 时间范围"], ["exclude", "朋友圈设置 / 不让他看"], ["block", "朋友圈设置 / 屏蔽他的朋友圈"], ["personalization", "朋友圈设置 / 个性化推荐"]]);
register("moments", "settings", [["range-sheet", "朋友圈设置 / 时间范围面板"]]);

register("profile", "home", [["default", "我 / 默认"]]);
register("profile", "details", [["default", "个人资料 / 默认"], ["edit", "个人资料 / 编辑"]]);
register("profile", "avatar", [["picker", "头像 / 相册选择"], ["permission-denied", "头像 / 权限拒绝"], ["crop", "头像 / 裁剪"], ["preview", "头像 / 预览"], ["uploading", "头像 / 上传中"], ["upload-failed", "头像 / 上传失败"], ["restore-confirm", "头像 / 恢复默认确认"], ["fallback", "头像 / 加载失败回退"]]);
register("profile", "settings", [["default", "设置 / 默认"], ["privacy", "设置 / 账号与隐私"], ["logout-confirm", "设置 / 退出确认"], ["logout-loading", "设置 / 退出中"], ["logout-failed", "设置 / 退出失败"]]);

register("caibi", "home", [["default", "点钻 / 默认"]]);
register("caibi", "history", [["all", "点钻记录 / 全部"], ["credit", "点钻记录 / 上分"], ["debit", "点钻记录 / 下分"], ["transfer", "点钻记录 / 转账"], ["redpacket", "点钻记录 / 红包"]], { height: 980 });
register("caibi", "transfer", [["default", "点钻转账 / 默认"], ["amount", "点钻转账 / 金额"], ["fee", "点钻转账 / 手续费"], ["confirm", "点钻转账 / 确认"], ["processing", "点钻转账 / 处理中"], ["success", "点钻转账 / 成功"], ["recipient-invalid", "点钻转账 / 收款人不存在"], ["amount-invalid", "点钻转账 / 金额错误"], ["insufficient", "点钻转账 / 余额不足"], ["duplicate", "点钻转账 / 重复提交"], ["unknown-result", "点钻转账 / 未知结果"]]);
register("caibi", "transaction", [["detail", "点钻交易 / 详情"]]);

register("redpacket", "create", [["group-equal", "红包 / 群聊等额"], ["group-random", "红包 / 群聊拼手气"], ["direct-equal", "红包 / 私聊等额"], ["direct-random", "红包 / 私聊拼手气"], ["fields", "红包 / 输入字段"], ["amount-invalid", "红包 / 金额错误"], ["count-invalid", "红包 / 份数错误"], ["minimum-invalid", "红包 / 最低金额错误"], ["confirm", "红包 / 创建确认"], ["submitting", "红包 / 创建中"], ["failed", "红包 / 创建失败"], ["success", "红包 / 创建成功"]]);
register("redpacket", "detail", [["available", "红包详情 / 可领取"], ["claiming", "红包详情 / 领取中"], ["claimed", "红包详情 / 已领取"], ["exhausted", "红包详情 / 已领完"], ["expired", "红包详情 / 已过期"], ["withdrawn", "红包详情 / 已撤回"], ["duplicate", "红包详情 / 重复领取"], ["concurrent-exhausted", "红包详情 / 并发领完"], ["unknown-result", "红包详情 / 未知结果"], ["history", "红包详情 / 领取明细", 1040]]);

register("wallet", "home", [["default", "USDT 钱包 / 默认"]]);
register("wallet", "history", [["all", "钱包记录 / 全部"], ["deposit", "钱包记录 / 充值"], ["withdrawal", "钱包记录 / 提现"], ["empty", "钱包记录 / 空"]], { height: 980 });
register("wallet", "deposit", [["allocating", "充值地址 / 分配中"], ["address", "充值地址 / 已生成"], ["copied", "充值地址 / 已复制"], ["allocation-failed", "充值地址 / 分配失败"], ["below-minimum", "充值 / 低于最低金额"], ["detected", "充值 / 已检测"], ["confirming", "充值 / 确认中"], ["credited", "充值 / 已入账"], ["manual-review", "充值 / 人工复核"]]);
register("wallet", "withdrawal", [["default", "提现 / 默认"], ["input", "提现 / 输入"], ["fee", "提现 / 费用摘要"], ["confirm", "提现 / 确认"], ["address-invalid", "提现 / 地址错误"], ["amount-invalid", "提现 / 金额错误"], ["insufficient", "提现 / 余额不足"], ["reviewing", "提现 / 管理员处理中"], ["direct-execution", "提现 / 管理员直接执行"], ["provider-processing", "提现 / 托管处理中"], ["broadcast", "提现 / 链上广播"], ["confirmed", "提现 / 已确认"], ["failed-refunded", "提现 / 失败退款"], ["unknown-result", "提现 / 未知结果"], ["unavailable", "提现 / 钱包不可用"]]);
register("wallet", "transaction", [["summary", "钱包交易 / 摘要"], ["detail", "钱包交易 / 完整地址详情"]]);
register("wallet", "state", [["history-failed", "钱包 / 记录加载失败"], ["empty", "钱包 / 空记录"], ["service-error", "钱包 / 服务异常"]]);

register("feedback", "dialog", [["confirm", "Dialog / 确认"], ["error", "Dialog / 错误"], ["detail", "Dialog / 详情"], ["danger", "Dialog / 危险操作"]]);
register("feedback", "toast", [["success", "Toast / 成功"], ["warning", "Toast / 警告"], ["error", "Toast / 错误"], ["info", "Toast / 信息"]]);
register("feedback", "empty", [["default", "Empty State / 无数据"], ["permission", "Empty State / 无权限"], ["network", "Empty State / 网络错误"], ["retry", "Empty State / 重试"]]);
register("feedback", "loading", [["spinner", "加载 / 指示器"], ["skeleton", "加载 / 骨架"], ["disabled", "加载 / 禁用"]]);
register("feedback", "permission", [["settings", "权限 / 系统设置入口"]]);
register("feedback", "network", [["offline", "网络 / 断网"], ["reconnecting", "网络 / 重连"], ["unavailable", "网络 / 服务不可用"], ["timeout", "网络 / 超时"]]);
register("feedback", "motion", [["reduced", "动效 / 减少动态效果"]]);
register("feedback", "type-scale", [["085", "字号缩放 / 0.85"], ["100", "字号缩放 / 1.0"], ["140", "字号缩放 / 1.4"]]);

const darkKeys = [
  ["foundation-tokens-overview", "foundation-tokens-overview-dark"],
  ["foundation-components-catalog", "foundation-components-catalog-dark"],
  ["auth-login-default", "auth-login-default-dark"],
  ["messages-inbox-default", "messages-inbox-default-dark"],
  ["chat-room-mixed", "chat-room-mixed-dark"],
  ["contacts-index-default", "contacts-index-default-dark"],
  ["moments-timeline-default", "moments-timeline-default-dark"],
  ["profile-home-default", "profile-home-default-dark"],
  ["wallet-home-default", "wallet-home-default-dark"]
];

for (const [sourceId, darkId] of darkKeys) {
  const source = definitions.find((definition) => definition.id === sourceId);
  const dark = {
    ...source,
    id: darkId,
    theme: "dark",
    title: `${source.title} / 深色`,
    tags: Object.freeze([...source.tags, "dark"]),
    component: null
  };
  dark.component = async () => {
    const renderer = await import(`../screens/${rendererFiles[dark.module]}.js`);
    return renderer.renderScreen(dark);
  };
  definitions.push(Object.freeze(dark));
}

export const screens = Object.freeze(definitions);

export function getScreen(id) {
  const screen = screens.find((candidate) => candidate.id === id);
  if (!screen) throw new Error(`Unknown screen: ${id}`);
  return screen;
}
