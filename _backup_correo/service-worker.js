const CACHE_NAME = "aulaya-shell-v28";
const APP_FILES = [
  "./", "./index.html", "./styles.css", "./app.js", "./question-bank.js", "./database.js", "./supabase-config.js",
  "./manifest.json", "./assets/teo-ai.bundle.js",
  "./assets/PERFILSAM.png", "./assets/notification-icon.png", "./assets/lengua-icon.svg",
  "./assets/Iniciosam.png", "./assets/Lenguajeoriginal-sin-fondo.png",
  "./assets/student-home-landscape.png", "./assets/matematicas.svg", "./assets/aulaya-mascot.png", "./assets/teacher-profile-avatar.png", "./assets/teacher-avatar-options.png", "./assets/teacher-character-1.png", "./assets/teacher-character-2.png", "./assets/teacher-character-3.png", "./assets/teacher-character-4.png", "./assets/teacher-character-5.png", "./assets/teacher-character-6.png", "./assets/teacher-character-7.png", "./assets/teacher-character-8.png", "./assets/teacher-welcome-background.png", "./assets/role-student.png", "./assets/role-teacher.png", "./assets/role-student-solo.png", "./assets/role-teacher-solo.png", "./assets/profile-corner-plants.png",
  "./assets/mondeaconlogo.png", "./assets/Descargaslogosam.png", "./assets/LogoSML.png", "./assets/librosnoprogreso.png",
  "./assets/socialessam.png", "./assets/Lenguanuevo.png", "./assets/aulaya-logo-white.png",
  "./assets/Matematicasoriginal.png", "./assets/downloads-icon.svg", "./assets/Ciencias.png",
  "./assets/inglessam.png", "./assets/NotificaciónNuevosam.png",
  "./assets/personalizcionsam.png"
];
self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_FILES)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key.startsWith("aulaya-shell-") && key !== CACHE_NAME).map((key) => caches.delete(key)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET" || new URL(request.url).origin !== self.location.origin) return;
  event.respondWith(caches.match(request).then((cached) => cached || fetch(request).then((response) => {
    if (response.ok) caches.open(CACHE_NAME).then((cache) => cache.put(request, response.clone()));
    return response;
  }).catch(() => request.mode === "navigate" ? caches.match("./index.html") : Response.error())));
});
