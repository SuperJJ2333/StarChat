// Native modal owns focus; caller retains its list DOM, filters and paging.
export function detailDialog(title,content,{onClose=()=>{}}={}){
  const previous=document.activeElement,dialog=document.createElement('dialog');dialog.className='admin-proof-dialog';dialog.setAttribute('aria-label',title);
  const header=document.createElement('header');header.className='admin-proof-heading';const heading=document.createElement('h2');heading.textContent=title;
  const close=document.createElement('button');close.type='button';close.textContent='×';close.className='admin-dialog-close';close.setAttribute('aria-label',`关闭${title}`);header.append(heading,close);
  content.classList?.add('admin-proof-body');dialog.append(header,content);document.body.append(dialog);
  let disposed=false;function destroy(){if(disposed)return;disposed=true;dialog.remove();onClose();if(previous?.isConnected)previous.focus({preventScroll:true});}
  close.addEventListener('click',()=>{dialog.close();destroy();});dialog.addEventListener('close',destroy);
  dialog.addEventListener('click',event=>{if(event.target!==dialog)return;const r=dialog.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)dialog.close();});
  dialog.showModal();close.focus({preventScroll:true});return {dialog,close:()=>{if(dialog.open)dialog.close();destroy();}};
}
