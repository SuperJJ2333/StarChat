import {formatBeijingTime, reasonLabel, actorLabel} from './admin-formatters.js';
import {installSidebarResize} from './admin-sidebar.js';
import {openProofDialog} from './admin-proof-dialog.js';
// Read-only dashboard presentation. Asset arithmetic belongs to the business API.
export function formatPoints(value) {
  if(typeof value!=='string'||! /^-?\d+\.\d{2}$/.test(value))return '—';
  const [whole,cents]=value.split('.');return `${whole.replace(/\B(?=(\d{3})+(?!\d))/g,',')}.${cents}`;
}
export function trendGeometry(data) {
  const valid=Array.isArray(data)?data.filter(p=>typeof p.date==='string'&&Number.isSafeInteger(p.value)&&p.value>=0):[];
  const max=Math.max(1,...valid.map(p=>p.value));
  return {max,points:valid.map((p,i)=>({...p,x:48+(valid.length===1?0.5:i/(valid.length-1))*688,y:192-p.value/max*156}))};
}
export function refreshCoordinator() {
  let pending=null;
  return tasks=>pending??(pending=Promise.allSettled(tasks.map(task=>Promise.resolve().then(task))).finally(()=>{pending=null;}));
}
const el=(tag,cls,text)=>{const n=document.createElement(tag);n.className=cls??'';if(text!==undefined)n.textContent=text;return n;};
const btn=(label,run,cls='admin-secondary')=>{const n=el('button',cls,label);n.type='button';n.addEventListener('click',run);return n;};
export function refreshIcon(run) {
  const n=btn('↻',run,'admin-refresh-icon');n.title='刷新';n.setAttribute('aria-label','刷新');return n;
}
function chartView(data) {
  const root=el('div','admin-trend-visual'),{max,points}=trendGeometry(data);
  if(!points.length){root.append(el('p','admin-audit-note','暂无趋势数据'));return root;}
  const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 760 232');svg.setAttribute('role','img');svg.setAttribute('aria-label','每日注册人数趋势，下方可查看完整数据表');
  function part(tag,attrs,text){const p=document.createElementNS(svg.namespaceURI,tag);for(const [k,v] of Object.entries(attrs))p.setAttribute(k,v);if(text!==undefined)p.textContent=text;svg.append(p);return p;}
  for(const fraction of (max===1?[0,1]:[0,0.5,1])){const y=192-156*fraction;part('line',{x1:48,y1:y,x2:736,y2:y,class:'admin-chart-grid'});part('text',{x:38,y:y+4,'text-anchor':'end'},String(max*fraction));}
  part('polyline',{points:points.map(p=>`${p.x},${p.y}`).join(' '),fill:'none',class:'admin-chart-line'});
  for(const p of points){const dot=part('circle',{cx:p.x,cy:p.y,r:4,class:'admin-chart-dot',tabindex:0});const title=document.createElementNS(svg.namespaceURI,'title');title.textContent=`${p.date}：${p.value} 人`;dot.setAttribute('aria-label',title.textContent);dot.append(title);}
  const first=points[0],last=points.at(-1);part('text',{x:48,y:220},first.date);part('text',{x:736,y:220,'text-anchor':'end'},last.date);
  const details=el('details','admin-chart-data');details.append(el('summary',null,'查看每日数据'));
  const table=el('table','admin-table');const head=table.createTHead().insertRow();head.append(el('th',null,'日期（北京时间自然日）'),el('th',null,'注册人数'));
  const body=table.createTBody();for(const p of points)body.insertRow().append(el('td',null,p.date),el('td',null,String(p.value)));
  details.append(table);root.append(svg,el('p','admin-audit-note','北京时间 · 今日数据尚未结束'),details);return root;
}
export function createAdminShell({context,api,modules,renderModule,onLogout}) {
  const page=el('div','admin-page admin-modern'),shell=el('div','admin-shell'),side=el('aside','admin-sidebar');side.id='admin-sidebar';
  const can=p=>context.permissions.includes('*')||context.permissions.includes(p);
  const logo=el('div','admin-logo'),mark=el('img','admin-brand-image');mark.src='/assets/branding/admin-logo.png';mark.alt='畅聊';logo.append(mark,el('span',null,'畅聊管理台'));side.append(logo);
  const nav=el('nav','admin-nav');nav.setAttribute('aria-label','功能模块');side.append(nav);
  const main=el('div','admin-main'),top=el('header','admin-topbar');
  const setHidden=value=>sidebar.setHidden(value);
  const routeTitle=el('h1',null,'运营概览'),tools=el('div','admin-topbar-actions'),status=el('span','admin-refresh-status');status.setAttribute('role','status');
  const refresh=refreshIcon(async()=>{if(refresh.disabled)return;refresh.disabled=true;refresh.setAttribute('aria-busy','true');status.textContent='刷新中…';const results=await coordinate([()=>loadCurrent(true)]);const failed=results.some(r=>r.status==='rejected'||r.value===false);status.textContent=failed?'部分数据刷新失败，请重试':`更新于 ${formatBeijingTime(new Date())}`;refresh.disabled=false;refresh.setAttribute('aria-busy','false');});
  tools.append(status,el('span','admin-actor',context.actor.display_name??'管理员'),refresh,btn('退出',()=>onLogout?.()));top.append(routeTitle,tools);
  const content=el('main','admin-content');content.id='admin-content';const backdrop=btn('',()=>setHidden(true),'admin-sidebar-backdrop');backdrop.setAttribute('aria-label','关闭侧边栏');
  main.append(top,content);shell.append(side,main);page.append(shell,backdrop);
  const sidebar=installSidebarResize({page,side,main});let closeProof=null;
  let current='overview',generation=0,days=30,currentPanel=null,initialOverview=true;
  const coordinate=refreshCoordinator();
  const links=new Map();
  function addNavigation(key,label){const item=btn(label,()=>{if(current===key)return;current=key;for(const [k,b] of links){b.classList.toggle('active',k===key);b.setAttribute('aria-current',k===key?'page':'false');}routeTitle.textContent=label;closeProof?.();closeProof=null;if(currentPanel?.dispose)currentPanel.dispose();else currentPanel?.querySelector('.admin-manual-wallet-panel')?.dispose?.();currentPanel=null;content.replaceChildren();void loadCurrent(false);if(matchMedia('(max-width:760px)').matches)setHidden(true);});item.dataset.module=key;nav.append(item);links.set(key,item);}
  addNavigation('overview','运营概览');links.get('overview').classList.add('active');links.get('overview').setAttribute('aria-current','page');
  const groups=[['用户与安全',['security','support-role','analytics','online']],['运营',['ads','notice']],['财务',['finance','ledger','wallet']]];
  for(const [label,keys] of groups){const entries=modules.filter(([, ,key,p])=>keys.includes(key)&&can(p));if(!entries.length)continue;nav.append(el('p','admin-nav-group',label));for(const [name,,key] of entries)addNavigation(key,name);}
  const esc=event=>{if(event.key==='Escape'&&!side.hidden&&matchMedia('(max-width:760px)').matches)setHidden(true);};page.addEventListener('keydown',esc);
  page.dispose=()=>{++generation;sidebar.dispose();closeProof?.();page.removeEventListener('keydown',esc);if(currentPanel?.dispose)currentPanel.dispose();else currentPanel?.querySelector('.admin-manual-wallet-panel')?.dispose?.();};
  async function loadCurrent(isRefresh){
    const revision=++generation;
    try{
      if(current==='overview'){
        const overview=initialOverview&&!isRefresh?context.overview:await api.getOverview({days});initialOverview=false;
        if(revision!==generation)return;
        const issuance=content.querySelector('.admin-issuance'),opened=content.querySelector('.admin-chart-data')?.open;
        const view=overviewView(overview);if(issuance)view.append(issuance);content.replaceChildren(view);
        if(opened&&content.querySelector('.admin-chart-data'))content.querySelector('.admin-chart-data').open=true;
        if(issuance?.refresh)return await issuance.refresh();if(can('admin.ledger.read'))return await showIssuance(view);return true;
      }
      if(currentPanel?.refresh&&isRefresh)return await currentPanel.refresh();
      if(currentPanel&&isRefresh){const wallet=currentPanel.querySelector('.admin-manual-wallet-panel');if(wallet?.refresh){const result=await wallet.refresh();return result!==false&&(!Array.isArray(result)||result.every(r=>r.status!=='rejected'));}}
      // Wallet owns its privacy gate; no sensitive module request before verification.
      const payload=current==='wallet'?{}:await api.getModule(current);if(revision!==generation)return;
      // Module tables refresh independently of command forms to retain user drafts.
      const rendered=renderModule(current,routeTitle.textContent,{...context,onWalletExit:()=>links.get('overview').click(),modules:{...context.modules,[current]:payload}});
      if(isRefresh&&currentPanel){const oldTable=currentPanel.querySelector('.admin-table'),newTable=rendered.querySelector('.admin-table');if(oldTable&&newTable)oldTable.replaceWith(newTable);}
      else{currentPanel=rendered;content.replaceChildren(rendered);}return true;
    }catch(error){if(revision!==generation)return;const old=content.querySelector('.admin-load-error');old?.remove();content.prepend(el('p','admin-load-error',`数据读取失败：${error.message??'请重试'}。现有数据可能已过期。`));return false;}
  }
  function overviewView(data){
    const root=el('div','admin-overview'),cards=el('div','admin-kpis');
    for(const [key,label,p] of [['registered_users','注册用户','admin.analytics.read'],['online_customers','在线客户','admin.presence.read'],['pending_withdrawals','待审核提现','admin.withdrawals.read'],['today_point_volume','今日点钻流水','admin.ledger.read']]){if(!can(p))continue;const metric=data[key]?.value??data[key];const value=key==='today_point_volume'?formatPoints(metric):(Number.isSafeInteger(metric)?metric.toLocaleString('zh-CN'):'—');const card=el('article','admin-card');card.append(el('p','admin-kpi-label',label),el('strong','admin-kpi-value',value));cards.append(card);}root.append(cards);
    if(can('admin.ledger.read')){
      const supply=data.point_supply,s=el('section','admin-card admin-supply');s.append(el('p','admin-kpi-label','平台点钻总量'),el('strong','admin-supply-total',formatPoints(supply?.total)));
      if(supply){const details=el('dl','admin-supply-breakdown');for(const [key,label] of [['issued','累计发行'],['returned','累计回收 / 冲正'],['holdings','用户与托管持有'],['platform_fees','平台手续费']])details.append(el('dt',null,label),el('dd',null,formatPoints(supply[key])));s.append(details,el('p',supply.balanced?'admin-audit-note':'admin-load-error',supply.balanced?'账本总量核对一致 · 转账和红包流转不重复计入发行':'账本一致性尚未确认，请核对发行凭证'));}else s.append(el('p','admin-audit-note','总量数据暂不可用'));
      s.append(el('p','admin-audit-note','总量包含平台手续费持有，不等同于用户可兑付负债或 USDT 储备。'));root.append(s);
    }
    if(can('admin.analytics.read')){const chart=el('section','admin-card admin-trend-card'),head=el('div','admin-panel-heading'),select=el('select','admin-filter');select.setAttribute('aria-label','注册趋势日期范围');for(const value of [7,30,90]){const option=el('option',null,`最近 ${value} 天`);option.value=String(value);select.append(option);}select.value=String(days);select.addEventListener('change',()=>{days=Number(select.value);void loadCurrent(true);});head.append(el('h2',null,'注册用户趋势'),select);chart.append(head,chartView(data.registration_trend));root.insertBefore(chart,root.querySelector('.admin-supply'));}return root;
  }
  async function showIssuance(parent){
    parent.querySelector('.admin-issuance')?.remove();const box=el('section','admin-card admin-issuance');parent.append(box);const title=el('h2',null,'发行与回收凭证'),kind=el('select','admin-filter');kind.setAttribute('aria-label','凭证类型');for(const [value,label] of [['','全部'],['issued','发行'],['returned','回收 / 冲正']]){const option=el('option',null,label);option.value=value;kind.append(option);}const records=el('div','admin-table-scroll'),feedback=el('p','admin-audit-note');box.append(title,kind,feedback,records);let revision=0;
    async function load(cursor){const requestedKind=kind.value,version=++revision;feedback.textContent='正在读取凭证…';try{const result=await api.getPointIssuance({limit:25,cursor,kind:requestedKind});if(version!==revision)return;currentCursor=cursor;currentKind=requestedKind;records.replaceChildren();const table=el('table','admin-table');table.createTHead().insertRow().append(...['交易 / 原交易','时间','数量（点钻）','操作人','原因','审计'].map(x=>el('th',null,x)));const body=table.createTBody();for(const item of result.items){const row=body.insertRow();row.append(...[item.transaction_id,formatBeijingTime(item.created_at),formatPoints(item.amount),actorLabel(item),reasonLabel(item.reason_code)].map(x=>el('td',null,x??'—')));const audit=el('td');audit.append(btn('查看凭证',()=>showProof(item.transaction_id)));row.append(audit);if(item.reversal_of_id)row.children[0].append(btn(`查看原交易 ${item.reversal_of_id}`,()=>showProof(item.reversal_of_id)));}records.append(table);if(result.next_cursor)records.append(btn('下一页',()=>load(result.next_cursor)));feedback.textContent=result.items.length?'按账本交易逐笔追溯':'暂无发行或回收记录';return true;}catch(error){if(version===revision){kind.value=currentKind;feedback.textContent=`凭证读取失败：${error.message}。保留上次数据。`;}return false;}}
    let currentCursor,currentKind='';box.refresh=()=>load(currentCursor);kind.addEventListener('change',()=>load());return await load();
  }
  function showProof(id){closeProof?.();closeProof=openProofDialog({id,api,formatPoints});}
  void loadCurrent(false);return page;
}
