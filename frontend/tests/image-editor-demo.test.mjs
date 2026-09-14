import test from "node:test";
import assert from "node:assert/strict";

class Node {
  constructor(tagName = "div") {
    this.tagName = tagName;
    this.children = [];
    this.attributes = {};
    this.dataset = {};
    this.listeners = {};
    this.classList = { add: () => {} };
    this.style = {};
    this.hidden = false;
    this.width = 720;
    this.height = 960;
  }
  append(...children) { this.children.push(...children); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  getAttributeNames() { return Object.keys(this.attributes); }
  addEventListener(name, handler) { this.listeners[name] = handler; }
  getContext() {
    return {
      beginPath() {}, drawImage() {}, fill() {}, fillRect() {}, fillText() {},
      getImageData: () => ({ width: this.width, height: this.height, data: [] }),
      lineTo() {}, moveTo() {}, putImageData() {}, quadraticCurveTo() {},
      stroke() {}, strokeRect() {}, arc() {}, save() {}, restore() {}, createLinearGradient: () => ({ addColorStop() {} }),
    };
  }
  getBoundingClientRect() { return { left: 0, top: 0, width: this.width, height: this.height }; }
  setPointerCapture() {}
}

globalThis.HTMLElement = Node;
globalThis.Node = Node;
// The editor reads its palette from CSS custom properties; tests supply
// deterministic values instead of a styling engine.
if (!globalThis.getComputedStyle) {
  globalThis.getComputedStyle = () => ({ getPropertyValue: () => "#888888" });
}
globalThis.document = {
  createElement: (tag) => new Node(tag),
  createElementNS: (_namespace, tag) => new Node(tag),
};

const { AppImageEditor } = await import("../src/components/image-editor.js");
const all = (root) => [root, ...root.children.filter((child) => child instanceof Node).flatMap(all)];

test("image editor demo exposes distinct eraser and centered fixed emoji controls", () => {
  const editor = new AppImageEditor();
  const rendered = editor.render();
  const nodes = all(rendered);
  const labels = nodes.map((node) => node.getAttribute("aria-label"));
  assert.ok(labels.includes("橡皮擦"), "eraser must be a distinct tool");

  const grid = nodes.find((node) => node.getAttribute("data-testid") === "image-editor-emoji-grid");
  assert.ok(grid, "emoji picker needs a stable centered grid");
  const cells = all(grid).filter((node) => node.getAttribute("data-testid") === "image-editor-emoji-cell");
  assert.equal(cells.length, 35);
  for (const cell of cells) assert.equal(cell.getAttribute("data-fixed-touch"), "48");

  const emojiTool = nodes.find((node) => node.getAttribute("aria-label") === "表情");
  emojiTool.listeners.click();
  assert.equal(grid.hidden, false, "emoji picker opens only for the emoji tool");
  cells[0].listeners.click();
  assert.equal(grid.hidden, true, "emoji picker closes after selection");

  const eraser = nodes.find((node) => node.getAttribute("aria-label") === "橡皮擦");
  assert.equal(eraser.children[0].dataset.icon, "eraser", "eraser uses its own vector icon");
});
