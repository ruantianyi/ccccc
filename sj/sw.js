// sw.js — Service Worker bootstrap for the Scramjet proxy.
//
// Served by the Node backend at /sw.js (under the token scope /sj/<token>/).
// importScripts uses a relative URL so the bundle resolves inside the token
// scope regardless of what the token is.
importScripts("./scram/scramjet.all.js");

const { ScramjetServiceWorker } = $scramjetLoadWorker();
const scramjet = new ScramjetServiceWorker();

// Paths under the SW scope that are the backend's own assets, never proxied
// page URLs. (Encoded page URLs never start with these segments.)
const ASSET_PREFIXES = ["/scram/", "/libcurl/", "/epoxy/", "/baremux/", "/wisp/"];

async function handleRequest(event) {
  await scramjet.loadConfig();
  const url = new URL(event.request.url);
  const scopePath = new URL(self.registration.scope).pathname;
  let rel = url.pathname;
  if (rel.startsWith(scopePath)) rel = "/" + rel.slice(scopePath.length);
  if (url.pathname === new URL(self.location.href).pathname ||
      ASSET_PREFIXES.some((p) => rel.startsWith(p))) {
    return fetch(event.request);
  }
  if (scramjet.route(event)) {
    const res = await scramjet.fetch(event);
    if (!res) return fetch(event.request);
    return new Response(res.body, {
      status: res.status,
      statusText: res.statusText,
      headers: res.headers,
    });
  }
  return fetch(event.request);
}

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", (event) => {
  event.respondWith(handleRequest(event));
});
