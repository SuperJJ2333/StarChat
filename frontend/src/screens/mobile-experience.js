import { button, element } from '../components/base.js';
import { component, navigation, pageRoot } from './shared.js';

// Synthetic local fixtures. These controls model client transitions, never APNs
// delivery or a real upload. Keep them separate from production gateways.
export function mobileExperienceDemo(definition) {
  const title=definition.state==='notification-permission'?'消息提醒':definition.state==='cached-start'?'消息':'周然';
  const root=pageRoot(definition, [navigation(title, definition.state==='cached-start'?{}:{leading:'返回'})]);
  root.dataset.demoSource='local-fixture';
  root.className+=' p-mobile-experience';
  const content=element('div','p-mobile-experience__content');
  const status=element('p','p-mobile-experience__status');
  status.setAttribute('role','status');
  const actions=element('div','p-mobile-experience__actions');
  const action=(id,label,callback)=>{
    const node=button('p-mobile-experience__action',label);
    node.textContent=label; node.dataset.control=id;
    node.addEventListener('click',callback); actions.append(node);
  };
  root.append(content,status,actions);
  if (definition.state==='notification-permission') {
    const draw=phase=>{
      root.dataset.phase=phase; actions.replaceChildren();
      const copy={explanation:'开启通知，及时接收消息提醒。声音和弹窗还受系统设置影响。',deferred:'暂未开启通知，你可以稍后主动开启。',requesting:'正在等待系统授权结果…',denied:'通知已关闭，请在系统设置中开启。',settings:'从系统设置返回后刷新通知状态。',granted:'通知权限已开启；弹窗、声音与角标以系统设置为准。'};
      status.textContent=copy[phase];
      if (['explanation','deferred'].includes(phase)) {
        action('request','开启通知',()=>draw('requesting'));
        if (phase==='explanation') action('defer','稍后再说',()=>draw('deferred'));
      } else if (phase==='requesting') {
        action('grant','模拟系统允许',()=>draw('granted'));
        action('deny','模拟系统拒绝',()=>draw('denied'));
      } else if (phase==='denied') action('settings','打开系统设置',()=>draw('settings'));
      else if (phase==='settings') {
        action('grant','模拟返回：已开启',()=>draw('granted'));
        action('deny','模拟返回：仍关闭',()=>draw('denied'));
      }
    };
    content.append(element('h2','','接收新消息通知'));
    draw('explanation'); return root;
  }
  if (definition.state==='static-emoji') {
    const emoji=element('span','p-mobile-experience__emoji','😄');
    emoji.setAttribute('role','img'); emoji.setAttribute('aria-label','开心表情'); content.append(emoji);
    const draw=playing=>{
      root.dataset.phase=playing?'playing':'static';
      emoji.dataset.playing=String(playing);
      status.textContent=playing?'点击停止播放':'表情静态预览 · 点击播放';
      actions.replaceChildren();
      action(playing?'stop':'play',playing?'停止播放':'播放表情',()=>draw(!playing));
    };
    draw(false); return root;
  }
  if (definition.state==='outgoing-media') {
    root.dataset.transactionId='demo-local-1';
    const card=element('figure','p-mobile-experience__media');
    const preview=element('img'); preview.dataset.control='preview';
    preview.setAttribute('src','/assets/moment-video-poster.svg');
    preview.setAttribute('alt','已选视频的本地首帧');
    const spinner=element('span','p-mobile-experience__spinner');
    spinner.dataset.control='progress'; spinner.setAttribute('aria-hidden','true');
    const progress=element('figcaption'); card.append(preview,spinner,progress); content.append(card);
    const draw=phase=>{
      root.dataset.phase=phase; actions.replaceChildren();
      const labels={preparing:'正在准备视频…',uploading:'正在发送 · 48%',failed:'发送失败',sent:'已发送',cancelled:'已取消'};
      progress.textContent=labels[phase];
      spinner.hidden=!['preparing','uploading'].includes(phase);
      card.setAttribute('aria-busy',String(['preparing','uploading'].includes(phase)));
      status.textContent=phase==='failed'?'预览已保留，可以重试或取消。':'';
      if (phase==='failed') action('retry','重试',()=>draw('uploading'));
      if (['preparing','uploading'].includes(phase)) {
        action('complete','模拟上传与确认完成',()=>draw('sent'));
        action('fail','模拟网络中断',()=>draw('failed'));
      }
      if (!['sent','cancelled'].includes(phase)) action('cancel','取消发送',()=>draw('cancelled'));
    };
    draw('preparing'); return root;
  }
  const history=definition.state==='recent-history';
  const rows=element('div','p-mobile-experience__rows');
  for (const [index,text] of ['这周末一起去海边吧。','好，照片我发给你。','收到，明天见！'].entries()) {
    const row=element('div',history?'':'c-conversation-row');
    row.dataset.cachedMessage=String(index+1);
    if (history) row.append(component('app-message-bubble',{content:text,direction:index===1?'outgoing':'incoming',delivery:'sent',sender:index===1?'我':'周然'}));
    else {
      const name=['周然','徒步群','林夕'][index];
      const body=element('div','c-conversation-row__body');
      body.append(element('h2','c-conversation-row__title',name),element('p','c-conversation-row__preview',text));
      row.append(component('app-avatar',{name,size:'conversation'}),body,element('time','c-conversation-row__time','09:41'));
    }
    rows.append(row);
  }
  content.append(rows);
  const draw=phase=>{
    root.dataset.phase=phase; actions.replaceChildren();
    status.textContent=phase==='ready'?'':phase==='failed'?'连接暂不可用，本地内容仍可浏览。':history?'正在补齐更早的消息…':'正在连接…';
    if (phase==='failed') action('retry','重试',()=>draw('loading'));
    if (phase==='loading') {
      action('complete','模拟同步完成',()=>draw('ready'));
      action('fail','模拟离线',()=>draw('failed'));
    }
  };
  draw('loading');
  if (history) root.append(component('app-composer',{mode:'text'}));
  return root;
}
