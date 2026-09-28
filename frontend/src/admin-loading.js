export function adminLoadingView() {
  const view=document.createElement('main');
  view.className='admin-loading';
  view.setAttribute('role','status');
  view.setAttribute('aria-live','polite');
  const emblem=document.createElement('div');emblem.className='admin-loading-emblem';
  const icon=document.createElement('img');icon.src='/assets/branding/admin-logo.png';icon.alt='畅聊';
  const spinner=document.createElement('span');spinner.className='admin-loading-spinner';spinner.setAttribute('aria-hidden','true');
  emblem.append(icon,spinner);
  const message=document.createElement('p');message.textContent='正在加载管理台';
  const detail=document.createElement('small');detail.textContent='正在核对管理会话与权限';
  view.append(emblem,message,detail);
  return view;
}
