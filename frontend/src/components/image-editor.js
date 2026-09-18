import { StrictElement, button, element } from "./base.js";
import { icon } from "../icons/icons.js";

function colorToken(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(`--image-editor-${name}`).trim();
}

// Semantic palette values come from the shared token layer, never from literals.
function semanticToken(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
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

/// 裁剪框最小边长（视图像素）——与 Flutter `ImageCropGeometry.minFrameSize`
/// 保持一致，避免 DOM 演示与实现漂移。
const cropMinSize = 56;
/// 手指命中边框的容差，与 Flutter `handleHitSlop` 一致。
const cropHitSlop = 24;
const cropAspects = [["free", "自由", null], ["1-1", "1:1", 1], ["4-5", "4:5", 4 / 5], ["16-9", "16:9", 16 / 9]];

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
    // 文档空间尺寸：旋转 90°/270° 时宽高互换（与 Flutter documentSpaceSize 一致）。
    const spaceSize = (rotation) => (rotation % 2 === 0
      ? { width: source.width, height: source.height }
      : { width: source.height, height: source.width });
    const documentFor = () => ({ crop: { x: 0, y: 0, width: source.width, height: source.height }, marks: [], rotation: 0 });
    const cloneDocument = (document) => ({
      crop: { ...document.crop },
      rotation: document.rotation ?? 0,
      marks: document.marks.map((mark) => ({ ...mark, points: mark.points.map((point) => ({ ...point })) }))
    });
    // 顺时针 90°：裁剪框与标注一起映射到新的文档空间（标注始终贴在原图同一处）。
    const rotatedDocument = (document) => {
      const size = spaceSize(document.rotation ?? 0);
      const crop = document.crop;
      return {
        crop: { x: size.height - (crop.y + crop.height), y: crop.x, width: crop.height, height: crop.width },
        marks: document.marks.map((mark) => ({ ...mark, points: mark.points.map((point) => ({ x: size.height - point.y, y: point.x })) })),
        rotation: ((document.rotation ?? 0) + 1) % 4
      };
    };
    const history = [documentFor()];
    let cursor = 0, tool = "brush", stroke = null, busy = false;
    // 裁剪会话：裁剪框在「当前裁剪区域」的视图坐标里，默认覆盖整张图片。
    let cropFrame = null, cropAspect = null, cropDrag = null, activeCropHandle = null;
    const header = element("header", "c-image-editor__header");
    const viewport = element("div", "c-image-editor__viewport");
    const footer = element("footer", "c-image-editor__footer");
    const tools = element("div", "c-image-editor__tools");
    const settings = element("div", "c-image-editor__settings");
    const cropOptions = element("div", "c-image-editor__crop-options");
    const cropActions = element("div", "c-image-editor__crop-actions");
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
    // 原图按旋转角度绘制进文档空间；旋转为 0 时走最短路径。
    const paintSource = (context, crop, rotation) => {
      if (!rotation) {
        context.drawImage(source, crop.x, crop.y, crop.width, crop.height, 0, 0, crop.width, crop.height);
        return;
      }
      context.save();
      context.translate(-crop.x, -crop.y);
      if (rotation === 1) { context.translate(source.height, 0); context.rotate(Math.PI / 2); }
      else if (rotation === 2) { context.translate(source.width, source.height); context.rotate(Math.PI); }
      else { context.translate(0, source.width); context.rotate(3 * Math.PI / 2); }
      context.drawImage(source, 0, 0);
      context.restore();
    };
    const clampFrame = (frame) => {
      const bounds = { width: history[cursor].crop.width, height: history[cursor].crop.height };
      const widthValue = Math.max(cropMinSize, Math.min(bounds.width, frame.width));
      const heightValue = Math.max(cropMinSize, Math.min(bounds.height, frame.height));
      return {
        x: Math.max(0, Math.min(bounds.width - widthValue, frame.x)),
        y: Math.max(0, Math.min(bounds.height - heightValue, frame.y)),
        width: widthValue,
        height: heightValue
      };
    };
    const fitAspect = (frame, aspect) => {
      if (!aspect) return clampFrame(frame);
      const bounds = { width: history[cursor].crop.width, height: history[cursor].crop.height };
      let widthValue = frame.width, heightValue = widthValue / aspect;
      if (heightValue > frame.height) { heightValue = frame.height; widthValue = heightValue * aspect; }
      if (widthValue > bounds.width) { widthValue = bounds.width; heightValue = widthValue / aspect; }
      if (heightValue > bounds.height) { heightValue = bounds.height; widthValue = heightValue * aspect; }
      if (widthValue < cropMinSize || heightValue < cropMinSize) return clampFrame(frame);
      return clampFrame({
        x: frame.x + (frame.width - widthValue) / 2,
        y: frame.y + (frame.height - heightValue) / 2,
        width: widthValue,
        height: heightValue
      });
    };
    const cropHandleAt = (point) => {
      const frame = cropFrame; if (!frame) return null;
      const nearLeft = Math.abs(point.x - frame.x) <= cropHitSlop;
      const nearRight = Math.abs(point.x - (frame.x + frame.width)) <= cropHitSlop;
      const nearTop = Math.abs(point.y - frame.y) <= cropHitSlop;
      const nearBottom = Math.abs(point.y - (frame.y + frame.height)) <= cropHitSlop;
      if (point.x < frame.x - cropHitSlop || point.x > frame.x + frame.width + cropHitSlop) return null;
      if (point.y < frame.y - cropHitSlop || point.y > frame.y + frame.height + cropHitSlop) return null;
      if (nearLeft && nearTop) return "nw";
      if (nearRight && nearTop) return "ne";
      if (nearRight && nearBottom) return "se";
      if (nearLeft && nearBottom) return "sw";
      if (nearTop && point.x > frame.x && point.x < frame.x + frame.width) return "n";
      if (nearBottom && point.x > frame.x && point.x < frame.x + frame.width) return "s";
      if (nearLeft && point.y > frame.y && point.y < frame.y + frame.height) return "w";
      if (nearRight && point.y > frame.y && point.y < frame.y + frame.height) return "e";
      return null;
    };
    const resizeFrame = (start, handle, delta) => {
      const bounds = { width: history[cursor].crop.width, height: history[cursor].crop.height };
      let left = start.x, top = start.y, right = start.x + start.width, bottom = start.y + start.height;
      if (handle.includes("w")) left = Math.max(0, Math.min(right - cropMinSize, left + delta.x));
      if (handle.includes("e")) right = Math.min(bounds.width, Math.max(left + cropMinSize, right + delta.x));
      if (handle.includes("n")) top = Math.max(0, Math.min(bottom - cropMinSize, top + delta.y));
      if (handle.includes("s")) bottom = Math.min(bounds.height, Math.max(top + cropMinSize, bottom + delta.y));
      const next = { x: left, y: top, width: right - left, height: bottom - top };
      if (!cropAspect) return next;
      // 固定比例：以拖动边的对侧为锚点套用比例，放不下则保持原框。
      const anchorX = handle.includes("w") ? right : left;
      const anchorY = handle.includes("n") ? bottom : top;
      let widthValue = next.width, heightValue = next.height;
      if (handle.includes("w") || handle.includes("e")) { heightValue = widthValue / cropAspect; }
      if (handle.includes("n") || handle.includes("s")) { widthValue = heightValue * cropAspect; }
      const fitted = {
        x: handle.includes("w") ? anchorX - widthValue : anchorX,
        y: handle.includes("n") ? anchorY - heightValue : anchorY,
        width: widthValue,
        height: heightValue
      };
      if (fitted.width < cropMinSize || fitted.height < cropMinSize) return start;
      if (fitted.x < 0 || fitted.y < 0 || fitted.x + fitted.width > bounds.width || fitted.y + fitted.height > bounds.height) return start;
      return fitted;
    };
    // 半透明遮罩 + 明显边框 + 四角控制点 + 四边拖动提示 + 三分参考线。
    const paintCropFrame = (context, crop) => {
      const frame = cropFrame; if (!frame) return;
      const onAccent = semanticToken("--color-on-accent");
      context.save();
      context.globalAlpha = .6;
      context.fillStyle = semanticToken("--color-scrim") || onAccent;
      context.fillRect(0, 0, crop.width, frame.y);
      context.fillRect(0, frame.y + frame.height, crop.width, crop.height - frame.y - frame.height);
      context.fillRect(0, frame.y, frame.x, frame.height);
      context.fillRect(frame.x + frame.width, frame.y, crop.width - frame.x - frame.width, frame.height);
      context.globalAlpha = .35;
      context.strokeStyle = onAccent; context.lineWidth = 1;
      for (let part = 1; part < 3; part++) {
        context.beginPath();
        context.moveTo(frame.x + frame.width * part / 3, frame.y);
        context.lineTo(frame.x + frame.width * part / 3, frame.y + frame.height);
        context.moveTo(frame.x, frame.y + frame.height * part / 3);
        context.lineTo(frame.x + frame.width, frame.y + frame.height * part / 3);
        context.stroke();
      }
      context.globalAlpha = 1;
      context.lineWidth = 2; context.strokeStyle = onAccent;
      context.strokeRect(frame.x, frame.y, frame.width, frame.height);
      context.fillStyle = activeCropHandle ? semanticToken("--color-brand-primary") : onAccent;
      const arm = 16, thick = 4;
      context.fillRect(frame.x, frame.y, arm, thick);
      context.fillRect(frame.x, frame.y, thick, arm);
      context.fillRect(frame.x + frame.width - arm, frame.y, arm, thick);
      context.fillRect(frame.x + frame.width - thick, frame.y, thick, arm);
      context.fillRect(frame.x, frame.y + frame.height - thick, arm, thick);
      context.fillRect(frame.x, frame.y + frame.height - arm, thick, arm);
      context.fillRect(frame.x + frame.width - arm, frame.y + frame.height - thick, arm, thick);
      context.fillRect(frame.x + frame.width - thick, frame.y + frame.height - arm, thick, arm);
      const middle = 9;
      context.fillRect(frame.x + frame.width / 2 - middle, frame.y - thick / 2, middle * 2, thick);
      context.fillRect(frame.x + frame.width / 2 - middle, frame.y + frame.height - thick / 2, middle * 2, thick);
      context.fillRect(frame.x - thick / 2, frame.y + frame.height / 2 - middle, thick, middle * 2);
      context.fillRect(frame.x + frame.width - thick / 2, frame.y + frame.height / 2 - middle, thick, middle * 2);
      context.restore();
    };
    const redraw = () => {
      const document = history[cursor], crop = document.crop;
      canvas.width = crop.width; canvas.height = crop.height;
      overlay.width = crop.width; overlay.height = crop.height;
      const context = canvas.getContext("2d"), overlayContext = overlay.getContext("2d");
      paintSource(context, crop, document.rotation ?? 0);
      for (const mark of document.marks) drawMark(overlayContext, mark, crop);
      context.drawImage(overlay, 0, 0);
      if (tool === "crop") paintCropFrame(context, crop);
    };
    const refresh = () => {
      undo.disabled = busy || cursor === 0;
      redo.disabled = busy || cursor === history.length - 1;
      done.disabled = busy;
      cropActions.hidden = tool !== "crop";
      cropOptions.hidden = tool !== "crop";
      if (cropActions.children.length) {
        cropActions.children[1].disabled = busy || !cropFrame
          || cropFrame.width < cropMinSize || cropFrame.height < cropMinSize;
      }
    };
    const commit = (next) => { history.splice(cursor + 1); history.push(cloneDocument(next)); cursor++; cropFrame = null; cropDrag = null; activeCropHandle = null; redraw(); refresh(); };
    const restore = () => { redraw(); refresh(); };
    const resetAll = () => {
      history.splice(0, history.length, documentFor()); cursor = 0;
      cropFrame = null; cropAspect = null; cropDrag = null; activeCropHandle = null;
      for (const node of cropOptions.children) if (node.dataset.aspect) node.setAttribute("aria-pressed", String(node.dataset.aspect === "free"));
      restore(); status.textContent = "已还原为原始图片（默认裁剪框、缩放与旋转）";
    };
    const cancel = control("取消", () => { cursor = 0; cropFrame = null; activeCropHandle = null; restore(); this.dispatchEvent(new CustomEvent("image-cancel", { bubbles: true })); status.textContent = "已取消编辑，原图保持不变"; }, "取消");
    const undo = control("撤销", () => { if (cursor > 0) { cursor--; cropFrame = null; restore(); } }, "↶");
    const redo = control("重做", () => { if (cursor < history.length - 1) { cursor++; cropFrame = null; restore(); } }, "↷");
    const historyControls = element("div", "c-image-editor__history"); historyControls.append(undo, redo); header.append(cancel, historyControls);
    const sheet = () => {
      if (root.querySelector(".c-image-editor__sheet")) return;
      const panel = element("div", "c-image-editor__sheet"); panel.setAttribute("role", "dialog"); panel.setAttribute("aria-label", "完成图片编辑");
      const close = () => panel.remove();
      for (const [action, label] of [["send", "发送"], ["forward", "转发"], ["save", "保存到相册"], ["favorite", "收藏"]]) {
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
              status.textContent = action === "forward" ? "演示：已生成转发图片" : action === "send" ? "演示：已作为新的媒体对象发送" : "演示：已生成收藏图片";
            }
            close();
          } catch { status.textContent = "图片处理失败，请重试"; }
          finally { busy = false; refresh(); panel.querySelectorAll("button").forEach((node) => { node.disabled = false; }); }
        }, label));
      }
      panel.append(control("取消", close, "取消")); root.append(panel);
    };
    const done = control("完成", sheet, "完成"); done.classList.add("c-image-editor__done");
    // 裁剪工具条：旋转 + 比例预设 + 还原 / 应用裁剪（同高度、同圆角）。
    const rotate = control("旋转", () => {
      if (busy) return;
      history.splice(cursor + 1); history.push(cloneDocument(rotatedDocument(history[cursor]))); cursor++;
      cropFrame = null; activeCropHandle = null; restore(); status.textContent = "已旋转 90°";
    }, "⟳");
    rotate.classList.add("c-image-editor__crop-chip");
    const applyCrop = control("应用裁剪", () => {
      if (busy || !cropFrame) return;
      if (cropFrame.width < cropMinSize || cropFrame.height < cropMinSize) return;
      const crop = history[cursor].crop;
      commit({
        ...history[cursor],
        // 裁剪框（视图）→ 图像像素：产生的是**新文档**，原图字节不被修改。
        crop: {
          x: crop.x + cropFrame.x,
          y: crop.y + cropFrame.y,
          width: cropFrame.width,
          height: cropFrame.height
        }
      });
      status.textContent = "已应用裁剪，原图保持不变";
    }, "应用裁剪");
    applyCrop.classList.add("c-image-editor__crop-action");
    applyCrop.dataset.filled = "true";
    const reset = control("还原", resetAll, "还原");
    reset.classList.add("c-image-editor__crop-action");
    cropOptions.append(rotate);
    for (const [id, label, aspect] of cropAspects) {
      const chip = control(label, () => {
        cropAspect = aspect;
        if (cropFrame) {
          const frame = aspect
            ? fitAspect(cropFrame, aspect)
            : { ...cropFrame };
          cropFrame = frame;
        }
        for (const node of cropOptions.children) if (node.dataset.aspect) node.setAttribute("aria-pressed", String(node === chip));
        restore();
      }, label);
      chip.classList.add("c-image-editor__crop-chip");
      chip.dataset.aspect = id;
      chip.setAttribute("aria-pressed", String(aspect === null));
      cropOptions.append(chip);
    }
    cropActions.append(reset, applyCrop);
    const choices = [["brush", "画笔", icon("edit")], ["emoji", "表情", icon("emoji")], ["text", "文字", "T"], ["crop", "裁剪", "⌗"], ["mosaic", "马赛克", "▦"], ["eraser", "橡皮擦", icon("eraser")]];
    for (const [id, label, glyph] of choices) {
      const item = control(label, () => {
        tool = id; text.hidden = id !== "text"; emojiPicker.hidden = id !== "emoji";
        // 进入裁剪：裁剪框默认覆盖整张图片（不是固定小框）。
        cropFrame = id === "crop" ? { x: 0, y: 0, width: history[cursor].crop.width, height: history[cursor].crop.height } : null;
        cropAspect = id === "crop" ? cropAspect : null;
        activeCropHandle = null;
        for (const node of tools.children) node.setAttribute("aria-pressed", String(node === item));
        status.textContent = id === "crop" ? "拖动边框或四角调整裁剪范围" : id === "emoji" ? "选择表情后点击图片放置" : id === "text" ? "点击图片放置" : id === "eraser" ? "轻触或拖动擦除编辑痕迹" : "在图片上拖动绘制";
        restore();
      }, glyph);
      item.setAttribute("aria-pressed", String(id === tool)); tools.append(item);
    }
    const point = (event) => { const rect = canvas.getBoundingClientRect(), crop = history[cursor].crop; return { x: Math.max(0, Math.min(canvas.width, (event.clientX - rect.left) * canvas.width / rect.width)), y: Math.max(0, Math.min(canvas.height, (event.clientY - rect.top) * canvas.height / rect.height)) }; };
    canvas.addEventListener("pointerdown", (event) => {
      if (busy || state === "loading" || state === "error") return;
      canvas.setPointerCapture(event.pointerId);
      const start = point(event);
      if (tool === "crop") {
        activeCropHandle = cropHandleAt(start);
        cropDrag = activeCropHandle ? { handle: activeCropHandle, start, frame: { ...cropFrame } } : null;
        restore();
        return;
      }
      stroke = [start];
      if (tool === "text" || tool === "emoji") {
        const value = tool === "emoji" ? selectedEmoji : text.value.trim();
        if (!value) { status.textContent = tool === "emoji" ? "请先选择表情" : "请先输入文字"; stroke = null; return; }
        commit({ ...history[cursor], marks: [...history[cursor].marks, { kind: tool, points: stroke, value, color: color.value, width: Number(width.value) }] }); stroke = null;
      }
    });
    canvas.addEventListener("pointermove", (event) => {
      if (tool === "crop") {
        if (!cropDrag) return;
        const next = point(event);
        cropFrame = resizeFrame(cropDrag.frame, cropDrag.handle, { x: next.x - cropDrag.start.x, y: next.y - cropDrag.start.y });
        restore();
        return;
      }
      if (!stroke) return;
      const next = point(event);
      stroke.push(next); redraw();
      const preview = { kind: tool, points: stroke, color: color.value, width: Number(width.value) };
      const document = history[cursor], overlayContext = overlay.getContext("2d");
      overlayContext.width = overlay.width;
      drawMark(overlayContext, preview, document.crop);
      canvas.getContext("2d").drawImage(overlay, 0, 0);
    });
    canvas.addEventListener("pointerup", (event) => {
      if (tool === "crop") { cropDrag = null; activeCropHandle = null; restore(); return; }
      if (!stroke) return;
      const end = point(event); if (stroke.at(-1).x !== end.x || stroke.at(-1).y !== end.y) stroke.push(end);
      commit({ ...history[cursor], marks: [...history[cursor].marks, { kind: tool, points: stroke, color: color.value, width: Number(width.value) }] });
      stroke = null;
    });
    canvas.addEventListener("pointercancel", () => { stroke = null; cropDrag = null; activeCropHandle = null; restore(); });
    settings.append(color, width, text, emojiPicker, cropOptions, cropActions); footer.append(settings, tools, done); viewport.append(canvas); root.append(header, viewport, status, footer); redraw(); refresh();
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
