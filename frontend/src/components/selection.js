import { StrictElement, element } from "./base.js";

const demoMessage = "明天上午九点见 🥲，请带上项目资料。\n第二行用于跨行选择。";

export function graphemes(value) {
  if (typeof Intl?.Segmenter === "function") {
    return [...new Intl.Segmenter("zh-CN", { granularity: "grapheme" }).segment(value)].map(({ segment }) => segment);
  }
  return Array.from(value);
}

export function closestGraphemeBoundary(boxes, x, y) {
  let closest = null;
  for (const { start, end, rect } of boxes) {
    const centerY = (rect.top + rect.bottom) / 2;
    for (const [offset, edgeX] of [[start, rect.left], [end, rect.right]]) {
      const distance = (x - edgeX) ** 2 + (y - centerY) ** 2;
      if (closest == null || distance < closest.distance) closest = { offset, distance };
    }
  }
  return closest?.offset ?? null;
}

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

function graphemeOffsetAtUtf16(value, utf16Offset) {
  const safeOffset = clamp(utf16Offset, 0, value.length);
  if (typeof Intl?.Segmenter !== "function") return graphemes(value.slice(0, safeOffset)).length;
  let count = 0;
  for (const part of new Intl.Segmenter("zh-CN", { granularity: "grapheme" }).segment(value)) {
    if (part.index + part.segment.length > safeOffset) break;
    count++;
  }
  return count;
}

export class AppEmojiInputDecoration extends StrictElement {
  render() {
    return element("span", "c-emoji-input-decoration", this.attr("text", "🥲 项目资料"));
  }
}

export class AppMessageSelectionSession extends StrictElement {
  constructor() {
    super();
    this.messageText = demoMessage;
    this.selectedStart = 0;
    this.selectedEnd = graphemes(this.messageText).length;
    this._sessionState = "active";
    this._dragEdge = null;
    this._lensVisible = false;
    this._menuVisible = true;
    this._longPress = null;
  }

  get selectedText() {
    return graphemes(this.messageText).slice(this.selectedStart, this.selectedEnd).join("");
  }

  get selectionKind() {
    return this.selectedStart === 0 && this.selectedEnd === graphemes(this.messageText).length ? "all" : "partial";
  }

  get sessionState() { return this._sessionState; }
  get lensVisible() { return this._lensVisible; }
  get menuVisible() { return this._menuVisible; }

  connectedCallback() {
    super.connectedCallback();
    this._scheduleHandlePlacement();
    if (typeof ResizeObserver === "function" && this._root) {
      this._resizeObserver = new ResizeObserver(() => this._scheduleHandlePlacement());
      this._resizeObserver.observe(this._root);
      this._resizeObserver.observe(this._text);
      this._resizeObserver.observe(this._menu);
    }
    this._onScroll = () => this.cancelSession();
    window?.addEventListener?.("scroll", this._onScroll, true);
  }

  disconnectedCallback() {
    window?.removeEventListener?.("scroll", this._onScroll, true);
    this._resizeObserver?.disconnect();
    if (this._handlePositionFrame) cancelAnimationFrame(this._handlePositionFrame);
    this._clearLongPress();
  }

