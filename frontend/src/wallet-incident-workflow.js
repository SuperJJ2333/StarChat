// This workflow never changes fund controls. Every transition uses the public API.
const REASONS={ack:'OWNER_INCIDENT_ACCEPTED',review:'OWNER_INCIDENT_CHECKED',resolve:'OWNER_INCIDENT_RESOLVED'};
const STEPS=['ack','review','resolve'];
const STEP_LABEL={ack:'确认接手事故',review:'实时核验当前证据',resolve:'结案并保留资金暂停'};
const reasonText={
  ALERT_DELIVERY_UNHEALTHY:'告警送达异常；请检查告警通道并确认通知能够送达',
  LEDGER_INTEGRITY:'账本完整性检查未通过；请联系财务或技术人员核对账本',
  MANUAL_CONTROL_ALERTS_NOT_CONFIGURED:'未配置恢复所需的告警通道；请先完成告警配置并验证送达',
  MANUAL_CONTROL_MISSING:'资金控制记录缺失；请联系技术人员检查钱包配置',
  MANUAL_COVERAGE_BACKLOG:'业务流水积压；请检查扫描服务并等待追平',
  MANUAL_COVERAGE_CONFLICT:'业务流水与链上检查记录不一致；请核查扫描和覆盖记录',
  MANUAL_COVERAGE_GAP:'业务流水扫描存在缺口；请检查扫描服务并补齐遗漏区间',
  MANUAL_MONITOR_UNAVAILABLE:'监控服务暂不可用；请检查服务运行状态后重试',
  MANUAL_PAYOUT_PENDING_MISMATCH:'待处理出款与冻结记录不一致；请核对出款订单和账本',
  MANUAL_PAYOUT_PENDING:'仍有待处理出款；请先核清相关出款订单',
  MANUAL_PAYOUT_UNCERTAIN:'出款结果尚未核清；请核对链上交易与原出款订单',
  MANUAL_RECEIPT_OBLIGATION_MISSING:'入款缺少对应的账务记录；请核对入款和账本',
  MANUAL_RESERVE_DEFICIT:'可用储备不足；请核对官方钱包余额与待履行金额',
  MANUAL_RESERVE_OVERFLOW:'储备金额超出允许范围；请联系技术人员核对数据',
  MANUAL_SETTLEMENT_AHEAD_OF_CUT:'结算记录晚于当前链上检查范围；请等待监控追平',
  MANUAL_SOURCE_INVALID:'链上数据格式或配置无效；请检查数据源配置',
  MANUAL_SOURCE_UNAVAILABLE:'链上数据暂不可用；请检查数据源连接后重试',
  MANUAL_TRANSACTION_TOO_LARGE:'链上交易金额超出处理范围；请核查该交易和金额配置',
  MANUAL_UNALLOCATED_OUTFLOW:'发现尚未对应出款订单的链上支出；请核清官方钱包支出',
  MANUAL_WALLET_PAUSED:'钱包处于保护性暂停；请先处理其他阻断原因，再单独核验恢复',
  WALLET_MONITOR_EVIDENCE_EXPIRED:'监控证据已过期；请检查扫描服务并等待新证据',
  MANUAL_COVERAGE_PENDING:'等待业务流水同步；请稍后刷新，扫描追平后再检查',
  MANUAL_SOURCE_PENDING:'链上监控正在等待稳定结果；请稍后刷新',
  MANUAL_SOURCE_UNHEALTHY:'链上数据源检查未通过；请检查数据源服务后重新核验',
  MANUAL_RESERVE_STALE:'储备证据已过期；请等待监控刷新储备证据',
  MANUAL_SOURCE_CHANGED:'链上快照刚发生变化；请刷新后重新检查',
  MANUAL_RESERVE_CHANGED:'储备记录刚发生变化；请刷新后重新检查',
  MONITOR_SCAN_BUSY:'监控正在核验；请稍后重新检查',
  MANUAL_BACKING_DEFICIT:'储备未覆盖账面负债；请核对储备与账目',
  SOURCE_RUN_ERROR:'链上数据源检查未通过；请检查数据源服务',
  BALANCE_UNSTABLE:'链上余额尚未稳定；请等待下一轮检查',
  RECONCILIATION_PENDING:'链上对账尚未完成；请等待下一轮检查',
  BALANCE_DISCREPANCY:'链上余额与对账记录不一致；请核对链上交易与账目',
};
export function incidentError(error) {
  if(error?.code==='WALLET_MONITOR_UNAVAILABLE') {
    const fields=Array.isArray(error.fields)?error.fields:[];
    const reasons=[...new Set(fields.filter(x=>x?.type==='wallet.monitor.reason').map(x=>reasonText[x.msg]).filter(x=>typeof x==='string'))];
    return `${reasons.join('；')||'本轮检查未完成，请刷新当前诊断后再检查'}。事故处理已停止，本流程不会恢复资金。`;
  }
  const known={
    WALLET_INCIDENT_VERSION_CONFLICT:'事故状态持续更新，本次提交未执行。请刷新后重新检查。',
    WALLET_INCIDENT_CONDITION_ACTIVE:'异常仍存在，请按当前诊断处理后重新检查。',
    RECENT_LOGIN_REQUIRED:'请重新登录，刷新事故状态后继续处理。',
    OPERATION_PASSWORD_INVALID:'操作密码不正确，请重新输入。',
    MFA_INVALID:'验证码未通过验证，请使用下一组验证码。',
    INCIDENT_STATE_INVALID:'事故状态无法核实，请刷新后再处理。',
    INCIDENT_WORKFLOW_STOPPED:'处理已停止，请刷新事故状态后继续。',
  };
  return known[error?.code]??'事故操作结果尚未确认，请先刷新服务端状态；再次检查时会沿用该步骤的原请求编号，核实后再继续。';
}
export function fundControlError(error) {
  const explanation={
    MANUAL_CONTROL_OTHER_SAFETY_RESTRICTION:'存在其他风控限制；请由对应风控流程解除后再核验',
    MANUAL_CONTROL_PAUSE_SOURCE_UNKNOWN:'暂停来源不明；请联系技术人员核实限制来源',
    MANUAL_CONTROL_SAFETY_SOURCE_UNKNOWN:'安全限制来源不明；请联系技术人员核实限制来源',
    MANUAL_CONTROL_UNRESOLVED_PAYOUT:'仍有未核清的出款；请先核对原订单与链上交易',
    WALLET_UNRESOLVED_INCIDENTS:'仍有阻断事故；请逐起检查并处理事故后再恢复',
    RECENT_LOGIN_REQUIRED:'请重新登录，刷新资金状态后继续',
  }[error?.code];
  return explanation?`${explanation}。本次未恢复资金。`:'资金操作结果尚未确认，请先刷新资金状态；重试会沿用原参数和请求编号。';
}
export function incidentSummary(item, policy) {
  const advisory=policy==='manual_liquidity'&&item.code==='MANUAL_BACKING_DEFICIT'&&item.severity==='P1'
    &&item.subject_id==='global'&&item.fingerprint==='manual-liquidity:backing-deficit';
  const titles={MANUAL_SOURCE_UNHEALTHY:'链上数据源曾出现异常',MANUAL_RESERVE_STALE:'储备证据曾过期',MANUAL_BACKING_DEFICIT:'储备覆盖提醒',MANUAL_COVERAGE_PENDING:'业务流水同步未完成'};
  const explanations={
    MANUAL_SOURCE_UNHEALTHY:'当时链上数据未满足健康要求，可能是结果过期或对账未完成，系统因此保护性暂停；具体历史触发条件以记录为准。',
    MANUAL_RESERVE_STALE:'当时用于核验钱包储备的证据已过期，无法据此确认可用资金，需要取得新的证据再核验。',
    MANUAL_BACKING_DEFICIT:'当时核验的储备未覆盖账面负债。这是一项储备覆盖记录，是否阻止恢复取决于当前资金策略；请核对储备与账目。',
    MANUAL_COVERAGE_PENDING:'当时业务流水扫描尚未追平链上记录，两边还不能在同一检查范围内完成核对。',
    MANUAL_SOURCE_UNAVAILABLE:'当时无法取得可用的链上数据，系统无法完成检查；具体连接或服务故障应以历史记录为准。',
    MANUAL_SOURCE_PENDING:'当时链上检查还没有稳定结果，需要等待后续观测完成后再核验。',
    MANUAL_PAYOUT_UNCERTAIN:'当时至少一笔出款的链上结果尚未核清，需要核对原订单和对应交易，不能仅凭客户端显示判断结算。',
    MANUAL_UNALLOCATED_OUTFLOW:'当时发现官方钱包存在尚未对应到出款订单的链上支出，需要核对支出用途及业务记录。',
    LEDGER_INTEGRITY:'当时账本完整性检查未通过，需要核查账务记录与平衡关系，不能直接跳过这项检查。',
    ALERT_DELIVERY_UNHEALTHY:'当时外部告警未满足送达要求，重要异常可能无法及时通知处理人员，需要核查告警通道。',
  };
  const explanation=explanations[item.code]??(typeof reasonText[item.code]==='string'?`这起记录表示相关检查曾未通过。${reasonText[item.code]}。具体历史触发条件以记录为准。`:'这是一条钱包安全检查未通过的历史记录。详细原因未记录时，不能推断具体故障；请结合当前诊断进行检查。');
  return {advisory,title:titles[item.code]??'钱包监控异常记录',
    explanation,
    status:{OPEN:'待处理',ACKNOWLEDGED:'已接手 · 待检查或结案',RESOLVED:'已结案'}[item.status]??'状态待核实',
    impact:advisory?'提示记录，不阻止恢复资金':item.status==='RESOLVED'?'事故已结案，资金恢复仍需单独核验':'阻止恢复资金，需要检查并处理',
    condition:item.condition_active===false?'最近记录显示异常已消失；仍需实时核验':item.condition_active===true?'这起事故尚未通过异常消除复核；请检查并处理事故':'当前异常状态尚未核实',
  };
}
export function incidentTime(value) {
  const time=Date.parse(value);return Number.isFinite(time)?new Date(time).toLocaleString('zh-CN',{timeZone:'Asia/Hong_Kong',hour12:false})+'（香港时间）':'暂无记录';
}
export function diagnosticSummary(value) {
  if(!value)return '当前诊断暂不可用，请刷新重试。';
  const source={HEALTHY:'链上数据正常',WAITING:'链上数据等待稳定',UNAVAILABLE:'链上数据暂不可用',UNHEALTHY:'链上数据异常'}[value.source_status]??'链上数据尚未核实';
  const coverage={CURRENT:'业务流水已同步',WAITING:'等待业务流水同步',UNAVAILABLE:'业务流水进度暂不可用',CONFLICT:'业务流水与链上检查不一致，请核查扫描服务'}[value.coverage_status]??'业务流水进度尚未核实';
  return `${source}；${coverage}。此诊断仅供检查，资金恢复仍需独立核验。`;
}
function valid(item,id) {
  if(item?.id!==id||!Number.isSafeInteger(item.version)||item.version<1||!['OPEN','ACKNOWLEDGED','RESOLVED'].includes(item.status)||typeof item.condition_active!=='boolean')
    throw {code:'INCIDENT_STATE_INVALID'};
  return item;
}
function nextStep(item) {
  if(item.status==='RESOLVED')return null;
  if(item.status==='OPEN')return 'ack';
  return !item.condition_active&&/^[a-f0-9]{64}$/.test(item.clearance_digest)?'resolve':'review';
}
export async function processIncident({id,api,journal,credentials,authMode,onProgress=()=>{},shouldStop=()=>false}) {
  const slot=kind=>`incident:${id}:process:${kind}`;
  let conflicts=0;
  try {
    for(let count=0;count<6;count++) {
      if(shouldStop())throw {code:'INCIDENT_WORKFLOW_STOPPED'};
      const current=valid(await api.getWalletIncident(id),id);
      if(shouldStop())throw {code:'INCIDENT_WORKFLOW_STOPPED'};
      // Inspect pending steps before deriving a new action, including after reload.
      const legacySlot=step=>`incident:${id}:${step}:${current.version}`;
      const kind=STEPS.find(step=>journal.pending(slot(step))||journal.pending(legacySlot(step)))??nextStep(current);
      if(!kind)return {status:'resolved',item:current};
      const operation=journal.pending(slot(kind))?slot(kind):journal.pending(legacySlot(kind))?legacySlot(kind):slot(kind), saved=journal.pending(operation);
      const metadata=saved?.metadata??{expected_version:current.version,reason_code:REASONS[kind],...(kind==='resolve'?{clearance_digest:current.clearance_digest}:{})};
      const entry=journal.begin(operation,metadata);
      onProgress(`${STEP_LABEL[kind]}…${saved?'正在核实上次请求。':''}`);
      let result;
      try {
        result=valid(await api.manualWalletIncidentAction(id,kind,{...metadata,...credentials},{idempotencyKey:entry.key}),id);
      } catch(error) {
        if(error?.code!=='WALLET_INCIDENT_VERSION_CONFLICT')throw error;
        journal.finish(operation);conflicts++;
        onProgress('事故状态已更新，原提交未执行，正在刷新。');
        if(conflicts>2)throw error;
        if(authMode!=='operation_password')return {status:'needs_credential',conflict:true};
        continue;
      }
      journal.finish(operation);
      if(kind==='resolve'&&result.status==='RESOLVED')return {status:'resolved',item:result};
      if(kind==='review'&&(result.condition_active||!result.clearance_digest))return {status:'blocked',item:result};
      if(authMode!=='operation_password')return {status:'needs_credential',item:result};
    }
    throw {code:'INCIDENT_WORKFLOW_STOPPED'};
  } finally {
    for(const key of Object.keys(credentials))delete credentials[key];
  }
}
