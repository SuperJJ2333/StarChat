import {pageSizeControl,changePageSize} from './admin-pagination.js?v=20260930-admin-navigation';
import { formatBeijingTime, parseBeijingInput } from './admin-formatters.js';
import {detailDialog} from './admin-detail-dialog.js';
import {walletRepairDialog} from './admin-wallet-repair-dialog.js?v=20260928-admin-entry';
import {shortHash,shortChainValue,transferKey,validateChainReadView} from './admin-chain-view-state.js?v=20260930-admin-navigation';

function node(tag, text, className) {
  const result = document.createElement(tag);
  if (text !== undefined) result.textContent = String(text);
  if (className) result.className = className;
  return result;
}

function time(value) {
  const formatted = formatBeijingTime(value);
  return formatted === '—' ? '暂无' : formatted;
}

function accounting(record) {
  const link = record.platform_record;
  if (!link) return "尚未核定";
  const labels = { CREDITED: "已入账", REVIEW: "待处理", SETTLED: "提现已结算" };
  const status = labels[link.ledger_status] ?? "尚未核定";
  return link.evidence_status === "CONFLICT" ? `${status}；证据冲突，需核查` : status;
}

function directionLabel(record) {
  if (record.direction === "INFLOW") return "转入";
  if (record.platform_record?.kind === "PAYOUT")
    return record.platform_record.ledger_status === "SETTLED" ? "提现转出" : "提现待核定";
  return "未关联出款订单";
}

function normalizedAmount(value) {
  if (typeof value !== 'string' || !/^\d+\.\d{6}$/.test(value)) return null;
  const [whole,fraction]=value.split('.');
  const units=BigInt(whole)*1000000n+BigInt(fraction);
  return units>0n?`${units/1000000n}.${String(units%1000000n).padStart(6,'0')}`:null;
}

function observedOutflow(record,txid) {
  return record && typeof record.txid==='string' && record.txid.toLowerCase()===txid.toLowerCase() &&
    Number.isSafeInteger(record.log_index) && record.log_index>=0 &&
    record.direction==='UNMATCHED_OUTFLOW' && record.asset==='USDT' &&
    Number.isSafeInteger(record.timestamp_ms) && record.timestamp_ms>=0 &&
    normalizedAmount(record.amount)!==null &&
    typeof record.to_address==='string' && record.to_address.trim()!=='' &&
    record.platform_record?.evidence_status!=='CONFLICT' && record.platform_record?.kind!=='PAYOUT';
}

async function copyFull(value,status) {
  try {
    if (typeof globalThis.navigator?.clipboard?.writeText !== 'function') throw Error('clipboard unavailable');
    await globalThis.navigator.clipboard.writeText(value);
    status.textContent='复制成功。';
  } catch {
    status.textContent='复制失败，请检查浏览器剪贴板权限。';
  }
}

function appendField(list,label,value,{copyValue,copyLabel}={}) {
  const term=node('dt',label),definition=node('dd',value??'暂无');
  if (copyValue) {
    const action=node('button',copyLabel,'admin-secondary');action.type='button';
    action.addEventListener('click',()=>copyFull(copyValue,list.copyStatus));
    definition.append(action);
  }
  list.append(term,definition);
}

function detailGroup(label,copyStatus) {
  const section=node('section');section.setAttribute('aria-label',label);
  const title=node('h5',label),list=node('dl');list.copyStatus=copyStatus;
  section.append(title,list);return {section,list};
}

