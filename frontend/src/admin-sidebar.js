const MIN=200,MAX=360,KEY='chatflow.admin.sidebar.width';
export function installSidebarResize({page,side,main}){
  let width=240,dragging=false,hidden=false;
  try{const stored=Number(localStorage.getItem(KEY));if(stored>=MIN&&stored<=MAX)width=stored;}catch{/* A private browser may disable preferences. */}
  const mobile=()=>matchMedia('(max-width:760px)').matches;
  const handle=document.createElement('div');handle.className='admin-sidebar-resize';handle.tabIndex=0;
  for(const [key,value] of Object.entries({role:'separator','aria-label':'调整侧边栏宽度','aria-orientation':'vertical','aria-valuemin':MIN,'aria-valuemax':MAX}))handle.setAttribute(key,String(value));
  handle.title='左右拖动调整宽度，也可使用方向键';
  const toggle=document.createElement('button');toggle.type='button';toggle.className='admin-sidebar-toggle admin-sidebar-edge-toggle';toggle.setAttribute('aria-controls',side.id);
  const icon=document.createElementNS('http://www.w3.org/2000/svg','svg');icon.setAttribute('viewBox','0 0 24 24');icon.setAttribute('aria-hidden','true');
  const path=document.createElementNS(icon.namespaceURI,'path');path.setAttribute('d','m14 7-5 5 5 5');path.setAttribute('fill','none');path.setAttribute('stroke','currentColor');path.setAttribute('stroke-width','2');path.setAttribute('stroke-linecap','round');path.setAttribute('stroke-linejoin','round');icon.append(path);toggle.append(icon);
  page.append(handle,toggle);
  function paint(){
    page.style.setProperty('--sidebar-width',hidden?'0px':`${width}px`);
    side.hidden=hidden;handle.hidden=hidden||mobile();page.classList.toggle('is-sidebar-hidden',hidden);
    toggle.setAttribute('aria-expanded',String(!hidden));toggle.setAttribute('aria-label',hidden?'展开侧边栏':'收起侧边栏');toggle.title=hidden?'展开侧边栏':'收起侧边栏';
    handle.setAttribute('aria-valuenow',String(width));icon.style.transform=hidden?'rotate(180deg)':'';
    main.inert=!hidden&&mobile();
  }
  function setWidth(value){width=Math.max(MIN,Math.min(MAX,Math.round(value)));paint();try{localStorage.setItem(KEY,String(width));}catch{/* Layout remains usable without storage. */}}
  function setHidden(value,focus=true){hidden=value;paint();if(focus){if(hidden)toggle.focus();else if(mobile())side.querySelector('button')?.focus();}}
  toggle.addEventListener('click',()=>setHidden(!hidden));
  const stop=()=>{dragging=false;page.classList.remove('is-sidebar-resizing');};
  handle.addEventListener('pointerdown',event=>{if(event.button!==0)return;event.preventDefault();dragging=true;page.classList.add('is-sidebar-resizing');handle.setPointerCapture(event.pointerId);});
  handle.addEventListener('pointermove',event=>{if(dragging)setWidth(event.clientX);});
  handle.addEventListener('pointerup',stop);handle.addEventListener('pointercancel',stop);handle.addEventListener('lostpointercapture',stop);
  handle.addEventListener('keydown',event=>{const value={ArrowLeft:width-16,ArrowRight:width+16,Home:MIN,End:MAX}[event.key];if(value!==undefined){event.preventDefault();setWidth(value);}});
  let wasMobile=mobile();const resize=()=>{if(wasMobile!==mobile()){wasMobile=mobile();setHidden(wasMobile,false);}else paint();};
  globalThis.addEventListener('resize',resize);setHidden(mobile(),false);
  return {setHidden,isHidden:()=>hidden,dispose(){stop();globalThis.removeEventListener('resize',resize);handle.remove();toggle.remove();main.inert=false;}};
}
