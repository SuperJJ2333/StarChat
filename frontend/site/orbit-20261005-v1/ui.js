const features = {
  connect: { kicker: 'CONVERSATION, WITHOUT DISTANCE', title: '一个入口，让对话无限延伸。', description: '文字、语音、视频。用此刻最自然的方式，靠近彼此。', nodes: ['私聊', '群聊', '语音', '视频'], label: '私聊、群聊、语音、视频围绕畅聊的连接关系图' },
  share: { kicker: 'LITTLE MOMENTS. SHARED TOGETHER.', title: '让日常的小事，成为共同的故事。', description: '照片、视频、朋友圈与评论。让分享成为另一种陪伴。', nodes: ['照片', '视频', '朋友圈', '评论'], label: '照片、视频、朋友圈、评论围绕畅聊的分享关系图' },
  privacy: { kicker: 'YOUR CONVERSATIONS. YOUR SPACE.', title: '每一次沟通，都有自己的边界。', description: '消息、附件与通话在设备端加密，私密连接自然发生。', nodes: ['消息', '附件', '语音通话', '视频通话'], label: '消息、附件、语音通话、视频通话的设备端加密关系图' }
};

function wireTabs(selector, onSelect) {
  const tabs = [...document.querySelectorAll(selector)];
  function select(tab) {
    tabs.forEach(item => { item.setAttribute('aria-selected', String(item === tab)); item.tabIndex = item === tab ? 0 : -1; });
    onSelect(tab);
  }
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => select(tab));
    tab.addEventListener('keydown', event => {
      const keys = { ArrowRight: (index + 1) % tabs.length, ArrowLeft: (index + tabs.length - 1) % tabs.length, Home: 0, End: tabs.length - 1 };
      if (!(event.key in keys)) return;
      event.preventDefault();
      const next = tabs[keys[event.key]];
      select(next); next.focus();
    });
  });
}

wireTabs('[data-feature]', tab => {
  const feature = features[tab.dataset.feature];
  document.querySelector('#feature-kicker').textContent = feature.kicker;
  document.querySelector('#feature-title').textContent = feature.title;
  document.querySelector('#feature-description').textContent = feature.description;
  document.querySelectorAll('[data-node]').forEach((node, index) => { node.textContent = feature.nodes[index]; });
  const diagram = document.querySelector('[data-diagram]');
  diagram.setAttribute('aria-label', feature.label);
  diagram.dataset.diagram = tab.dataset.feature;
  document.querySelector('#feature-panel').setAttribute('aria-labelledby', tab.id);
});
wireTabs('[data-platform]', tab => {
  document.querySelectorAll('.platform-panel').forEach(panel => { panel.hidden = panel.id !== `${tab.dataset.platform}-panel`; });
});
document.querySelector('#architecture')?.addEventListener('change', event => {
  const architecture = event.target.value;
  if (!['arm64', 'arm32', 'x86_64'].includes(architecture)) return;
  document.querySelector('#android-download').href = `https://www.liuhetong888.com/downloads/latest-${architecture}.apk`;
});
