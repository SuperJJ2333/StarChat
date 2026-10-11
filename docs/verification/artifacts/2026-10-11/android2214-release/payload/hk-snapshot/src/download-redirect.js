import {installAndroidNetworkDownload} from './download-network.js';

const iosInstall = 'itms-services://?action=download-manifest&url=https://www.liuhetong888.com/downloads/ios/manifest.plist';

export function downloadDestination(search, device) {
  const query = new URLSearchParams(search);
  if (query.get('install') !== '1') return null;
  const ua = device.userAgent ?? '';
  const ios = /iPhone|iPad|iPod/i.test(ua) || (device.platform === 'MacIntel' && device.maxTouchPoints > 1);
  const platform = ios ? 'ios' : /Android/i.test(ua) ? 'android' : null;
  const requested = query.get('platform');
  if (!platform || (requested && requested !== platform)) return null;
  return platform === 'ios' ? iosInstall : '/downloads/latest-arm64.apk';
}

export function startDownload(location, device, status) {
  const target = downloadDestination(location.search, device);
  if (!target) return;
  if (target.startsWith('itms-services:')) {
    if (status) status.textContent = '本版更换企业签名团队。请先阅读下方提示，再点击“安装 iOS 正式版”。';
    return;
  }
  if (status) status.textContent = '正在打开安装入口。如未出现系统提示，请点击下方对应设备的安装按钮。';
  try { location.assign(target); } catch {
    if (status) status.textContent = '浏览器未能自动打开安装入口，请点击下方对应设备的安装按钮。';
  }
}

if (typeof window !== 'undefined') {
  const network=installAndroidNetworkDownload({document,location:window.location,device:window.navigator,
    autoStart:downloadDestination(window.location.search,window.navigator)==='/downloads/latest-arm64.apk'});
  if (!network) startDownload(window.location, window.navigator, document.getElementById('download-status'));
  else if (downloadDestination(window.location.search,window.navigator)?.startsWith('itms-services:'))
    startDownload(window.location, window.navigator, document.getElementById('download-status'));
}
