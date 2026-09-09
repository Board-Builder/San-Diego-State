/* Minimal offline shell. Bump CACHE_VERSION when you deploy app changes. */
const CACHE_VERSION = "board-san-diego-state-a5c8eef261";
const SHELL = ["./", "./index.html", "./app.js", "./config.js", "./manifest.json", "./icon-192.png", "./icon-512.png", "./apple-touch-icon.png"];
self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE_VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE_VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", (e) => {
  if (e.request.method !== "GET") return;
  e.respondWith(
    fetch(e.request).then((res) => {
      const copy = res.clone();
      caches.open(CACHE_VERSION).then((c) => c.put(e.request, copy)).catch(() => {});
      return res;
    }).catch(() => caches.match(e.request).then((m) => m || caches.match("./index.html")))
  );
});

/* ---------- phone push (Web Push) ----------
   Payload from the school's `notify` Edge Function:
   { title, body, tag?, url?, taskId? }. Tapping focuses the app (or opens
   it) and tells the page which assignment to show. */
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { title: "The Board", body: e.data ? e.data.text() : "" }; }
  const title = d.title || "The Board";
  const opts = {
    body: d.body || "",
    icon: "./icon-192.png",
    badge: "./icon-192.png",
    tag: d.tag || (d.taskId ? "task-" + d.taskId : "board"),
    renotify: !!d.taskId,
    data: { url: d.url || "./", taskId: d.taskId || null },
  };
  e.waitUntil(self.registration.showNotification(title, opts));
});
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const data = (e.notification && e.notification.data) || {};
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const target = all.find((c) => "focus" in c);
    if (target) {
      try { await target.focus(); } catch (err) { /* best effort */ }
      target.postMessage({ type: "board:openTask", id: data.taskId });
      return;
    }
    const c = await self.clients.openWindow(data.url || "./");
    if (c && data.taskId) setTimeout(() => { try { c.postMessage({ type: "board:openTask", id: data.taskId }); } catch (err) {} }, 2500);
  })());
});
