export const fixtures = Object.freeze({
  currentUser: Object.freeze({
    name: "林晓",
    username: "linxiao",
    email: "l***@demo.invalid",
    signature: "保持好奇，也保持联系。"
  }),
  contacts: Object.freeze([
    Object.freeze({ name: "周然", username: "zhouran", initial: "周", subtitle: "刚刚在线" }),
    Object.freeze({ name: "陈默", username: "chenmo", initial: "陈", subtitle: "端到端加密会话" }),
    Object.freeze({ name: "畅聊客服 008", username: "support008", initial: "客", subtitle: "官方客服 · 已认证" })
  ]),
  conversations: Object.freeze([
    Object.freeze({ name: "周然", preview: "好，明天见。", time: "09:41", unread: "2" }),
    Object.freeze({ name: "周末徒步群", preview: "陈默：[图片]", time: "08:12", unread: "18" }),
    Object.freeze({ name: "畅聊客服 008", preview: "您的工单正在处理中", time: "昨天", unread: "" })
  ]),
  messages: Object.freeze([
    Object.freeze({ direction: "incoming", sender: "周然", content: "明天上午九点，地铁口见。", delivery: "sent" }),
    Object.freeze({ direction: "outgoing", sender: "我", content: "好，收到。路上保持联系。", delivery: "sent" })
  ]),
  moment: Object.freeze({
    author: "周然",
    content: "天气很好，沿着海边走了很久。",
    location: "海滨步道",
    time: "12 分钟前"
  }),
  finance: Object.freeze({
    caibiBalance: "1288.50",
    caibiTransferAmount: "88.00",
    caibiFee: "0.44",
    usdtBalance: "320.125000",
    usdtWithdrawalAmount: "20.000000",
    usdtFee: "1.000000",
    walletAddress: "TTest...8Demo",
    walletAddressFull: "TTestAddressForDesignReviewOnly8Demo",
    prohibitedFeatures: Object.freeze([])
  })
});
