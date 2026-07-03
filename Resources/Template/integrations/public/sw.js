const CACHE_VERSION = 1;
const CACHE_NAME = `site-v${CACHE_VERSION}`;
const OFFLINE_URL = "/offline/";

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(["/", OFFLINE_URL]))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.filter((k) => k.startsWith("site-") && k !== CACHE_NAME).map((k) => caches.delete(k))
      )
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  const { request } = event;

  if (request.method !== "GET") return;
  const url = new URL(request.url);
  // Never cache the Keystatic admin route or the on-site search index — both
  // change independently of a deploy and would go stale silently.
  if (url.pathname.startsWith("/keystatic/") || url.pathname.startsWith("/pagefind/")) return;

  // Navigation requests: network-first, fall back to cache, then the offline page.
  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request)
        .then((response) => {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
          return response;
        })
        .catch(() => caches.match(request).then((cached) => cached || caches.match(OFFLINE_URL)))
    );
    return;
  }

  // CSS, JS, fonts: stale-while-revalidate.
  const dest = request.destination;
  if (dest === "style" || dest === "script" || dest === "font") {
    event.respondWith(
      caches.match(request).then((cached) => {
        const network = fetch(request).then((response) => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
          }
          return response;
        });
        return cached || network;
      })
    );
    return;
  }

  // Images: cache-first.
  if (dest === "image") {
    event.respondWith(
      caches.match(request).then(
        (cached) =>
          cached ||
          fetch(request).then((response) => {
            if (response.ok) {
              const clone = response.clone();
              caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
            }
            return response;
          })
      )
    );
    return;
  }
});