  render() {
    const root = element("section", "c-selection-demo");
    root.dataset.state = this._sessionState;
    root.dataset.selection = this.selectionKind;
    root.setAttribute("aria-label", "消息文字选择演示");

    const text = element("p", "c-selection-demo__text");
    text.addEventListener("pointerdown", event => this._startLongPress(event));
    text.addEventListener("pointerup", () => this._clearLongPress());
    text.addEventListener("pointercancel", () => this._clearLongPress());

    const lens = element("div", "c-selection-demo__lens");
    lens.setAttribute("aria-hidden", "true");
    const lensClip = element("div", "c-selection-demo__lens-clip");
    const lensText = element("span", "c-selection-demo__lens-text", this.messageText);
    lensClip.append(lensText);
    lens.append(lensClip);

    const menu = element("div", "c-selection-demo__menu");
    const menuControl = document.createElement("app-anchored-action-menu");
    menuControl.setAttribute("options", JSON.stringify(this._menuOptions()));
    menu.addEventListener("click", event => {
      const action = event.target.closest?.("[data-action]")?.dataset.action;
      if (action) void this.performAction(action);
    });
    menu.append(menuControl);

    const result = element("output", "c-selection-demo__result");
    result.setAttribute("aria-live", "polite");
    result.hidden = true;

    root.addEventListener("pointerdown", event => {
      if (event.target === root) this.cancelSession();
    });
    const startHandle = this._handle("start");
    const endHandle = this._handle("end");
    root.append(text, startHandle, endHandle, lens, menu, result);
    this._root = root;
    this._text = text;
    this._lens = lens;
    this._lensText = lensText;
    this._menu = menu;
    this._menuControl = menuControl;
    this._result = result;
    this._startHandle = startHandle;
    this._endHandle = endHandle;
    this._paint();
    return root;
  }

  _handle(edge) {
    const hit = element("button", "c-selection-demo__hit");
    hit.type = "button";
    hit.dataset.edge = edge;
    hit.setAttribute("aria-label", `${edge === "start" ? "起点" : "终点"}选择手柄`);
    const line = element("span", "c-selection-demo__handle-line");
    line.setAttribute("aria-hidden", "true");
    const dot = element("span", "c-selection-demo__handle");
    dot.setAttribute("aria-hidden", "true");
    hit.append(line, dot);
    hit.addEventListener("pointerdown", event => {
      event.preventDefault();
      hit.setPointerCapture?.(event.pointerId);
      this.beginDrag(edge, event);
    });
    hit.addEventListener("pointermove", event => {
      if (this._dragEdge !== edge) return;
      this.updateHandle(edge, this._offsetAtPointer(event));
      this._positionLens(event);
    });
    hit.addEventListener("pointerup", () => this.finishDrag());
    hit.addEventListener("pointercancel", () => this.finishDrag());
    return hit;
  }

  _startLongPress(event) {
    if (this._sessionState !== "dismissed") return;
    this._clearLongPress();
    this._longPress = setTimeout(() => {
      this._sessionState = "active";
      this._menuVisible = true;
      this._lensVisible = false;
      this._paint();
    }, 360);
    event.currentTarget?.setPointerCapture?.(event.pointerId);
  }

  _clearLongPress() {
    if (this._longPress) clearTimeout(this._longPress);
    this._longPress = null;
  }

  setSelection(start, end) {
    const length = graphemes(this.messageText).length;
    this.selectedStart = clamp(Math.min(start, end), 0, Math.max(0, length - 1));
    this.selectedEnd = clamp(Math.max(start, end), this.selectedStart + 1, length);
    this._paint();
  }

  updateHandle(edge, offset) {
    if (edge === "start") this.setSelection(offset, this.selectedEnd);
    else this.setSelection(this.selectedStart, offset);
  }

  beginDrag(edge, event) {
    this._dragEdge = edge;
    this._sessionState = "dragging";
    this._lensVisible = true;
    this._menuVisible = false;
    this._positionLens(event);
    this._paint();
  }

  finishDrag() {
    this._dragEdge = null;
    if (this._sessionState === "dismissed") return;
    this._sessionState = "settled";
    this._lensVisible = false;
    this._menuVisible = true;
    this._paint();
  }

  cancelSession() {
    this._clearLongPress();
    this._dragEdge = null;
    this._sessionState = "dismissed";
    this._lensVisible = false;
    this._menuVisible = false;
    this._paint();
  }

