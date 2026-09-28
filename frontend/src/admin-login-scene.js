// Decorative 2D scene. The form and its validation never depend on canvas.
export function startLoginScene(canvas) {
  const reduced = globalThis.matchMedia?.('(prefers-reduced-motion: reduce)');
  if (reduced?.matches || typeof globalThis.requestAnimationFrame !== 'function') return () => {};
  const context = canvas.getContext?.('2d');
  if (!context) return () => {};
  const cssColor = name => globalThis.getComputedStyle?.(canvas).getPropertyValue(name).trim() || 'transparent';
  const colors = {
    orbit: cssColor('--admin-login-color-rgba-172-239-247-19'),
    beamClear: cssColor('--admin-login-color-rgba-156-228-243-0'),
    beamCore: cssColor('--admin-login-color-rgba-195-249-255-48'),
    star: cssColor('--admin-login-scene-star')
  };
  const stars = Array.from({length:42},(_,index)=>({
    x:(index * 0.61803398875) % 1,
    y:(index * 0.38196601125 + 0.17) % 1,
    size:index % 7 === 0 ? 1.6 : 0.8,
    phase:index * 0.73
  }));
  let frame = 0, stopped = false, last = 0, width = 0, height = 0, scale = 1;
  function resize() {
    const nextWidth = Math.max(1, Math.floor(canvas.clientWidth));
    const nextHeight = Math.max(1, Math.floor(canvas.clientHeight));
    const nextScale = Math.min(2, globalThis.devicePixelRatio || 1);
    if (width === nextWidth && height === nextHeight && scale === nextScale) return;
    width = nextWidth; height = nextHeight; scale = nextScale;
    canvas.width = Math.floor(width * scale); canvas.height = Math.floor(height * scale);
    context.setTransform(scale,0,0,scale,0,0);
  }
  function stop() {
    stopped = true;
    if (frame) globalThis.cancelAnimationFrame?.(frame);
    globalThis.removeEventListener?.('pagehide', stop);
    reduced?.removeEventListener?.('change', onMotionChange);
  }
  function onMotionChange() {if (reduced?.matches) stop();}
  function draw(time) {
    if (stopped) return;
    if (!canvas.isConnected) {stop();return;}
    frame = globalThis.requestAnimationFrame(draw);
    if (globalThis.document?.hidden || time - last < 33) return;
    last = time; resize(); context.clearRect(0,0,width,height);
    const seconds = time / 1000;
    context.lineWidth = 1;
    context.strokeStyle = colors.orbit;
    for (const fraction of [0.26,0.35,0.45]) {
      context.beginPath();
      context.arc(width*.80,height*.52,Math.min(width,height)*fraction,-2.4,1.7);
      context.stroke();
    }
    const beam = context.createLinearGradient(width*.38,height*.84,width*.98,height*.12);
    beam.addColorStop(0,colors.beamClear);
    beam.addColorStop(.5,colors.beamCore);
    beam.addColorStop(1,colors.beamClear);
    context.strokeStyle = beam; context.lineWidth = 1.5;
    context.beginPath();context.moveTo(width*.38,height*.84);context.lineTo(width*.98,height*.12);context.stroke();
    for (const star of stars) {
      const alpha = .18 + .25 * (1 + Math.sin(seconds * 1.1 + star.phase)) / 2;
      context.fillStyle = colors.star;
      context.globalAlpha = alpha;
      context.beginPath();context.arc(star.x*width,star.y*height,star.size,0,Math.PI*2);context.fill();
    }
    context.globalAlpha = 1;
  }
  reduced?.addEventListener?.('change', onMotionChange);
  globalThis.addEventListener?.('pagehide', stop);
  frame = globalThis.requestAnimationFrame(draw);
  return stop;
}
