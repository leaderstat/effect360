// services/frontend/src/effectivnost_360_lustre/nav.mjs
//
// Navigation helpers for the CJM screen map.
//
// Routing model
// -------------
// The routes are served by nginx (services/frontend/nginx.conf):
//
//   /                → S0 Старт
//   /describe        → S1 Описание
//   /request/<uuid>  → S2 Уточнения / S4 Результат
//
// Navigation is therefore a FULL PAGE LOAD, not an in-app route change.
// That is deliberate: after F5 the browser must be able to restore the
// request from its URL, and the state must come from the server, not from
// client memory. See docs/architecture/cjm-screen-map.md §6.
//
// `navigate_to` is called from inside an effect. The effect then dispatches
// `Navigate(path)`, but because the page is already unloading the dispatch
// is harmless — the state update is only a safety net for the case where
// navigation is blocked.

export function current_path(_flags) {
  if (typeof window === "undefined") return "/";
  const path = window.location.pathname || "/";
  return path.length === 0 ? "/" : path;
}

export function navigate_to(path) {
  if (typeof window === "undefined") return;
  if (window.location.pathname === path) return;
  window.location.assign(path);
}
