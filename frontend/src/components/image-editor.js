import { StrictElement, button, element } from "./base.js";
import { icon } from "../icons/icons.js";

// Local canvas fixtures keep this demo independent of remote images and accounts.
function picture(index = 0) {
  const canvas = element("canvas");
  canvas.width = 720; canvas.height = 960;
  const ctx = canvas.getContext("2d");
  const palettes = [["#b8d5dd", "#537d83", "#d5c7af"], ["#e3cbb5", "#8a8990", "#d7b492"], ["#b9c9bd", "#527b6d", "#dfd7b9"]];
  const colors = palettes[index % palettes.length];
  const sky = ctx.createLinearGradient(0, 0, 0, 650);
  sky.addColorStop(0, colors[0]); sky.addColorStop(1, "#f0eee6");
  ctx.fillStyle = sky; ctx.fillRect(0, 0, 720, 960);
  ctx.fillStyle = "#fff5db"; ctx.beginPath(); ctx.arc(530, 235, 65, 0, Math.PI * 2); ctx.fill();
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
    const ctx = canvas.getContext("2d");
    ctx.drawImage(source, 0, 0);
    const history = [ctx.getImageData(0, 0, canvas.width, canvas.height)];
    let cursor = 0, tool = "brush", stroke = null, crop = null, busy = false;
    const header = element("header", "c-image-editor__header");
    const viewport = element("div", "c-image-editor__viewport");
    const footer = element("footer", "c-image-editor__footer");
    const tools = element("div", "c-image-editor__tools");
    const settings = element("div", "c-image-editor__settings");
    const status = element("p", "c-image-editor__status"); status.setAttribute("role", "status");
    const color = element("input"); color.type = "color"; color.value = "#ffffff"; color.setAttribute("aria-label", "画笔与文字颜色");
    const width = element("input"); width.type = "range"; width.min = "2"; width.max = "32"; width.value = "8"; width.setAttribute("aria-label", "画笔粗细");
    const text = element("input", "c-image-editor__text"); text.placeholder = "输入文字，再点击图片放置"; text.setAttribute("aria-label", "图片文字"); text.hidden = true;
    const emojis = element("select"); emojis.setAttribute("aria-label", "选择表情"); emojis.hidden = true;
    for (const value of ["🙂", "❤️", "✨", "🌈", "🌻"]) { const option = element("option", "", value); emojis.append(option); }
    const refresh = () => { undo.disabled = busy || cursor === 0; redo.disabled = busy || cursor === history.length - 1; done.disabled = busy; };
    const commit = () => { history.splice(cursor + 1); history.push(ctx.getImageData(0, 0, canvas.width, canvas.height)); cursor++; refresh(); };
    const restore = () => { const data = history[cursor]; canvas.width = data.width; canvas.height = data.height; ctx.putImageData(data, 0, 0); refresh(); };
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
    const choices = [["brush", "画笔", icon("edit")], ["emoji", "表情", icon("emoji")], ["text", "文字", "T"], ["crop", "裁剪", "⌗"], ["mosaic", "马赛克", "▦"]];
    for (const [id, label, glyph] of choices) {
      const item = control(label, () => {
        tool = id; text.hidden = id !== "text"; emojis.hidden = id !== "emoji";
        for (const node of tools.children) node.setAttribute("aria-pressed", String(node === item));
        status.textContent = id === "crop" ? "拖动选择保留区域" : id === "emoji" || id === "text" ? "点击图片放置" : "在图片上拖动绘制";
      }, glyph);
      item.setAttribute("aria-pressed", String(id === tool)); tools.append(item);
    }
    const point = (event) => { const rect = canvas.getBoundingClientRect(); return { x: Math.max(0, Math.min(canvas.width, (event.clientX - rect.left) * canvas.width / rect.width)), y: Math.max(0, Math.min(canvas.height, (event.clientY - rect.top) * canvas.height / rect.height)) }; };
    canvas.addEventListener("pointerdown", (event) => {
      if (busy || state === "loading" || state === "error") return;
      canvas.setPointerCapture(event.pointerId); stroke = point(event);
      if (tool === "crop") crop = ctx.getImageData(0, 0, canvas.width, canvas.height);
      if (tool === "text" || tool === "emoji") {
        const value = tool === "emoji" ? emojis.value : text.value.trim();
        if (!value) { status.textContent = "请先输入文字"; stroke = null; return; }
        ctx.font = `${tool === "emoji" ? 64 : 46}px sans-serif`; ctx.fillStyle = color.value; ctx.fillText(value, stroke.x, stroke.y); commit(); stroke = null;
      }
    });
    canvas.addEventListener("pointermove", (event) => {
      if (!stroke) return; const next = point(event);
      if (tool === "crop") { ctx.putImageData(crop, 0, 0); ctx.strokeStyle = color.value; ctx.lineWidth = 3; ctx.strokeRect(stroke.x, stroke.y, next.x - stroke.x, next.y - stroke.y); return; }
      if (tool === "mosaic") {
        const size = 28, x = Math.min(canvas.width - 1, Math.floor(next.x / size) * size), y = Math.min(canvas.height - 1, Math.floor(next.y / size) * size);
        const data = ctx.getImageData(x, y, 1, 1).data; ctx.fillStyle = `rgb(${data[0]} ${data[1]} ${data[2]})`; ctx.fillRect(x, y, size, size);
      } else { ctx.strokeStyle = color.value; ctx.lineWidth = Number(width.value); ctx.lineCap = "round"; ctx.beginPath(); ctx.moveTo(stroke.x, stroke.y); ctx.lineTo(next.x, next.y); ctx.stroke(); }
      stroke = next;
    });
    canvas.addEventListener("pointerup", (event) => {
      if (!stroke) return;
      if (tool === "crop") {
        const end = point(event), x = Math.floor(Math.min(stroke.x, end.x)), y = Math.floor(Math.min(stroke.y, end.y));
        const w = Math.floor(Math.abs(end.x - stroke.x)), h = Math.floor(Math.abs(end.y - stroke.y)); ctx.putImageData(crop, 0, 0);
        if (w > 8 && h > 8) { const data = ctx.getImageData(x, y, w, h); canvas.width = w; canvas.height = h; ctx.putImageData(data, 0, 0); }
      }
      stroke = null; crop = null; commit();
    });
    canvas.addEventListener("pointercancel", () => { stroke = null; crop = null; restore(); });
    settings.append(color, width, text, emojis); footer.append(settings, tools, done); viewport.append(canvas); root.append(header, viewport, status, footer); refresh();
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
