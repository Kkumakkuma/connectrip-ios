const CACHE_NAME = 'connectrip-v2';
const OFFLINE_URL = '/';

// Install
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll([OFFLINE_URL]);
    })
  );
  self.skipWaiting();
});

// Activate
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))
      );
    })
  );
  self.clients.claim();
});

// Fetch - network first. 네트워크가 아예 끊겼을 때만 캐시한 홈을 보여 준다(2026-09-16 codex 검토).
// 예전에는 서버 오류(!response.ok)도 홈으로 바꿔치기했고, caches.match() 가 Promise 라 `|| response` 가 항상 무시돼
// 캐시가 없으면 undefined 를 돌려줬다. Vercel 이 SPA 경로를 200 으로 돌려주므로 실패 응답은 그대로 보여 주는 게 맞다
// (공개 안내 페이지 /guide/* 가 오류 때 옛 홈 HTML 로 덮이지 않게).
self.addEventListener('fetch', (event) => {
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request).catch(async () => {
        const cached = await caches.match(OFFLINE_URL);
        return cached || Response.error();
      })
    );
  }
});

// Push Notifications
self.addEventListener('push', (event) => {
  const data = event.data?.json() || { title: 'ConnectTrip', body: '새로운 알림이 있습니다.' };
  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: '/icon-192x192.png',
      badge: '/icon-192x192.png',
      data: data.url || '/',
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data));
});
