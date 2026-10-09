import * as THREE from './vendor/three.module.js';

// The field is an abstract illustration, never a live user or telemetry map.
document.querySelectorAll('[data-scene]').forEach(mount => {
  let renderer;
  try { renderer = new THREE.WebGLRenderer({ alpha: true, antialias: window.innerWidth > 760, powerPreference: 'low-power' }); }
  catch { return; } // CSS orbital illustration remains visible when WebGL is unavailable.
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(36, 1, .1, 100);
  camera.position.set(0, 0, 8.7);
  const field = new THREE.Group();
  scene.add(field);
  const isDownload = mount.dataset.scene === 'download';
  const mobile = matchMedia('(max-width: 760px)').matches;
  const radius = isDownload ? 1.78 : 1.83;
  const count = mobile ? 240 : 460;
  const positions = [];
  const points = [];
  const colors = [];
  const mint = new THREE.Color('#a9f6ce');
  const blue = new THREE.Color('#7faafa');
  // Deterministic Fibonacci distribution keeps the composition coherent on reload.
  for (let i = 0; i < count; i++) {
    const y = 1 - (i / (count - 1)) * 2;
    const theta = i * Math.PI * (3 - Math.sqrt(5));
    const r = Math.sqrt(1 - y * y);
    const point = new THREE.Vector3(Math.cos(theta) * r, y, Math.sin(theta) * r).multiplyScalar(radius);
    points.push(point); positions.push(point.x, point.y, point.z);
    const color = mint.clone().lerp(blue, (Math.sin(theta) + 1) * .28);
    colors.push(color.r, color.g, color.b);
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geometry.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));
  field.add(new THREE.Points(geometry, new THREE.PointsMaterial({ size: mobile ? .024 : .018, vertexColors: true, transparent: true, opacity: .85, blending: THREE.AdditiveBlending, depthWrite: false })));
  const lines = [];
  const threshold = mobile ? .48 : .39;
  points.forEach((point, i) => {
    for (let j = i + 1; j < points.length; j++) {
      if (point.distanceTo(points[j]) < threshold) lines.push(point.x, point.y, point.z, points[j].x, points[j].y, points[j].z);
    }
  });
  const lineGeometry = new THREE.BufferGeometry();
  lineGeometry.setAttribute('position', new THREE.Float32BufferAttribute(lines, 3));
  field.add(new THREE.LineSegments(lineGeometry, new THREE.LineBasicMaterial({ color: '#73cbaa', transparent: true, opacity: isDownload ? .12 : .19 })));
  const rings = [];
  for (let i = 0; i < 3; i++) {
    const ring = new THREE.Mesh(new THREE.TorusGeometry(radius + .3 + i * .19, .005, 5, mobile ? 100 : 180), new THREE.MeshBasicMaterial({ color: i === 1 ? '#83a9e8' : '#b4f8d0', transparent: true, opacity: i === 1 ? .4 : .65 }));
    ring.rotation.set(.8 + i * .56, i * .8, .3 + i * .7);
    field.add(ring); rings.push(ring);
    const satellite = new THREE.Mesh(new THREE.SphereGeometry(.035, 8, 8), new THREE.MeshBasicMaterial({ color: i === 1 ? blue : mint }));
    satellite.position.x = radius + .3 + i * .19;
    ring.add(satellite);
  }
  const starPositions = [];
  for (let i = 0; i < 70; i++) starPositions.push(Math.sin(i * 97.2) * 4.7, Math.cos(i * 51.1) * 3.1, -1.6);
  const starGeometry = new THREE.BufferGeometry();
  starGeometry.setAttribute('position', new THREE.Float32BufferAttribute(starPositions, 3));
  scene.add(new THREE.Points(starGeometry, new THREE.PointsMaterial({ color: '#8fbcac', size: .014, transparent: true, opacity: .38 })));
  field.rotation.set(.15, .3, -.26);
  if (isDownload) field.scale.setScalar(1.04);
  renderer.setClearColor(0x000000, 0);
  renderer.setPixelRatio(Math.min(devicePixelRatio, mobile ? 1.5 : 2));
  mount.prepend(renderer.domElement);
  renderer.domElement.setAttribute('aria-hidden', 'true');
  let visible = false, frame = 0, lastTime = 0, elapsed = 0, lost = false, disposed = false;
  const pointer = { x: 0, y: 0 };
  function draw(time = 0) {
    frame = 0;
    if (disposed || lost) return;
    if (lastTime) elapsed += Math.min((time - lastTime) / 1000, .05);
    lastTime = time;
    if (!reducedMotion.matches) {
      field.rotation.y = .3 + elapsed * .055 + pointer.x * .15;
      field.rotation.x += (.15 + pointer.y * .09 - field.rotation.x) * .04;
      rings.forEach((ring, index) => { ring.rotation.z = .3 + index * .7 + elapsed * (index % 2 ? -.08 : .06); });
    }
    renderer.render(scene, camera);
    mount.classList.add('scene-ready');
    if (visible && !document.hidden && !reducedMotion.matches) frame = requestAnimationFrame(draw);
  }
  function sync() {
    cancelAnimationFrame(frame); frame = 0; lastTime = 0;
    if (visible && !document.hidden && !lost && !disposed) draw();
  }
  const resize = new ResizeObserver(() => {
    const width = mount.clientWidth, height = mount.clientHeight;
    if (!width || !height || disposed) return;
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
    renderer.setSize(width, height, false);
    sync();
  });
  resize.observe(mount);
  const observer = new IntersectionObserver(entries => { visible = entries[0].isIntersecting; sync(); });
  observer.observe(mount);
  function move(event) {
    if (event.pointerType !== 'mouse' || reducedMotion.matches) return;
    const rect = mount.getBoundingClientRect();
    pointer.x = (event.clientX - rect.left) / rect.width - .5;
    pointer.y = (event.clientY - rect.top) / rect.height - .5;
  }
  mount.addEventListener('pointermove', move);
  document.addEventListener('visibilitychange', sync);
  reducedMotion.addEventListener('change', sync);
  renderer.domElement.addEventListener('webglcontextlost', event => { event.preventDefault(); lost = true; cancelAnimationFrame(frame); mount.classList.remove('scene-ready'); });
  renderer.domElement.addEventListener('webglcontextrestored', () => { lost = false; sync(); });
  addEventListener('pagehide', event => {
    if (event.persisted) return;
    disposed = true; cancelAnimationFrame(frame); resize.disconnect(); observer.disconnect();
    mount.removeEventListener('pointermove', move); document.removeEventListener('visibilitychange', sync); reducedMotion.removeEventListener('change', sync);
    scene.traverse(object => { object.geometry?.dispose(); if (object.material) object.material.dispose(); });
    renderer.dispose();
  });
});
