import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

class Node {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.dataset = {};
    this.attributes = {};
    this.handlers = {};
    this.hidden = false;
    this.style = {};
    this.classList = { add: (...values) => { this.className = [this.className, ...values].filter(Boolean).join(' '); } };
  }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  removeAttribute(name) { delete this.attributes[name]; }
  addEventListener(name, handler) { this.handlers[name] = handler; }
  load() { this.loads = (this.loads ?? 0) + 1; }
  pause() { this.pauses = (this.pauses ?? 0) + 1; }
}
globalThis.HTMLElement = class {};
globalThis.document = { createElement: tag => new Node(tag), createElementNS: (_ns, tag) => new Node(tag) };
const { renderMediaVideoPreview } = await import('../src/screens/media-video-preview.js');
const { renderScreen: renderMessaging } = await import('../src/screens/messaging.js');
const { renderScreen: renderMoments } = await import('../src/screens/moments.js');
const walk = node => [node, ...node.children.flatMap(walk)];
const byClass = (root, value) => walk(root).find(node => node.className?.split(' ').includes(value));
const contexts = [{ module: 'chat', page: 'gallery-video' }, { module: 'chat', page: 'video-preview' }, { module: 'moments', page: 'video-preview' }];
const definition = (context, state) => ({ ...context, state, id: 'video-test', title: '视频预览', height: 'standard', theme: 'light' });

for (const context of contexts) {
  for (const state of ['loading', 'playing', 'failed']) {
    test(`${context.module}/${context.page}/${state} maps native preview without top capsule or toast`, () => {
      const root = renderMediaVideoPreview(definition(context, state));
      assert.ok(root.className.includes('p-media-video-preview'));
      assert.equal(root.dataset.state, state);
      assert.ok(!walk(root).some(node => node.tag === 'app-network-capsule' || node.tag === 'app-toast' || node.className?.split(' ').includes('ui-device')));
      const renderer = context.module === 'moments' ? renderMoments : renderMessaging;
      assert.ok(byClass(renderer(definition(context, state)), 'p-media-video-preview'), 'native page must use the shared renderer');
      assert.equal(Boolean(byClass(root, 'p-media-video-preview__select')), context.page === 'gallery-video');
      if (state === 'loading') {
        assert.ok(byClass(root, 'p-media-video-preview__spinner'));
        assert.equal(byClass(root, 'p-media-video-preview__status').attributes['aria-busy'], 'true');
      } else if (state === 'playing') {
        const video = walk(root).find(node => node.tag === 'video');
        assert.equal(video.controls, true);
        assert.equal(video.playsInline, true);
        assert.equal(video.muted, true);
        assert.equal(video.src, '/assets/demo-video-preview.mp4');
      } else assert.ok(byClass(root, 'p-media-video-preview__retry'));
    });
  }
}

test('failed preview retries through native canplay and stale media errors cannot replace retry', () => {
  const root = renderMediaVideoPreview(definition(contexts[1], 'playing'));
  const old = walk(root).find(node => node.tag === 'video');
  old.handlers.error();
  assert.equal(root.dataset.state, 'failed');
  byClass(root, 'p-media-video-preview__retry').handlers.click();
  assert.equal(root.dataset.state, 'loading');
  const current = walk(root).find(node => node.tag === 'video');
  assert.notEqual(current, old);
  assert.equal(old.pauses, 1);
  assert.equal(current.loads, 1);
  old.handlers.error();
  old.handlers.canplay();
  assert.equal(root.dataset.state, 'loading');
  current.handlers.canplay();
  assert.equal(root.dataset.state, 'playing');
  assert.equal(current.hidden, false);
  current.handlers.error();
  assert.equal(root.dataset.state, 'failed');
});

test('gallery selection remains available in loading and changes only its own selection state', () => {
  const root = renderMediaVideoPreview(definition(contexts[0], 'loading'));
  const select = byClass(root, 'p-media-video-preview__select');
  assert.equal(select.attributes['aria-pressed'], 'false');
  select.handlers.click();
  assert.equal(select.attributes['aria-pressed'], 'true');
  assert.equal(select.textContent, '已选择');
  select.handlers.click();
  assert.equal(select.attributes['aria-pressed'], 'false');
  assert.equal(root.dataset.state, 'loading');
});

test('video demo uses the approved synthetic clip without a user media dependency', () => {
  const bytes = readFileSync(new URL('../assets/demo-video-preview.mp4', import.meta.url));
  assert.equal(createHash('sha256').update(bytes).digest('hex'), '7a88d53f1efad3b135aeb9d19cf8b6ab960d5f7878353784fef963f66f283783');
});
