import { button, element } from '../components/base.js';
import { pageRoot } from './shared.js';

// Local synthetic media exercises the public HTML video controls only.
export function renderMediaVideoPreview(definition) {
  const root = pageRoot(definition);
  root.classList.add('p-media-video-preview');
  const media = element('div', 'p-media-video-preview__media');
  const status = element('div', 'p-media-video-preview__status');
  const controls = element('div', 'p-media-video-preview__controls');
  let video = null;
  let generation = 0;

  function showState(state) {
    root.dataset.state = state;
    status.hidden = state === 'playing';
    status.className = `p-media-video-preview__status${state === 'loading' ? ' p-media-video-preview__loading' : ''}`;
    status.setAttribute('role', state === 'failed' ? 'alert' : 'status');
    status.setAttribute('aria-busy', String(state === 'loading'));
    if (video) video.hidden = state !== 'playing';
    if (state === 'loading') {
      const spinner = element('span', 'p-media-video-preview__spinner');
      spinner.setAttribute('aria-hidden', 'true');
      status.replaceChildren(spinner, element('p', '', '正在加载视频…'));
    } else if (state === 'failed') {
      const retry = button('p-media-video-preview__retry', '重试');
      retry.textContent = '重试';
      retry.addEventListener('click', () => {
        createVideo(true);
        showState('loading');
        video.load();
      });
      status.replaceChildren(element('p', '', '视频加载失败，请重试'), retry);
    } else status.replaceChildren();
  }

  function createVideo(autoplay) {
    const attempt = ++generation;
    if (video) {
      video.pause();
      video.removeAttribute('src');
    }
    const next = element('video', 'p-media-video-preview__video');
    next.controls = true;
    next.playsInline = true;
    next.muted = true;
    next.autoplay = autoplay;
    next.preload = 'metadata';
    next.src = '/assets/demo-video-preview.mp4';
    next.setAttribute('aria-label', '视频预览');
    next.addEventListener('canplay', () => {
      if (attempt === generation && root.dataset.state === 'loading') showState('playing');
    });
    next.addEventListener('error', () => {
      if (attempt === generation) showState('failed');
    });
    video = next;
    media.replaceChildren(next);
  }

  if (definition.module === 'chat' && definition.page === 'gallery-video') {
    const select = button('p-media-video-preview__select', '选择');
    let selected = false;
    const updateSelection = () => {
      select.textContent = selected ? '已选择' : '选择';
      select.setAttribute('aria-pressed', String(selected));
      select.setAttribute('aria-label', select.textContent);
    };
    select.addEventListener('click', () => {
      selected = !selected;
      updateSelection();
    });
    updateSelection();
    controls.append(select);
  }

  const state = definition.state === 'loading' ? 'loading'
    : ['failed', 'error'].includes(definition.state) ? 'failed' : 'playing';
  if (state === 'playing') createVideo(definition.state === 'playing');
  showState(state);
  root.append(media, status, controls);
  return root;
}
