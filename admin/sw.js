/* Coach Gari back-office — service worker (scope /admin/ only; the public site has none).

   What it does: makes the back-office installable and keeps its SHELL available offline —
   the HTML, the two stylesheets, the scripts, the config, the manifest and icons, the
   supabase-js UMD build and the web fonts. Shell files: stale-while-revalidate (served from
   cache at once, refreshed in the background; a new version replaces the cache on activate).
   What it never does: cache data. Every request to Supabase (REST, RPC, auth, Edge
   Functions) goes to the network untouched and is never stored — nothing from the CRM,
   the calendar, the finance or the emails lives in this cache. Offline, a data request
   simply fails and the app shows its own error; the shell still opens. */
const VERSION = 'cg-admin-v1';
const SHELL = [
  '/admin/', '/admin/index.html', '/admin/admin.css', '/admin/admin.js', '/admin/finance.js',
  '/admin/manifest.webmanifest', '/admin/icons/icon-192.png', '/admin/icons/icon-512.png', '/admin/icons/maskable-512.png',
  '/assets/coach-gari.css', '/config.js',
];
const SHELL_HOSTS = ['cdn.jsdelivr.net', 'fonts.googleapis.com', 'fonts.gstatic.com'];   // static third-party files the shell needs, never data

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});

function isShell(url) {
  if (url.origin === self.location.origin) {
    if (url.pathname.startsWith('/admin/')) return !url.pathname.endsWith('/sw.js');
    return url.pathname.startsWith('/assets/') || url.pathname === '/config.js';
  }
  return SHELL_HOSTS.includes(url.hostname);
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;                       // never touch writes
  const url = new URL(req.url);
  if (url.hostname.endsWith('.supabase.co')) return;      // data + auth: network only, never cached
  if (req.mode === 'navigate') {                          // the app entry: network first, cached shell when offline
    e.respondWith(fetch(req).then((r) => { const copy = r.clone(); caches.open(VERSION).then((c) => c.put('/admin/index.html', copy)); return r; })
      .catch(() => caches.match('/admin/index.html')));
    return;
  }
  if (!isShell(url)) return;
  e.respondWith(caches.open(VERSION).then(async (c) => {
    const cached = await c.match(req);
    const refresh = fetch(req).then((r) => { if (r.ok) c.put(req, r.clone()); return r; }).catch(() => cached);
    return cached || refresh;
  }));
});
