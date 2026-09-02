import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("../", import.meta.url)));
const port = Number.parseInt(process.env.PORT ?? "4173", 10);
const mimeTypes = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".mjs", "text/javascript; charset=utf-8"],
  [".png", "image/png"],
  [".svg", "image/svg+xml"]
]);

function safePath(pathname) {
  const relative = pathname === "/" ? "index.html" : decodeURIComponent(pathname.slice(1));
  const candidate = resolve(root, relative);
  return candidate === root || candidate.startsWith(`${root}${sep}`) ? candidate : null;
}

const server = createServer(async (request, response) => {
  const pathname = new URL(request.url ?? "/", "http://local.test").pathname;
  const candidate = safePath(pathname);
  if (!candidate) {
    response.writeHead(403).end("Forbidden");
    return;
  }

  try {
    const info = await stat(candidate);
    const file = info.isDirectory() ? resolve(candidate, "index.html") : candidate;
    response.writeHead(200, {
      "content-type": mimeTypes.get(extname(file)) ?? "application/octet-stream",
      "cache-control": "no-store"
    });
    createReadStream(file).pipe(response);
  } catch {
    response.writeHead(404).end("Not found");
  }
});

server.listen(port, "127.0.0.1", () => {
  process.stdout.write(`Changliao design demo listening on port ${port}\n`);
});
