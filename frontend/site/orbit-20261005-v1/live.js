const query=new URLSearchParams(location.search);
const ios=/iPhone|iPad|iPod/i.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);
const requested=query.get('platform');
const platform=requested==='ios'||requested!=='android'&&ios?'ios':'android';
document.querySelector(`#platform-${platform}`)?.click();
const select=document.querySelector('#architecture');
const main=document.querySelector('#android-network-download');
const other=document.querySelector('#android-download');
const backup=document.querySelector('#android-direct-download');
const exactBackup=backup.getAttribute('href');
select.addEventListener('change',()=>{
  const value=select.value;
  if(!['arm64','arm32','x86_64'].includes(value))return;
  main.hidden=value!=='arm64';other.hidden=value==='arm64';
  other.href=`/downloads/latest-${value}.apk`;
  backup.href=value==='arm64'?exactBackup:`/downloads/latest-${value}.apk`;
});
new MutationObserver(()=>{select.disabled=main.getAttribute('aria-busy')==='true';}).observe(main,{attributes:true,attributeFilter:['aria-busy']});
