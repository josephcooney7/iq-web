/* Makes the site installable and lets the pages open with a weak signal.
   Always tries the network first so changes show up straight away. Data calls to Supabase are never cached. */
const CACHE = "iq-shell-v7";
const SHELL = ["/", "/dashboard", "/setup", "/css/common.css", "/js/app.js", "/client", "/gear", "/schedule", "/js/schedule.js", "/js/sheet-read.js", "/scan", "/css/gear.css", "/js/gear.js", "/js/sop.js", "/js/supabase.js", "/manifest.webmanifest", "/icons/icon-192.png", "/icons/stapleton-logo.png"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).catch(() => {}));
  self.skipWaiting();
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET" || new URL(req.url).origin !== location.origin) return;
  e.respondWith(
    fetch(req).then((res) => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
      return res;
    }).catch(() => caches.match(req).then((hit) => hit || (req.mode === "navigate" ? caches.match("/setup") : undefined)))
  );
});
