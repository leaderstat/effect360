// services/frontend/src/effectivnost_360_lustre/random_key.mjs
//
// Tiny helpers for the Lustre spike.

export function random_key() {
  if (typeof crypto !== "undefined" && crypto.randomUUID) {
    return crypto.randomUUID();
  }
  return "idem-" + Date.now() + "-" + Math.floor(Math.random() * 1e9);
}
