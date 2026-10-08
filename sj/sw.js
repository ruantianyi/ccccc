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

// WebRTC block shim, injected at the top of <head> in every proxied HTML
// document (before any page script runs).
//
// Why: fetch/XHR/WebSocket in proxied pages are tunneled through Wisp, but
// the browser's NATIVE WebRTC stack (RTCPeerConnection) can open direct
// STUN/ICE peer connections that bypass the tunnel entirely, leaking the
// user's real IP to the site. Scramjet 1.1.0 does not interpose on WebRTC,
// so we neuter it here.
//
// How it stays inert: pages that never touch WebRTC only see two window
// properties set to undefined and two mediaDevices functions replaced with
// ones that return a rejected promise. No console output, no exceptions,
// no behavior change unless the page actually tries to use WebRTC — in
// which case feature detection (`if (window.RTCPeerConnection)`) fails
// gracefully and getUserMedia/getDisplayMedia reject exactly like a normal
// "permission denied", both patterns pages already handle.
const WEBRTC_BLOCK_SHIM =
  "<script>(function(){'use strict';" +
  "try{window.RTCPeerConnection=undefined;}catch(e){}" +
  "try{window.webkitRTCPeerConnection=undefined;}catch(e){}" +
  "try{if(navigator.mediaDevices){" +
  "if(navigator.mediaDevices.getUserMedia){" +
  "navigator.mediaDevices.getUserMedia=function(){" +
  "return Promise.reject(new DOMException('WebRTC is disabled by this proxy','NotSupportedError'));};}" +
  "if(navigator.mediaDevices.getDisplayMedia){" +
  "navigator.mediaDevices.getDisplayMedia=function(){" +
  "return Promise.reject(new DOMException('WebRTC is disabled by this proxy','NotSupportedError'));};}" +
  "}}catch(e){}" +
  "})();</script>";

function injectWebrtcBlock(html) {
  // Insert immediately after the opening <head> tag so the shim runs
  // before any page script. Fall back to the very start of the document
  // if there is no <head>.
  if (/<head[^>]*>/i.test(html)) {
    return html.replace(/<head[^>]*>/i, (m) => m + WEBRTC_BLOCK_SHIM);
  }
  return WEBRTC_BLOCK_SHIM + html;
}

// Fail-closed for non-routed requests: if Scramjet doesn't route a URL
// (rewriter miss), do NOT fall back to the browser's native direct fetch,
// which would connect user->origin outside the tunnel and leak the visit.
// Return 403 instead. Routed traffic is unaffected.
function blockedResponse() {
  return new Response('Blocked by proxy: URL not routed through tunnel', {
    status: 403,
    headers: { 'Content-Type': 'text/plain' },
  });
}

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
    if (!res) return blockedResponse();
    // Cross-origin isolation for proxied documents: lets threaded web builds
    // (Godot/Unity, which need SharedArrayBuffer) run inside the proxy.
    // Subresources are same-origin through the SW, so require-corp is
    // satisfiable.
    const headers = new Headers(res.headers);
    headers.set("Cross-Origin-Opener-Policy", "same-origin");
    headers.set("Cross-Origin-Embedder-Policy", "require-corp");
    // Neuter WebRTC in HTML documents: without this, a proxied page could
    // use RTCPeerConnection to open direct STUN/ICE connections that
    // bypass the Wisp tunnel and leak the real IP. Only HTML documents
    // are buffered and rewritten; all other responses stream through
    // untouched. (Status 200 only: 204/304 must not gain a body.)
    const ctype = res.headers.get("content-type") || "";
    if (res.status === 200 && ctype.includes("text/html")) {
      const html = await res.text();
      // Body was decoded and rewritten: drop length/encoding headers so
      // they can't disagree with the new bytes.
      headers.delete("content-length");
      headers.delete("content-encoding");
      headers.delete("transfer-encoding");
      return new Response(injectWebrtcBlock(html), {
        status: res.status,
        statusText: res.statusText,
        headers,
      });
    }
    return new Response(res.body, {
      status: res.status,
      statusText: res.statusText,
      headers,
    });
  }
  return blockedResponse();
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
