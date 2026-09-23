import {icon} from './icons/icons.js';

// The API cursor is an actor-scoped inbox position, not an event ID or timestamp.
export function createOrderFeed(api,{visible=()=>!document.hidden,onEvents=()=>{},onError=()=>{},onHealthy=()=>{},onCursor=()=>{},initialCursor=null,bootstrap=false}={}) {
  let cursor=initialCursor,busy=false,stopped=false,initializing=bootstrap;
  const seen=new Set();
  return {
    async poll(){
      if(stopped||busy||!visible())return;
      busy=true;
      try {
        // Bound catch-up work per tick so a large inbox never monopolizes the UI.
        for(let pages=0;pages<10&&!stopped&&visible();pages++){
          const page=await api.getOrderEvents({...cursor?{cursor}:{},limit:100});
          if(stopped)return;
          const fresh=[],batch=new Set();
          for(const event of page.items??[])if(event.id&&!seen.has(event.id)&&!batch.has(event.id)){batch.add(event.id);fresh.push(event);}
          await onEvents(fresh,{initializing});
          if(stopped)return;
          for(const id of batch)seen.add(id);
          while(seen.size>1000)seen.delete(seen.values().next().value);
          const previous=cursor;cursor=page.next_cursor??cursor;
          const more=(page.items?.length??0)>=100&&cursor!==previous;
          if(!more)initializing=false;
          onCursor(cursor,{initializing});onHealthy();
          if(!more)break;
        }
      }catch(error){
        if(stopped)return;
        if(error.status===401||error.status===403)stopped=true;
        if(error.status===400&&cursor){cursor=null;initializing=true;seen.clear();onCursor(null,{initializing});}
        onError(error);
      }
      finally{busy=false;}
    },
    dispose(){stopped=true;}
  };
}

export function orderNotifications(api,{onOpen=()=>{},onChange=()=>{},actorId=null,storage}={}) {
  if(storage===undefined){try{storage=globalThis.localStorage;}catch{storage=null;}}
  const storageKey=actorId?'starchat.order-notifications.v1:'+encodeURIComponent(actorId):null;
  let saved={};try{saved=JSON.parse(storageKey&&storage?.getItem(storageKey)||'{}')??{};}catch{/* Storage is optional. */}
  let cursor=typeof saved.cursor==='string'?saved.cursor:null;
  let initializing=saved.initializing!==false;
  let unread=Number.isSafeInteger(saved.unread)&&saved.unread>0?Math.min(saved.unread,999):0;
  let readCursor=typeof saved.readCursor==='string'?saved.readCursor:null,disposed=false,toastTimer;
  const root=document.createElement('div');root.className='admin-order-notifications';
  const badge=document.createElement('button');badge.className='admin-icon-button admin-notification-bell';badge.type='button';badge.append(icon('bell'));
  const count=document.createElement('span');count.className='admin-notification-count';count.setAttribute('aria-hidden','true');badge.append(count);
  const toast=document.createElement('div');toast.className='admin-notification-toast';toast.hidden=true;
  const message=document.createElement('p');message.setAttribute('role','status');message.setAttribute('aria-live','polite');
  const actions=document.createElement('div');actions.className='admin-notification-toast-actions';
  const open=document.createElement('button');open.type='button';open.className='admin-secondary';open.textContent='查看订单';
  const close=document.createElement('button');close.type='button';close.className='admin-icon-button';close.setAttribute('aria-label','关闭订单提醒');close.append(icon('close'));
  const error=document.createElement('p');error.className='admin-audit-note admin-notification-error';error.setAttribute('role','status');error.hidden=true;
  function persist(){try{if(storageKey)storage?.setItem(storageKey,JSON.stringify({cursor,readCursor,unread,initializing}));}catch{/* Disabled or full storage must not interrupt polling. */}}
  function render(){count.textContent=unread>99?'99+':String(unread);count.hidden=unread===0;badge.setAttribute('aria-label',unread?'订单提醒，'+unread+' 条未读':'订单提醒，暂无未读');badge.title=unread?unread+' 条未读订单':'暂无新订单';}
  function dismiss(){toast.hidden=true;message.textContent='';clearTimeout(toastTimer);}
  function markRead(){if(disposed)return;unread=0;readCursor=cursor;dismiss();render();persist();}
  function showOrders(){markRead();onOpen();}
  badge.addEventListener('click',showOrders);open.addEventListener('click',showOrders);close.addEventListener('click',dismiss);
  const feed=createOrderFeed(api,{initialCursor:cursor,bootstrap:initializing,onEvents:async(events,state)=>{
    if(!events.length)return;
    await onChange(events);
    if(disposed||state.initializing)return;
    const fresh=events.filter(event=>event.event_type==='recharge.submitted'||event.event_type==='wallet.manual_payout_request');
    if(!fresh.length)return;
    unread=Math.min(999,unread+fresh.length);render();
    const recharge=fresh.filter(event=>event.event_type==='recharge.submitted').length,payout=fresh.length-recharge;
    message.textContent='收到'+[recharge?recharge+' 笔充值订单':'',payout?payout+' 笔提现订单':''].filter(Boolean).join('、');
    toast.hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(dismiss,10000);toastTimer.unref?.();
  },onCursor:(next,state)=>{cursor=next;initializing=state.initializing;if(!unread)readCursor=cursor;persist();},onHealthy:()=>{error.hidden=true;error.textContent='';},onError:failure=>{
    error.hidden=false;error.textContent=failure.status===403?'订单提醒权限已失效，请联系管理员。':failure.status===401?'登录已失效，请重新登录以接收订单提醒。':failure.status===400?'订单提醒位置已失效，正在重新同步。':'订单提醒连接中断，正在自动重试。';
  }});
  actions.append(open,close);toast.append(message,actions);root.append(badge,toast,error);render();
  const timer=setInterval(()=>void feed.poll(),10000);timer.unref?.();
  const resume=()=>void feed.poll();document.addEventListener?.('visibilitychange',resume);void feed.poll();
  root.markRead=markRead;root.refresh=()=>feed.poll();
  root.dispose=()=>{disposed=true;feed.dispose();clearInterval(timer);clearTimeout(toastTimer);document.removeEventListener?.('visibilitychange',resume);};
  return root;
}
