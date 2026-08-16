const primitive = (tag, attributes) => Object.freeze({ tag, attributes: Object.freeze(attributes) });
const path = (d) => primitive("path", { d });
const circle = (cx, cy, r) => primitive("circle", { cx, cy, r });
const rect = (x, y, width, height, rx = 0) => primitive("rect", { x, y, width, height, rx });
const line = (x1, y1, x2, y2) => primitive("line", { x1, y1, x2, y2 });
const polyline = (points) => primitive("polyline", { points });

export const iconDefinitions = Object.freeze({
  add: [line(12, 5, 12, 19), line(5, 12, 19, 12)],
  back: [polyline("15 18 9 12 15 6")],
  bell: [path("M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9"), path("M10 21h4")],
  "bell-off": [path("M13.7 21h-3.4"), path("M6.3 6.3A5.9 5.9 0 0 0 6 8c0 7-3 7-3 9h14"), path("M18 8a6 6 0 0 0-8.2-5.6"), line(3, 3, 21, 21)],
  bookmark: [path("M6 4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18l-6-4-6 4z")],
  calendar: [rect(3, 5, 18, 16, 2), line(16, 3, 16, 7), line(8, 3, 8, 7), line(3, 11, 21, 11)],
  call: [path("M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 2 .7 2.9a2 2 0 0 1-.5 2.1L8 10a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.5c.9.3 1.9.6 2.9.7A2 2 0 0 1 22 16.9z")],
  camera: [path("M14.5 4 16 7h3a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h3l1.5-3z"), circle(12, 13, 3)],
  chat: [path("M21 11.5a8.4 8.4 0 0 1-9 8.5 9.5 9.5 0 0 1-4-.9L3 21l1.8-4.5A8.2 8.2 0 0 1 3 11.5 8.4 8.4 0 0 1 12 3a8.4 8.4 0 0 1 9 8.5z"), circle(8, 12, .5), circle(12, 12, .5), circle(16, 12, .5)],
  check: [polyline("20 6 9 17 4 12")],
  chevron: [polyline("9 18 15 12 9 6")],
  close: [line(18, 6, 6, 18), line(6, 6, 18, 18)],
  comment: [path("M21 15a4 4 0 0 1-4 4H8l-5 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4z")],
  contact: [circle(12, 7.5, 3.5), path("M5 21v-2a7 7 0 0 1 14 0v2")],
  copy: [rect(8, 8, 12, 12, 2), path("M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2")],
  delete: [polyline("3 6 5 6 21 6"), path("M8 6V4h8v2M19 6l-1 15H6L5 6M10 11v6M14 11v6")],
  discovery: [circle(12, 12, 9), path("m15.5 8.5-2.2 4.8-4.8 2.2 2.2-4.8z")],
  document: [path("M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"), polyline("14 2 14 8 20 8"), line(8, 13, 16, 13), line(8, 17, 16, 17)],
  download: [path("M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"), polyline("7 10 12 15 17 10"), line(12, 15, 12, 3)],
  edit: [path("M12 20h9"), path("M16.5 3.5a2.1 2.1 0 0 1 3 3L8 18l-4 1 1-4z")],
  emoji: [circle(12, 12, 9), circle(9, 10, .6), circle(15, 10, .6), path("M8 14a4.5 4.5 0 0 0 8 0")],
  error: [circle(12, 12, 9), line(12, 7, 12, 13), line(12, 17, 12.01, 17)],
  eye: [path("M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12z"), circle(12, 12, 2.5)],
  "eye-off": [path("M9.8 5.3A10.5 10.5 0 0 1 12 5c6.5 0 10 7 10 7a16 16 0 0 1-2 2.7"), path("M6.6 6.6A16.5 16.5 0 0 0 2 12s3.5 7 10 7a10 10 0 0 0 4.4-1"), line(3, 3, 21, 21)],
  file: [path("M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"), polyline("14 2 14 8 20 8")],
  filter: [path("M4 4h16l-6 7v6l-4 3v-9z")],
  gift: [rect(3, 8, 18, 13, 2), line(12, 8, 12, 21), line(3, 12, 21, 12), path("M12 8H7.5A2.5 2.5 0 1 1 10 5.5C10 7 12 8 12 8z"), path("M12 8h4.5A2.5 2.5 0 1 0 14 5.5C14 7 12 8 12 8z")],
  group: [circle(9, 8, 3), circle(17, 9, 2.5), path("M3 21v-2a6 6 0 0 1 12 0v2"), path("M15 15a5 5 0 0 1 6 5v1")],
  headset: [path("M4 14v-2a8 8 0 0 1 16 0v2"), rect(3, 13, 4, 6, 2), rect(17, 13, 4, 6, 2), path("M17 19c0 2-2 3-5 3")],
  heart: [path("M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.6l-1.1-1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8z")],
  image: [rect(3, 3, 18, 18, 2), circle(8.5, 8.5, 1.5), polyline("21 15 16 10 5 21")],
  info: [circle(12, 12, 9), line(12, 11, 12, 17), line(12, 7, 12.01, 7)],
  like: [path("M7 22H4a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2h3z"), path("M7 11l4-9a3 3 0 0 1 3 3v4h5a3 3 0 0 1 3 3l-1 7a3 3 0 0 1-3 3H7z")],
  link: [path("M10 13a5 5 0 0 0 7.5.5l2-2a5 5 0 0 0-7-7l-1.1 1"), path("M14 11a5 5 0 0 0-7.5-.5l-2 2a5 5 0 0 0 7 7l1.1-1")],
  location: [path("M20 10c0 5-8 12-8 12S4 15 4 10a8 8 0 1 1 16 0z"), circle(12, 10, 2.5)],
  lock: [rect(5, 10, 14, 11, 2), path("M8 10V7a4 4 0 0 1 8 0v3")],
  logout: [path("M10 17l5-5-5-5"), line(15, 12, 3, 12), path("M14 3h5a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-5")],
  mail: [rect(3, 5, 18, 14, 2), polyline("3 7 12 13 21 7")],
  me: [circle(12, 8, 4), path("M4 21a8 8 0 0 1 16 0")],
  microphone: [rect(9, 3, 6, 12, 3), path("M5 11a7 7 0 0 0 14 0"), line(12, 18, 12, 22), line(8, 22, 16, 22)],
  more: [circle(5, 12, 1), circle(12, 12, 1), circle(19, 12, 1)],
  network: [path("M5 12.5a10 10 0 0 1 14 0"), path("M8 16a6 6 0 0 1 8 0"), path("M11 19.5a2 2 0 0 1 2 0")],
  pause: [rect(6, 4, 4, 16, 1), rect(14, 4, 4, 16, 1)],
  play: [path("m7 4 13 8-13 8z")],
  "qr-code": [path("M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h3v3h-3zM18 14h3v7h-3zM14 19h3v2h-3z")],
  retry: [path("M20 7v5h-5"), path("M4 17v-5h5"), path("M6.1 9a7 7 0 0 1 11.5-2.6L20 12"), path("M4 12l2.4 5.6A7 7 0 0 0 17.9 15")],
  scan: [path("M3 8V5a2 2 0 0 1 2-2h3M16 3h3a2 2 0 0 1 2 2v3M21 16v3a2 2 0 0 1-2 2h-3M8 21H5a2 2 0 0 1-2-2v-3"), line(7, 12, 17, 12)],
  search: [circle(11, 11, 7), line(20, 20, 16, 16)],
  send: [path("M22 2 11 13"), path("m22 2-7 20-4-9-9-4z")],
  settings: [circle(12, 12, 3), path("M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4v-.2a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-1.6v-.2h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1z")],
  share: [circle(18, 5, 2.5), circle(6, 12, 2.5), circle(18, 19, 2.5), line(8.2, 10.8, 15.8, 6.2), line(8.2, 13.2, 15.8, 17.8)],
  shield: [path("M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"), polyline("9 12 11 14 15 10")],
  star: [path("m12 2 3.1 6.3 6.9 1-5 4.9 1.2 6.8-6.2-3.2L5.8 21 7 14.2 2 9.3l6.9-1z")],
  upload: [path("M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"), polyline("17 8 12 3 7 8"), line(12, 3, 12, 15)],
  "user-add": [circle(9, 8, 4), path("M2 21a7 7 0 0 1 14 0"), line(19, 8, 19, 14), line(16, 11, 22, 11)],
  video: [rect(3, 6, 14, 12, 2), path("m17 10 4-3v10l-4-3z")],
  wallet: [path("M4 5h14a2 2 0 0 1 2 2v12H4a2 2 0 0 1-2-2V5a3 3 0 0 1 3-3h13"), path("M16 11h6v4h-6a2 2 0 0 1 0-4z")],
  warning: [path("M10.3 3.6 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.6a2 2 0 0 0-3.4 0z"), line(12, 9, 12, 13), line(12, 17, 12.01, 17)]
});

export const iconNames = Object.freeze(Object.keys(iconDefinitions));
const svgNamespace = "http:" + "//www.w3.org/2000/svg";

export function icon(name, className = "") {
  const definition = iconDefinitions[name];
  if (!definition) throw new Error(`Unknown icon: ${name}`);
  const svg = document.createElementNS(svgNamespace, "svg");
  svg.setAttribute("class", ["c-icon", className].filter(Boolean).join(" "));
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "1.8");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("focusable", "false");
  svg.dataset.icon = name;
  for (const item of definition) {
    const node = document.createElementNS(svgNamespace, item.tag);
    for (const [attribute, value] of Object.entries(item.attributes)) node.setAttribute(attribute, String(value));
    svg.append(node);
  }
  return svg;
}