  _offsetAtPointer(event) {
    const range = document.caretRangeFromPoint?.(event.clientX, event.clientY)
      ?? document.caretPositionFromPoint?.(event.clientX, event.clientY);
    const node = range?.startContainer ?? range?.offsetNode;
    const offset = range?.startOffset ?? range?.offset;
    const segment = node?.parentElement?.closest?.("[data-selection-start]") ?? node?.closest?.("[data-selection-start]");
    if (segment) {
      const local = graphemeOffsetAtUtf16(segment.textContent, offset);
      return Number(segment.dataset.selectionStart) + local;
    }
    const geometricOffset = this._offsetFromRangeBoxes(event.clientX, event.clientY);
    if (geometricOffset != null) return geometricOffset;
    const rect = this._text?.getBoundingClientRect?.();
    if (!rect?.width) return this._dragEdge === "start" ? this.selectedStart : this.selectedEnd;
    return Math.round(((event.clientX - rect.left) / rect.width) * graphemes(this.messageText).length);
  }

  _offsetFromRangeBoxes(x, y) {
    if (!document.createRange || !this._segments) return null;
    const boxes = [];
    for (const { start, element: segment } of this._segments) {
      const textNode = segment.firstChild;
      if (!textNode) continue;
      let utf16Offset = 0;
      for (const [index, grapheme] of graphemes(segment.textContent).entries()) {
        const range = document.createRange();
        range.setStart(textNode, utf16Offset);
        utf16Offset += grapheme.length;
        range.setEnd(textNode, utf16Offset);
        for (const rect of range.getClientRects?.() ?? []) boxes.push({ start: start + index, end: start + index + 1, rect });
      }
    }
    return closestGraphemeBoundary(boxes, x, y);
  }

  _selectionRange() {
    if (!this._text || !document.createRange) return null;
    const range = document.createRange();
    range.setStart(this._text, 0);
    range.setEnd(this._text, this._text.children?.length ?? 0);
    return range;
  }

  _positionHandles() {
    if (!this._root || !this._selected || !document.createRange) return;
    const range = document.createRange();
    range.selectNodeContents?.(this._selected);
    const rectangles = [...(range.getClientRects?.() ?? [])];
    const fallback = this._selected.getBoundingClientRect?.();
    const first = rectangles[0] ?? fallback;
    const last = rectangles.at(-1) ?? fallback;
    const root = this._root.getBoundingClientRect?.();
    if (!first || !last || !root || root.width === 0 || root.height === 0 || first.height === 0 || last.height === 0) return;
    const place = (handle, x, y, height) => {
      if (!handle) return;
      handle.style.left = `${Math.round(x - root.left - 22)}px`;
      handle.style.top = `${Math.round(y + height / 2 - root.top - 22)}px`;
    };
    place(this._startHandle, first.left, first.top, first.height);
    place(this._endHandle, last.right, last.top, last.height);
  }

  _scheduleHandlePlacement() {
    if (this._handlePositionFrame) cancelAnimationFrame(this._handlePositionFrame);
    if (typeof requestAnimationFrame !== "function") {
      this._positionHandles();
      return;
    }
    this._handlePositionFrame = requestAnimationFrame(() => {
      this._handlePositionFrame = null;
      this._positionHandles();
      this._positionMenu();
    });
  }

  _positionMenu() {
    if (!this._root || !this._text || !this._menu || !this._menuControl) return;
    const root = this._root.getBoundingClientRect?.();
    const text = this._text.getBoundingClientRect?.();
    const menu = this._menu.getBoundingClientRect?.();
    if (!root || !text || !menu || root.width === 0 || root.height === 0 || menu.height === 0) return;
    const gap = 8;
    const above = text.top - root.top - menu.height - gap;
    const below = text.bottom - root.top + gap;
    const canPlaceBelow = below + menu.height <= root.height - gap;
    const placeBelow = above < gap && canPlaceBelow;
    this._menu.style.left = `${Math.round(clamp(text.left - root.left, gap, Math.max(gap, root.width - menu.width - gap)))}px`;
    this._menu.style.top = `${Math.round(placeBelow ? below : Math.max(gap, above))}px`;
    if (placeBelow) this._menuControl.setAttribute("arrow-at-top", "true");
    else this._menuControl.removeAttribute("arrow-at-top");
  }

