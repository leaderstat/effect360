// services/frontend/src/effectivnost_360_lustre/http.mjs
//
// Low-level HTTP adapter for the Gleam API client.
//
// Contract with api_client.gleam:
//
//   request(method, path, body, on_success, on_failure) -> void
//
// `on_success(status, text)` is called for ANY HTTP response (2xx, 4xx, 5xx)
// — the Gleam side decides what each status means. `on_failure(reason)` is
// called only when the request could not be completed at all (network error,
// DNS failure, aborted request).
//
// IMPORTANT: paths are RELATIVE. The app is served by the same nginx that
// reverse-proxies `/api/` to the Gleam API, so the browser resolves them
// against the current origin. Never hardcode a Docker-internal hostname
// like "http://api:8000" — the browser cannot resolve that.
//
// Authentication: the bearer token of the current session is kept in
// `sessionStorage` under `e360.session-token` and sent as
// `Authorization: Bearer <token>` on every request. The token is read at
// CALL time, so a token obtained after this module was loaded is still used.

const CSRF_TOKEN = "test-token";
const TOKEN_STORAGE_KEY = "e360.session-token";

/// Read the bearer token of the current session.
/// @returns {string}
export function session_token() {
  try {
    return window.sessionStorage.getItem(TOKEN_STORAGE_KEY) || "";
  } catch (_reason) {
    // Private browsing modes can throw on sessionStorage access.
    return "";
  }
}

/// Store the bearer token of the current session.
/// @param {string} token
export function set_session_token(token) {
  try {
    if (token === "") {
      window.sessionStorage.removeItem(TOKEN_STORAGE_KEY);
    } else {
      window.sessionStorage.setItem(TOKEN_STORAGE_KEY, token);
    }
  } catch (_reason) {
    // Storing the token is best-effort; the request still carries it.
  }
}

export function request(method, path, body, on_success, on_failure) {
  const headers = {
    "content-type": "application/json",
    "x-csrf-token": CSRF_TOKEN,
  };

  const token = session_token();
  if (token !== "") {
    headers["authorization"] = `Bearer ${token}`;
  }

  const options = {
    method: method,
    headers: headers,
  };

  if (method !== "GET" && body !== "") {
    options.body = body;
  }

  let settled = false;
  try {
    fetch(path, options)
      .then((res) => res.text().then((text) => [res.status, text]))
      .then(([status, text]) => {
        settled = true;
        on_success(status, text);
      })
      .catch((reason) => {
        if (settled) return;
        settled = true;
        on_failure(reason instanceof Error ? reason.message : String(reason));
      });
  } catch (reason) {
    // `fetch` throws synchronously on some malformed-request cases.
    on_failure(reason instanceof Error ? reason.message : String(reason));
  }
}
