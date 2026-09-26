// itms-services 的 url= 参数里禁止携带查询串（?v=...）：部分 iOS 版本会
// 静默失败，点击安装毫无反应（2026-09-24 实测）。防缓存靠 manifest 的
// no-store 响应头即可；若未来真需要按版本区分，用独立文件名而不是查询串。
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
  if (status) status.textContent = '正在打开安装入口。如未出现系统提示，请点击下方对应设备的安装按钮。';
  try { location.assign(target); } catch {
    if (status) status.textContent = '浏览器未能自动打开安装入口，请点击下方对应设备的安装按钮。';
  }
}

if (typeof window !== 'undefined') {
  startDownload(window.location, window.navigator, document.getElementById('download-status'));
}