  _menuOptions() {
    return this.selectionKind === "all"
      ? [
          { id: "copy", label: "复制", icon: "copy" },
          { id: "forward", label: "转发", icon: "pin" },
          { id: "quote", label: "引用", icon: "reply" },
          { id: "reminder", label: "提醒" },
          { id: "select", label: "多选", icon: "select" },
          { id: "delete", label: "删除", icon: "delete" }
        ]
      : [
          { id: "copy", label: "复制", icon: "copy" },
          { id: "select-all", label: "全选", icon: "select" },
          { id: "quote", label: "引用", icon: "reply" },
          { id: "forward", label: "转发", icon: "pin" }
        ];
  }

  _positionLens(event = {}) {
    const rangeRect = this._selectionRange()?.getBoundingClientRect?.();
    const x = event.clientX ?? rangeRect?.left ?? 0;
    const y = event.clientY ?? rangeRect?.top ?? 0;
    if (this._lens) {
      this._lens.style.left = `${Math.max(8, x - 58)}px`;
      this._lens.style.top = `${Math.max(8, y - 94)}px`;
    }
    if (this._lensText) {
      this._lensText.style.transform = `translate(${-Math.max(0, x - (rangeRect?.left ?? 0)) * 1.4}px, ${-Math.max(0, y - (rangeRect?.top ?? 0)) * 1.4}px) scale(1.45)`;
    }
  }

  _paint() {
    if (!this._root) return;
    this._root.dataset.state = this._sessionState;
    this._root.dataset.selection = this.selectionKind;
    if (this._text) {
      const parts = graphemes(this.messageText);
      const before = element("span", "c-selection-demo__segment", parts.slice(0, this.selectedStart).join(""));
      const selected = element("mark", "c-selection-demo__range", parts.slice(this.selectedStart, this.selectedEnd).join(""));
      const after = element("span", "c-selection-demo__segment", parts.slice(this.selectedEnd).join(""));
      before.dataset.selectionStart = "0";
      selected.dataset.selectionStart = String(this.selectedStart);
      after.dataset.selectionStart = String(this.selectedEnd);
      this._text.replaceChildren(before, selected, after);
      this._selected = selected;
      this._segments = [
        { start: 0, element: before },
        { start: this.selectedStart, element: selected },
        { start: this.selectedEnd, element: after }
      ];
      this._positionHandles();
    }
    if (this._menuControl) this._menuControl.setAttribute("options", JSON.stringify(this._menuOptions()));
    this._positionMenu();
    this._menuControl?.renderContract?.();
    if (this._lens) this._lens.hidden = !this._lensVisible;
    if (this._menu) this._menu.hidden = !this._menuVisible;
  }

  async copySelectedText() {
    const text = this.selectedText;
    try {
      if (!navigator.clipboard?.writeText) throw new Error("clipboard unavailable");
      await navigator.clipboard.writeText(text);
      return "已复制";
    } catch {
      return "复制不可用，请使用系统复制";
    }
  }

  performAction(action) {
    if (action === "copy") {
      const text = this.selectedText;
      return this.copySelectedText().then(status => {
        const result = `${status}：${text}`;
        this._showResult(result);
        return result;
      });
    }
    if (action === "select-all") {
      this.setSelection(0, graphemes(this.messageText).length);
      this._showResult("已选择整条消息");
      return "已选择整条消息";
    }
    const prefix = action === "quote" ? "引用" : "转发";
    const result = `${prefix}：${this.selectedText}`;
    this._showResult(result);
    return result;
  }

  _showResult(message) {
    this.lastResult = message;
    if (!this._result) return;
    this._result.textContent = message;
    this._result.hidden = false;
  }
}
