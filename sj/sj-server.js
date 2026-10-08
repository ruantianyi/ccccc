// sj-server.js — Scramjet static assets + Wisp backend for Academic Code Tester.
//
// Binds 127.0.0.1:$SJ_PORT only. The Python front door (server.py) enforces the
// per-start proxy token on /sj/<token>/* and reverse-proxies here, so this
// process trusts localhost unconditionally and performs no auth of its own.
//
// Routes:
//   GET /scram/*    -> @mercuryworkshop/scramjet dist (scramjet.all.js, .wasm, .sync.js)
//   GET /libcurl/*  -> @mercuryworkshop/libcurl-transport dist (index.mjs)
//   GET /baremux/*  -> @mercuryworkshop/bare-mux dist (index.js, worker.js)
//   GET /sw.js      -> our service-worker bootstrap (see sw.js)
//   UPGRADE /wisp/  -> wisp-js (raw TCP/UDP tunnel for proxied pages)
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, normalize, extname } from "node:path";
import { createReadStream } from "node:fs";
import { scramjetPath } from "@mercuryworkshop/scramjet/path";
import { libcurlPath } from "@mercuryworkshop/libcurl-transport";
import { baremuxPath } from "@mercuryworkshop/bare-mux/node";
import { server as wisp } from "@mercuryworkshop/wisp-js/server";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
// epoxy-transport has no path export; resolve its dist dir manually.
// (require.resolve may point at lib/index.cjs or dist/index.js depending
// on version — normalize to the dist directory.)
const _epoxyResolved = require.resolve("@mercuryworkshop/epoxy-transport");
const epoxyPath = _epoxyResolved
  .replace(/\/dist\/index\.(js|mjs|cjs)$/, "/dist")
  .replace(/\/lib\/index\.(js|mjs|cjs)$/, "/dist");

const PORT = parseInt(process.env.SJ_PORT || "18091", 10);

// Test-only: allow Wisp to connect to private/reserved IPs. Default is false
// (secure). Needed on VMs whose DNS sandbox-resolves everything to 198.18.x.x.
if (process.env.SJ_ALLOW_PRIVATE === "1") {
  wisp.options.allow_private_ips = true;
}

const MIME = {
  ".js": "application/javascript",
  ".mjs": "application/javascript",
  ".wasm": "application/wasm",
  ".map": "application/json",
  ".json": "application/json",
  ".html": "text/html; charset=utf-8",
  ".css": "text/css",
};

const ROUTES = [
  ["/scram/", scramjetPath],
  ["/libcurl/", libcurlPath],
  ["/epoxy/", epoxyPath],
  ["/baremux/", baremuxPath],
];

let SW_JS = null;
try {
  SW_JS = await readFile(new URL("./sw.js", import.meta.url), "utf8");
} catch (e) {
  console.error("[sj] FATAL: cannot read sw.js:", e.message);
  process.exit(1);
}

function isolationHeaders(res) {
  // Required for the Scramjet WASM rewriter and for SharedArrayBuffer
  // (threaded Godot/Unity web builds) inside proxied pages.
  res.setHeader("Cross-Origin-Opener-Policy", "same-origin");
  res.setHeader("Cross-Origin-Embedder-Policy", "require-corp");
}

function serveFile(res, fullPath) {
  const ext = extname(fullPath).toLowerCase();
  res.setHeader("Content-Type", MIME[ext] || "application/octet-stream");
  // The SW must be re-fetched when we redeploy; versioned bundles cache fine.
  if (fullPath.endsWith("/sw.js") || res.reqPath === "/sw.js") {
    res.setHeader("Cache-Control", "no-store");
  } else {
    res.setHeader("Cache-Control", "public, max-age=3600");
  }
  const stream = createReadStream(fullPath);
  stream.on("error", () => {
    if (!res.headersSent) {
      res.writeHead(404, { "Content-Type": "text/plain" });
    }
    res.end("not found");
  });
  res.writeHead(200);
  stream.pipe(res);
}

function safeJoin(dir, rel) {
  const p = normalize("/" + rel).replace(/^\/+/, "");
  const full = join(dir, p);
  return full.startsWith(dir + "/") || full === dir ? full : null;
}

const server = createServer((req, res) => {
  res.reqPath = new URL(req.url, "http://127.0.0.1").pathname;
  isolationHeaders(res);
  // Service-Worker-Allowed lets the SW cover the whole token scope.
  res.setHeader("Service-Worker-Allowed", "/");

  const pathname = res.reqPath;

  if (req.method === "GET" && pathname === "/sw.js") {
    res.setHeader("Content-Type", "application/javascript");
    res.setHeader("Cache-Control", "no-store");
    res.writeHead(200);
    res.end(SW_JS);
    return;
  }

  if (req.method === "GET" || req.method === "HEAD") {
    for (const [prefix, dir] of ROUTES) {
      if (pathname.startsWith(prefix)) {
        const full = safeJoin(dir, pathname.slice(prefix.length));
        if (!full) break;
        serveFile(res, full);
        return;
      }
    }
  }

  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("not found");
});

server.on("upgrade", (req, socket, head) => {
  let pathname = "/";
  try {
    pathname = new URL(req.url, "http://127.0.0.1").pathname;
  } catch {}
  if (pathname === "/wisp/" || pathname.endsWith("/wisp/")) {
    wisp.routeRequest(req, socket, head);
  } else {
    socket.destroy();
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[sj] scramjet backend on 127.0.0.1:${PORT}`);
});