export function chainPanel(api, {actorId,accessController,onSelectOwnerTransfer,initialReadView}={}) {
  const panel = node("section", undefined, "admin-card admin-chain-panel");
  panel.append(node("h3", "官方钱包链上流水"), node("p",
    "TronGrid 单源监控。平台入账与提现结算以关联账本为准；待处理或证据冲突的流水需核查。", "admin-audit-note"));
  const summary = node("p", "正在读取监控状态…", "admin-audit-note");
  summary.setAttribute("role", "status");
  const form = node("form", undefined, "admin-filters");
  const direction = node("select", undefined, "admin-filter");
  direction.setAttribute("aria-label", "流水方向");
  for (const [value, label] of [["", "全部方向"], ["INFLOW", "转入"], ["UNMATCHED_OUTFLOW", "转出"]]) {
    const option = node("option", label); option.value = value; direction.append(option);
  }
  const txid = node("input", undefined, "admin-filter");
  txid.placeholder = "完整交易哈希"; txid.setAttribute("aria-label", "完整交易哈希");
  txid.pattern = "[a-fA-F0-9]{64}";
  const dates = ["开始时间", "结束时间"].map(label => {
    const input = node("input", undefined, "admin-filter");
    input.type = "datetime-local"; input.setAttribute("aria-label", label);
    input.title = "按北京时间输入（UTC+08:00）"; return input;
  });
  const submit = node("button", "查询 / 刷新", "admin-primary"); submit.type = "submit";
  form.append(direction, txid, ...dates, submit);
  const state = node("p", "正在加载流水…", "admin-audit-note"); state.setAttribute("role", "status");
  const copyStatus=node('p',undefined,'admin-audit-note');copyStatus.setAttribute('role','status');
  const rows = node("div",undefined,"admin-table-scroll"); rows.style.overflowX = "auto";
  const detail = node("section",undefined,"admin-chain-detail"); detail.setAttribute("aria-label", "流水详情"); detail.setAttribute("aria-live", "polite");
  const previous = node("button", "上一页", "admin-secondary"); previous.type = "button";
  const next = node("button", "下一页", "admin-secondary"); next.type = "button";
  const paging = node("div", undefined, "admin-filters"); paging.append(previous, next);
  panel.append(summary, form, state, copyStatus, rows, paging);
  let detailModal,repairModal;
  let offset = 0, snapshot, activeFilters = {}, generation = 0, detailGeneration = 0, candidateGeneration = 0;
  let selectedRecord,readDetail,suspendedReadDetail,visibleItems,visibleTotal,healthSummary;
  let loading = false, disposed = false, suspendedForAccessCheck = false;
  let limit = 10;
  const sizeControl=pageSizeControl(changePageSize(value=>limit=value,()=>load({fresh:true,requestedOffset:0})));paging.append(sizeControl);
  let lastPaging=[true,true],stableState=state.textContent;
  function staleDetail(message) {
    detail.replaceChildren(...Array.from(detail.children).filter(child=>child.className!=="admin-chain-stale"),
      node("p", `${message}；上次详情已过期，请刷新重试。`, "admin-chain-stale"));
  }
  function openDetailModal() {
    if(!detailModal)detailModal=detailDialog('流水详情',detail,{onClose:()=>{
      detailModal=null;selectedRecord=undefined;readDetail=undefined;++detailGeneration;++candidateGeneration;
    }});
  }
  async function selectOwnerTransferCandidate(item,record,status,button,selection) {
    if(disposed||suspendedForAccessCheck||selection!==candidateGeneration||!detailModal)return false;
    button.disabled=true;status.textContent='正在核对同一交易的链上观察记录…';
    try {
      if(!observedOutflow(record,item.txid)||record.log_index!==item.log_index)throw Error('incomplete selection');
      const page=await api.getChainTransactions({txid:item.txid,limit:100,offset:0});
      if(disposed||suspendedForAccessCheck||selection!==candidateGeneration||!detailModal)return false;
      if(!page||!Number.isSafeInteger(page.total)||page.total<1||page.total>100||
          !Array.isArray(page.items)||page.items.length!==page.total||
          (page.offset!==undefined&&page.offset!==0))throw Error('incomplete observation');
      const indexes=new Set();
      for(const row of page.items){
        if(!row||typeof row.txid!=='string'||row.txid.toLowerCase()!==item.txid.toLowerCase()||
            !Number.isSafeInteger(row.log_index)||row.log_index<0||indexes.has(row.log_index))throw Error('ambiguous indexes');
        indexes.add(row.log_index);
      }
      if(!indexes.has(item.log_index))throw Error('selection missing');
      const observed=await Promise.all(page.items.map(row=>api.getChainTransaction(row.txid,row.log_index)));
      if(disposed||suspendedForAccessCheck||selection!==candidateGeneration||!detailModal)return false;
      const visible=new Set();let chosen;
      for(let index=0;index<observed.length;index++){
        const row=page.items[index],full=observed[index];
        if(!full||full.log_index!==row.log_index||typeof full.txid!=='string'||
            full.txid.toLowerCase()!==item.txid.toLowerCase()||full.direction!==row.direction||
            full.timestamp_ms!==row.timestamp_ms||normalizedAmount(full.amount)!==normalizedAmount(row.amount))
          throw Error('changed observation');
        if(full.direction!=='UNMATCHED_OUTFLOW')continue;
        if(!observedOutflow(full,item.txid))throw Error('incomplete outflow');
        const fingerprint=`${normalizedAmount(full.amount)}|${full.to_address}|${full.timestamp_ms}`;
        if(visible.has(fingerprint))throw Error('indistinguishable outflows');
        visible.add(fingerprint);
        if(full.log_index===item.log_index)chosen=full;
      }
      if(!chosen||normalizedAmount(chosen.amount)!==normalizedAmount(record.amount)||
          chosen.to_address!==record.to_address||chosen.timestamp_ms!==record.timestamp_ms)
        throw Error('changed selection');
      const accepted=await onSelectOwnerTransfer({txid:chosen.txid.toLowerCase(),log_index:chosen.log_index,
        amount:normalizedAmount(chosen.amount),to_address:chosen.to_address,timestamp_ms:chosen.timestamp_ms});
      if(disposed||suspendedForAccessCheck||selection!==candidateGeneration||!detailModal)return false;
      if(accepted===false)throw Error('selection rejected');
      status.textContent='已选择链上转出，请在申报区核对用途并预检。';return true;
    } catch {
      if(!disposed&&!suspendedForAccessCheck&&selection===candidateGeneration&&detailModal)
        status.textContent='观察记录不完整或无法安全区分，请等待链上同步或人工核查。';
      return false;
    } finally {button.disabled=false;}
  }
  function renderDetail(item,record,cachedAt) {
      const detailCopyStatus=node('p',undefined,'admin-audit-note');detailCopyStatus.setAttribute('role','status');
      const chain=detailGroup('链上证据',detailCopyStatus);
      appendField(chain.list,'交易哈希 / 日志',`${shortHash(record.txid)} / #${record.log_index}`,
        {copyValue:transferKey(record),copyLabel:'复制完整交易哈希 / 日志'});
      appendField(chain.list,'区块高度',record.block_number);
      appendField(chain.list,'链上时间',time(record.timestamp_ms));
      const evidence={VERIFIED:'已核验（TronGrid 单源）',UNVERIFIED:'尚未核验',CONFLICT:'证据冲突，需核查'};
      appendField(chain.list,'证据状态',evidence[record.platform_record?.evidence_status]??'链上单源观察，平台尚未核定');
      const path=detailGroup('资金路径',detailCopyStatus);
      appendField(path.list,'转出地址',shortChainValue(record.from_address),
        record.from_address?{copyValue:record.from_address,copyLabel:'复制完整转出地址'}:{});
      appendField(path.list,'转入地址',shortChainValue(record.to_address),
        record.to_address?{copyValue:record.to_address,copyLabel:'复制完整转入地址'}:{});
      appendField(path.list,'USDT 金额',record.amount??'暂无');
      const association=detailGroup('平台关联',detailCopyStatus);
      const link = record.platform_record;
      if (link) {
        appendField(association.list,'用户归属说明',link.attribution_reason_text??(link.user_id?'已关联业务记录':'尚无通过核验的用户关联，请核查绑定及订单匹配原因'));
        if(link.user_username){appendField(association.list,'畅聊号',link.user_username);appendField(association.list,'用户名',link.user_nickname??'—');}
        for (const [key, label] of [["record_id", "关联收款 / 提现单"], ["user_id", "用户归属"],
          ["ledger_transaction_id", "账本交易编号"], ["intent_id", "充值意图编号"], ["reason_code", "核定原因码"]]) {
          appendField(association.list,label,link[key]??'尚未关联');
        }
        appendField(association.list,'平台处理',accounting(record));
      } else {
        association.section.append(node('p',record.direction==='UNMATCHED_OUTFLOW'
          ? '尚无可验证关联。该链上转出未关联人工出款订单；所有者转出申报以独立记录为准。'
          : '尚无可验证关联。请核查平台收款与账本资料。'));
      }
      for(const group of [chain,path,association])group.list.style.overflowWrap='anywhere';
      const candidateStatus=node('p',undefined,'admin-audit-note');candidateStatus.setAttribute('role','status');
      const candidate=typeof onSelectOwnerTransfer==='function'&&record.direction==='UNMATCHED_OUTFLOW'
        ? node('button','用于所有者转出申报','admin-secondary'):null;
      if(candidate){candidate.type='button';const selection=++candidateGeneration;
        candidate.addEventListener('click',()=>selectOwnerTransferCandidate(item,record,candidateStatus,candidate,selection));}
      detail.replaceChildren(node('h4',`${directionLabel(record)} · ${record.amount??'暂无'} USDT`),
        chain.section,path.section,association.section,
        node('p',`平台处理：${accounting(record)}。`),...(candidate?[candidate,candidateStatus]:[]),
        detailCopyStatus,node('p',`${cachedAt?'详情缓存于':'详情更新于'} ${time(cachedAt??Date.now())}`));
  }
  async function showDetail(item, preserve = false) {
    if(disposed||suspendedForAccessCheck)return false;
    openDetailModal();selectedRecord=item;
    const current = generation;
    const selected = ++detailGeneration;
    ++candidateGeneration;
    if(!preserve){readDetail=undefined;detail.replaceChildren(node("p", "正在加载详情…"));}
    try {
      const record = await api.getChainTransaction(item.txid, item.log_index);
      if (disposed || suspendedForAccessCheck || current !== generation || selected !== detailGeneration) return false;
      readDetail={item,record,fetchedAt:Date.now()};renderDetail(item,record);
      return true;
    } catch { if (!disposed && current === generation && selected === detailGeneration) staleDetail('详情读取失败');return false; }
  }
  function renderSummary(health) {
    summary.textContent=`链上观察余额（不等于账本可用余额）：${health.balance??'暂无'} USDT；观察器最近成功扫描：${time(health.last_success_ms)}；扫描水位：${time(health.checkpoint_ms)}；覆盖起点：${time(health.coverage_start_ms)}；观察器：${health.observer_status}；对账：${health.reconciliation}。`;
  }
  function renderRows(page) {
    const table = node("table", undefined, "admin-table"), head = node("thead"), body = node("tbody"), headers = node("tr");
    for (const label of ["时间", "方向", "金额（USDT）", "交易哈希 / 日志", "入账核定", "操作"]) headers.append(node("th", label));
    head.append(headers);
    for (const item of page.items) {
      const tr = node("tr");
      for (const value of [time(item.timestamp_ms), directionLabel(item), item.amount]) tr.append(node('td',value));
      const locator=node('td',`${shortHash(item.txid)} / #${item.log_index}`);
      const copy=node('button','复制完整哈希 / 日志','admin-secondary');copy.type='button';
      copy.addEventListener('click',()=>copyFull(transferKey(item),copyStatus));locator.append(copy);
      tr.append(locator,node('td',accounting(item)));
      const cell = node("td"), action = node("button", "详情", "admin-secondary"); action.type = "button";
      action.addEventListener("click", () => showDetail(item)); cell.append(action); tr.append(cell); body.append(tr);
      if(actorId){const repair=node('button',item.direction==='INFLOW'?'充值补入账':'提现核对','admin-secondary');repair.type='button';repair.addEventListener('click',async()=>{
        if(disposed||suspendedForAccessCheck)return;
        if(accessController&&!accessController.canWrite()){
          state.textContent='请先验证以操作。验证后请再次选择这笔流水；系统不会自动打开或提交修复。';
          await accessController.requestWriteGrant();return;
        }
        repairModal?.close();repairModal=walletRepairDialog(api,item,{actorId,accessController,onClose:()=>{repairModal=null;},onCompleted:()=>panel.refresh()});
      });cell.append(repair);}
    }
    table.append(head,body);rows.replaceChildren(table);
    previous.disabled=offset===0;next.disabled=offset+page.items.length>=page.total;
    lastPaging=[previous.disabled,next.disabled];
  }
  async function load({fresh = false, preserveSelection = false, requestedOffset = offset, filters = activeFilters} = {}) {
    if(disposed||suspendedForAccessCheck||loading)return false;
    const current = ++generation;loading=true;
    const priorPaging=[previous.disabled,next.disabled];
    previous.disabled = next.disabled = submit.disabled = true;
    state.textContent = "正在加载流水…";
    try {
      const [health, page] = await Promise.all([api.getChainSummary(), api.getChainTransactions({ ...filters, limit, offset:requestedOffset, snapshot:fresh?undefined:snapshot })]);
      if (disposed || suspendedForAccessCheck || current !== generation) return false;
      snapshot = page.snapshot;offset=requestedOffset;activeFilters=filters;
      healthSummary=health;visibleItems=page.items.slice(0,limit);visibleTotal=page.total;
      renderSummary(health);
      state.textContent = page.total ? `共 ${page.total} 笔，显示 ${offset + 1}–${offset + page.items.length}。新流水请点击刷新。` : "当前筛选范围内暂无流水。";
      renderRows(page);stableState=state.textContent;
      if(preserveSelection&&selectedRecord)return await showDetail(selectedRecord,true);
      selectedRecord=undefined;detail.replaceChildren();
      return true;
    } catch {
      if (disposed || suspendedForAccessCheck || current !== generation) return false;
      if(!rows.children.length)summary.textContent = "监控状态读取失败，不能据此判断钱包余额或扫描进度。";
      state.textContent = '流水加载失败。上次流水与监控状态已过期，请点击查询 / 刷新重试。';
      stableState=state.textContent;
      if(selectedRecord)staleDetail("本轮刷新未完成");
      [previous.disabled,next.disabled]=priorPaging;
      return false;
    } finally { if (current === generation) {submit.disabled = false;loading=false;} }
  }
  form.addEventListener("submit", event => {
    event.preventDefault();
    if(disposed||suspendedForAccessCheck)return;
    const start = parseBeijingInput(dates[0].value);
    const end = parseBeijingInput(dates[1].value);
    if ([start, end].some(value => value !== undefined && !Number.isFinite(value))) {
      state.textContent = "请输入有效的北京时间。"; return;
    }
    if (start !== undefined && end !== undefined && start > end) { state.textContent = "开始时间不能晚于结束时间。"; return; }
    const filters = { direction: direction.value, txid: txid.value.trim(), start_ms: start, end_ms: end };
    void load({filters,requestedOffset:0,fresh:true});
  });
  previous.addEventListener("click", () => load({requestedOffset:Math.max(0,offset-limit)}));
  next.addEventListener("click", () => load({requestedOffset:offset+limit}));
  function restoreReadView(view) {
    direction.value=view.draftFilters.direction??'';
    txid.value=view.draftFilters.txid??'';
    dates[0].value=view.draftFilters.start??'';
    dates[1].value=view.draftFilters.end??'';
    limit=view.pageSize;sizeControl.commitPageSize(limit);activeFilters=view.activeFilters;offset=view.offset;snapshot=view.snapshot;
    visibleItems=view.items;visibleTotal=view.total;healthSummary=view.summary;
    renderSummary(healthSummary);
    state.textContent=view.total?
      `共 ${view.total} 笔，显示 ${offset+1}–${offset+view.items.length}。本页缓存于 ${time(view.cachedAt)}；新流水请点击刷新。`:
      `当前筛选范围内暂无流水。本页缓存于 ${time(view.cachedAt)}；新流水请点击刷新。`;
    stableState=state.textContent;
    renderRows({items:visibleItems,total:visibleTotal});
    rows.scrollLeft=view.scrollLeft;
    if(view.detail?.open){
      openDetailModal();selectedRecord=view.detail.item;
      readDetail={item:view.detail.item,record:view.detail.record,fetchedAt:view.cachedAt};
      renderDetail(view.detail.item,view.detail.record,view.cachedAt);
    }
    const restoreScroll=()=>{if(disposed)return;rows.scrollLeft=view.scrollLeft;
      globalThis.window?.scrollTo?.(0,view.pageScrollY);};
    if(typeof globalThis.requestAnimationFrame==='function')globalThis.requestAnimationFrame(restoreScroll);
    else queueMicrotask(restoreScroll);
  }
  panel.exportReadView=()=>{
    if(disposed||suspendedForAccessCheck||!healthSummary||!visibleItems)return null;
    return validateChainReadView({
      draftFilters:{direction:direction.value,txid:txid.value,start:dates[0].value,end:dates[1].value},
      pageSize:limit,activeFilters,offset,snapshot,items:visibleItems.slice(0,limit),summary:healthSummary,total:visibleTotal,
      pageScrollY:globalThis.window?.scrollY??0,scrollLeft:rows.scrollLeft??0,
      ...(detailModal&&readDetail&&selectedRecord?{detail:{item:readDetail.item,record:readDetail.record,open:true}}:{}),
      cachedAt:Date.now()
    });
  };
  panel.refresh=()=>loading||disposed||suspendedForAccessCheck?Promise.resolve(false):load({fresh:true,preserveSelection:true});
  panel.suspendForAccessCheck=()=>{
    if(disposed||suspendedForAccessCheck)return;
    suspendedForAccessCheck=true;
    const prior=detailModal&&readDetail&&selectedRecord?readDetail:undefined;
    ++generation;++detailGeneration;++candidateGeneration;
    if(loading){loading=false;submit.disabled=false;[previous.disabled,next.disabled]=lastPaging;
      state.textContent=rows.children.length?stableState:'流水读取已中断，请点击查询 / 刷新。';}
    detailModal?.close();repairModal?.close();
    suspendedReadDetail=prior;
  };
  panel.resumeReadDetail=()=>{
    if(disposed||!suspendedForAccessCheck)return false;
    suspendedForAccessCheck=false;
    const prior=suspendedReadDetail;suspendedReadDetail=undefined;
    if(!prior)return false;
    openDetailModal();selectedRecord=prior.item;readDetail=prior;
    renderDetail(prior.item,prior.record,prior.fetchedAt);
    return true;
  };
  panel.dispose=()=>{disposed=true;suspendedForAccessCheck=true;suspendedReadDetail=undefined;
    ++generation;++detailGeneration;++candidateGeneration;detailModal?.close();repairModal?.close();};
  const restored=initialReadView?validateChainReadView(initialReadView):null;
  if(restored&&[10,20,50].includes(restored.pageSize))restoreReadView(restored);else void load();
  return panel;
}
