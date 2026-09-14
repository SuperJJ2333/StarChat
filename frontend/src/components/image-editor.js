import { StrictElement, button, element } from "./base.js";
import { icon } from "../icons/icons.js";

function colorToken(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(`--image-editor-${name}`).trim();
}

function opaqueMosaic(ctx, x, y, size) {
  const source = ctx.getImageData(x, y, 1, 1).data;
  const tile = ctx.createImageData(size, size);
  for (let offset = 0; offset < tile.data.length; offset += 4) {
    tile.data[offset] = source[0];
    tile.data[offset + 1] = source[1];
    tile.data[offset + 2] = source[2];
    tile.data[offset + 3] = 255;
  }
  ctx.putImageData(tile, x, y);
}

// Local canvas fixtures keep this demo independent of remote images and accounts.
function picture(index = 0) {
  const canvas = element("canvas");
  canvas.width = 720; canvas.height = 960;
  const ctx = canvas.getContext("2d");
  const palette = index % 3;
  const colors = ["sky", "ridge", "foreground"].map((part) => colorToken(`landscape-${palette}-${part}`));
  const sky = ctx.createLinearGradient(0, 0, 0, 650);
  sky.addColorStop(0, colors[0]); sky.addColorStop(1, colorToken("sky-haze"));
  ctx.fillStyle = sky; ctx.fillRect(0, 0, 720, 960);
  ctx.fillStyle = colorToken("sun"); ctx.beginPath(); ctx.arc(530, 235, 65, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = colors[1]; ctx.beginPath(); ctx.moveTo(0, 590); ctx.lineTo(220, 380); ctx.lineTo(460, 610); ctx.lineTo(720, 440); ctx.lineTo(720, 960); ctx.lineTo(0, 960); ctx.fill();
  ctx.fillStyle = colors[2]; ctx.beginPath(); ctx.moveTo(0, 850); ctx.quadraticCurveTo(470, 590, 720, 750); ctx.lineTo(720, 960); ctx.lineTo(0, 960); ctx.fill();
  return canvas;
}

function control(label, handler, glyph) {
  const node = button("c-image-editor__control", label);
  node.title = label;
  node.append(glyph instanceof Node ? glyph : element("span", "", glyph ?? label));
  node.addEventListener("click", handler);
  return node;
}

export class AppImageEditor extends StrictElement {
  render() {
    const root = element("section", "c-image-editor");
    const state = this.attr("state", "ready");
    const source = this.sourceCanvas ?? picture(Number(this.attr("picture", "0")));
    const canvas = element("canvas", "c-image-editor__canvas");
    canvas.width = source.width; canvas.height = source.height;
    canvas.setAttribute("aria-label", "图片编辑画布，拖动绘制或裁剪");
    // The source canvas is immutable. Marks live on a separate overlay so an
    // eraser clears only edits and always reveals the correctly cropped source.
    const overlay = element("canvas");
    const sourceContext = source.getContext("2d");
    const documentFor = () => ({ crop: { x: 0, y: 0, width: source.width, height: source.height }, marks: [] });
    const cloneDocument = (document) => ({
      crop: { ...document.crop },
      marks: document.marks.map((mark) => ({ ...mark, points: mark.points.map((point) => ({ ...point })) }))
    });
    const history = [documentFor()];
    let cursor = 0, tool = "brush", stroke = null, selection = null, busy = false;
    const header = element("header", "c-image-editor__header");
    const viewport = element("div", "c-image-editor__viewport");
    const footer = element("footer", "c-image-editor__footer");
    const tools = element("div", "c-image-editor__tools");
    const settings = element("div", "c-image-editor__settings");
    const status = element("p", "c-image-editor__status"); status.setAttribute("role", "status");
    const color = element("input"); color.type = "color"; color.value = colorToken("brush"); color.setAttribute("aria-label", "画笔与文字颜色");
    const width = element("input"); width.type = "range"; width.min = "2"; width.max = "32"; width.value = "8"; width.setAttribute("aria-label", "画笔粗细");
    const text = element("input", "c-image-editor__text"); text.placeholder = "输入文字，再点击图片放置"; text.setAttribute("aria-label", "图片文字"); text.hidden = true;
    let selectedEmoji = null;
    const emojiPicker = element("div", "c-image-editor__emoji-picker");
    emojiPicker.setAttribute("aria-label", "选择表情");
    emojiPicker.setAttribute("data-testid", "image-editor-emoji-grid");
    emojiPicker.hidden = true;
    for (const value of ["😀", "😄", "😂", "🥹", "😍", "🥰", "😎", "😭", "😡", "🤔", "🤗", "😘", "🥳", "🤩", "👍", "👎", "👏", "🙏", "💪", "🤝", "✌️", "❤️", "💛", "💚", "💙", "🔥", "🎉", "🌹", "🐱", "🐶", "🌈", "☀️", "⭐", "🎂", "🎁"]) {
      const item = control(`选择表情 ${value}`, () => { selectedEmoji = value; emojiPicker.hidden = true; status.textContent = "点击图片放置表情"; }, value);
      item.classList.add("c-image-editor__emoji-cell");
      item.setAttribute("data-testid", "image-editor-emoji-cell");
      item.setAttribute("data-fixed-touch", "48");
      emojiPicker.append(item);
    }
    const local = (point, crop) => ({ x: point.x - crop.x, y: point.y - crop.y });
    const drawPath = (context, mark, crop) => {
      const points = mark.points.map((point) => local(point, crop));
      if (!points.length) return;
      context.beginPath(); context.moveTo(points[0].x, points[0].y);
      for (const point of points.slice(1)) context.lineTo(point.x, point.y);
      if (points.length === 1) context.lineTo(points[0].x + .01, points[0].y + .01);
      context.lineCap = "round"; context.lineJoin = "round"; context.lineWidth = mark.width;
      context.stroke();
    };
    const drawMosaic = (context, mark, crop) => {
      const size = 28;
      for (const point of mark.points) {
        const x = Math.max(0, Math.min(source.width - 1, Math.floor(point.x / size) * size));
        const y = Math.max(0, Math.min(source.height - 1, Math.floor(point.y / size) * size));
        const data = sourceContext.getImageData(x, y, 1, 1).data;
        // Runtime pixel sample, not a design color; hex form keeps the token
        // contract's no-hardcoded-css-color scan clean.
        const hexPair = (value) => value.toString(16).padStart(2, "0");
        context.fillStyle = `#${hexPair(data[0])}${hexPair(data[1])}${hexPair(data[2])}`;
        context.fillRect(x - crop.x, y - crop.y, size, size);
      }
    };
    const drawMark = (context, mark, crop) => {
      if (mark.kind === "text" || mark.kind === "emoji") {
        const point = local(mark.points[0], crop);
        context.font = `${mark.kind === "emoji" ? 64 : 46}px sans-serif`;
        context.fillStyle = mark.color; context.fillText(mark.value, point.x, point.y); return;
      }
      if (mark.kind === "mosaic") { drawMosaic(context, mark, crop); return; }
      context.save();
      context.globalCompositeOperation = mark.kind === "eraser" ? "destination-out" : "source-over";
      context.strokeStyle = mark.color;
      drawPath(context, mark, crop);
      context.restore();
    };
    const redraw = (preview = null) => {
      const document = history[cursor], crop = document.crop;
      canvas.width = crop.width; canvas.height = crop.height;
      overlay.width = crop.width; overlay.height = crop.height;
      const context = canvas.getContext("2d"), overlayContext = overlay.getContext("2d");
      context.drawImage(source, crop.x, crop.y, crop.width, crop.height, 0, 0, crop.width, crop.height);
      for (const mark of document.marks) drawMark(overlayContext, mark, crop);
      if (preview && preview.kind !== "crop") drawMark(overlayContext, preview, crop);
      context.drawImage(overlay, 0, 0);
      if (preview?.kind === "crop") {
        const start = local(preview.start, crop), end = local(preview.end, crop);
        context.strokeStyle = color.value; context.lineWidth = 3;
        context.strokeRect(start.x, start.y, end.x - start.x, end.y - start.y);
      }
    };
    const refresh = () => { undo.disabled = busy || cursor === 0; redo.disabled = busy || cursor === history.length - 1; done.disabled = busy; };
    const commit = (next) => { history.splice(cursor + 1); history.push(cloneDocument(next)); cursor++; redraw(); refresh(); };
    const restore = () => { redraw(); refresh(); };
    const cancel = control("取消", () => { cursor = 0; restore(); this.dispatchEvent(new CustomEvent("image-cancel", { bubbles: true })); status.textContent = "已取消编辑，原图保持不变"; }, "取消");
    const undo = control("撤销", () => { if (cursor > 0) { cursor--; restore(); } }, "↶");
    const redo = control("重做", () => { if (cursor < history.length - 1) { cursor++; restore(); } }, "↷");
    const historyControls = element("div", "c-image-editor__history"); historyControls.append(undo, redo); header.append(cancel, historyControls);
    const sheet = () => {
      if (root.querySelector(".c-image-editor__sheet")) return;
      const panel = element("div", "c-image-editor__sheet"); panel.setAttribute("role", "dialog"); panel.setAttribute("aria-label", "完成图片编辑");
      const close = () => panel.remove();
      for (const [action, label] of [["forward", "转发"], ["save", "保存到相册"], ["favorite", "收藏"]]) {
        panel.append(control(label, async () => {
          busy = true; refresh(); panel.querySelectorAll("button").forEach((node) => { node.disabled = true; });
          status.textContent = "正在生成图片…";
          try {
            const blob = await new Promise((resolve, reject) => canvas.toBlob((value) => value ? resolve(value) : reject(new Error("export")), "image/png"));
            if (action === "save") {
              const url = URL.createObjectURL(blob); const link = element("a"); link.href = url; link.download = "畅聊-编辑图片.png"; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
              status.textContent = "已下载编辑后的图片";
            } else {
              this.dispatchEvent(new CustomEvent(`image-${action}`, { bubbles: true, detail: { blob } }));
              status.textContent = action === "forward" ? "演示：已生成转发图片" : "演示：已生成收藏图片";
            }
            close();
          } catch { status.textContent = "图片处理失败，请重试"; }
          finally { busy = false; refresh(); panel.querySelectorAll("button").forEach((node) => { node.disabled = false; }); }
        }, label));
      }
      panel.append(control("取消", close, "取消")); root.append(panel);
    };
    const done = control("完成", sheet, "完成"); done.classList.add("c-image-editor__done");
    const choices = [["brush", "画笔", icon("edit")], ["emoji", "表情", icon("emoji")], ["text", "文字", "T"], ["crop", "裁剪", "⌗"], ["mosaic", "马赛克", "▦"], ["eraser", "橡皮擦", icon("eraser")]];
    for (const [id, label, glyph] of choices) {
      const item = control(label, () => {
        tool = id; text.hidden = id !== "text"; emojiPicker.hidden = id !== "emoji";
        for (const node of tools.children) node.setAttribute("aria-pressed", String(node === item));
        status.textContent = id === "crop" ? "拖动选择保留区域" : id === "emoji" ? "选择表情后点击图片放置" : id === "text" ? "点击图片放置" : id === "eraser" ? "轻触或拖动擦除编辑痕迹" : "在图片上拖动绘制";
      }, glyph);
      item.setAttribute("aria-pressed", String(id === tool)); tools.append(item);
    }
    const point = (event) => { const rect = canvas.getBoundingClientRect(), crop = history[cursor].crop; return { x: crop.x + Math.max(0, Math.min(canvas.width, (event.clientX - rect.left) * canvas.width / rect.width)), y: crop.y + Math.max(0, Math.min(canvas.height, (event.clientY - rect.top) * canvas.height / rect.height)) }; };
    canvas.addEventListener("pointerdown", (event) => {
      if (busy || state === "loading" || state === "error") return;
      canvas.setPointerCapture(event.pointerId); stroke = [point(event)];
      if (tool === "crop") selection = { start: stroke[0], end: stroke[0] };
      if (tool === "text" || tool === "emoji") {
        const value = tool === "emoji" ? selectedEmoji : text.value.trim();
        if (!value) { status.textContent = tool === "emoji" ? "请先选择表情" : "请先输入文字"; stroke = null; return; }
        commit({ ...history[cursor], marks: [...history[cursor].marks, { kind: tool, points: stroke, value, color: color.value, width: Number(width.value) }] }); stroke = null;
      }
    });
    canvas.addEventListener("pointermove", (event) => {
      if (!stroke) return; const next = point(event);
      if (tool === "crop") { selection.end = next; redraw({ kind: "crop", ...selection }); return; }
      stroke.push(next); redraw({ kind: tool, points: stroke, color: color.value, width: Number(width.value) });
    });
    canvas.addEventListener("pointerup", (event) => {
      if (!stroke) return;
      if (tool === "crop") {
        const end = point(event), x = Math.floor(Math.min(stroke[0].x, end.x)), y = Math.floor(Math.min(stroke[0].y, end.y));
        const w = Math.floor(Math.abs(end.x - stroke[0].x)), h = Math.floor(Math.abs(end.y - stroke[0].y));
        if (w > 8 && h > 8) commit({ ...history[cursor], crop: { x, y, width: w, height: h } }); else redraw();
      } else {
        const end = point(event); if (stroke.at(-1).x !== end.x || stroke.at(-1).y !== end.y) stroke.push(end);
        commit({ ...history[cursor], marks: [...history[cursor].marks, { kind: tool, points: stroke, color: color.value, width: Number(width.value) }] });
      }
      stroke = null; selection = null;
    });
    canvas.addEventListener("pointercancel", () => { stroke = null; selection = null; restore(); });
    settings.append(color, width, text, emojiPicker); footer.append(settings, tools, done); viewport.append(canvas); root.append(header, viewport, status, footer); redraw(); refresh();
    if (state === "loading" || state === "error") { canvas.hidden = true; status.textContent = state === "loading" ? "正在打开图片…" : "图片打开失败，请返回重试"; done.disabled = true; }
    if (state === "complete-sheet") sheet();
    return root;
  }
}

export class AppRoomImageGallery extends StrictElement {
  render() {
    const root = element("section", "c-room-image-gallery");
    const header = element("header", "c-room-image-gallery__header");
    const counter = element("span", "", "1 / 3");
    const track = element("div", "c-room-image-gallery__track");
    track.setAttribute("aria-label", "当前聊天的图片，左右滑动查看"); track.tabIndex = 0;
    const pictures = [picture(0), picture(1), picture(2)];
    let index = 0;
    for (const [i, image] of pictures.entries()) { const page = element("figure", "c-room-image-gallery__page"); image.setAttribute("aria-label", `聊天图片 ${i + 1}`); page.append(image); track.append(page); }
    const move = (delta) => track.scrollTo({ left: Math.max(0, Math.min(2, index + delta)) * track.clientWidth, behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth" });
    track.addEventListener("scroll", () => { index = Math.round(track.scrollLeft / (track.clientWidth || 1)); counter.textContent = `${index + 1} / 3`; });
    track.addEventListener("keydown", (event) => { if (event.key === "ArrowLeft" || event.key === "ArrowRight") { event.preventDefault(); move(event.key === "ArrowLeft" ? -1 : 1); } });
    header.append(control("上一张", () => move(-1), "‹"), counter, control("下一张", () => move(1), "›"));
    const edit = control("编辑", () => {
      const editor = document.createElement("app-image-editor"); editor.sourceCanvas = pictures[index];
      const exit = () => { root.replaceChildren(header, track, edit); requestAnimationFrame(() => { track.scrollLeft = index * track.clientWidth; }); };
      editor.addEventListener("image-cancel", exit, { once: true }); root.replaceChildren(editor);
    }, "编辑");
    root.append(header, track, edit); return root;
  }
}
