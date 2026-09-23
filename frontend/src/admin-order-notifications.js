// Cursor advances only after the consumer has applied a page. A failed request is
// retried at the same cursor; IDs make a repeated response safe.
export function createOrderFeed(api,{visible=()=>!document.hidden,onEvents=()=>{},onError=()=>{}}={}) {
  let cursor=null,busy=false,stopped=false;
  const seen=new Set();
  return {
    async poll(){
      if(stopped||busy||!visible())return;
      busy=true;
      try {
        const page=await api.getOrderEvents({...cursor?{cursor}:{},limit:100});
        if(stopped)return;
        const fresh=[];const batch=new Set();
        for(const event of page.items??[])if(event.id&&!seen.has(event.id)&&!batch.has(event.id)){batch.add(event.id);fresh.push(event);}
        await onEvents(fresh);
        for(const id of batch)seen.add(id);
        cursor=page.next_cursor??cursor;
      }catch(error){if(error.status===401||error.status===403)stopped=true;onError(error);}
      finally{busy=false;}
    },
    dispose(){stopped=true;}
  };
}

export function orderNotifications(api,{onOpen=()=>{},onChange=()=>{}}={}) {
  const root=document.createElement('div');root.className='admin-order-notifications';
  const badge=document.createElement('button');badge.className='admin-secondary';badge.textContent='订单提醒 0';
  const toast=document.createElement('p');toast.className='admin-audit-note';toast.setAttribute('role','status');toast.setAttribute('aria-live','polite');
  let unread=0;
  badge.addEventListener('click',()=>{unread=0;badge.textContent='订单提醒 0';toast.textContent='';onOpen();});
  const feed=createOrderFeed(api,{onEvents:async events=>{if(!events.length)return;await onChange(events);unread+=events.length;badge.textContent=`订单提醒 ${unread}`;toast.textContent=`收到 ${events.length} 条订单更新，请打开工作台查看。`;},onError:error=>{toast.textContent=error.status===403?'订单提醒权限已失效':'订单提醒连接中断，将自动补齐。';}});
  root.append(badge,toast);
  const timer=setInterval(()=>void feed.poll(),10000);timer.unref?.();
  const resume=()=>void feed.poll();document.addEventListener?.('visibilitychange',resume);void feed.poll();
  root.dispose=()=>{feed.dispose();clearInterval(timer);document.removeEventListener?.('visibilitychange',resume);};
  return root;
}
