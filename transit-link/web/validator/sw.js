/* Service worker: lets the gate screen open with no connection after the first visit.
   Strategy: network first, fall back to the cache. API calls are never intercepted. */
const CACHE = 'tl-validator-v3';
const ASSETS = [
  './',
  './app.js',
  '../shared/theme.css',
  '../shared/site.css',
  '../shared/api.js',
  '../shared/ui.js',
  'https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.js',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then(cache => Promise.all(ASSETS.map(url => {
        const cross = url.startsWith('http');
        return cache.add(new Request(url, cross ? { mode: 'cors' } : {})).catch(() => {});
      })))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.pathname.startsWith('/api/')) return;
  event.respondWith(
    fetch(event.request)
      .then(res => {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(event.request, copy)).catch(() => {});
        return res;
      })
      .catch(() => caches.match(event.request, { ignoreSearch: true }))
  );
});
