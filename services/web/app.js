// services/web/app.js
//
// Minimal client for the Effectivnost 360 API.
//
// Three-step flow:
//   1. Submit free-text -> POST /api/v1/requests -> {request_id, status: draft}
//   2. The user fills required fields (DEMO mode shell).
//   3. POST /api/v1/requests/{id}/submit:
//        200 -> status submitted; show final state.
//        422 -> render missing[] with clause_id + quote.
//        409 -> status already transitioned; refresh.
//
// No localStorage persistence: it would leak PII / draft state across
// sessions and we have not justified the privacy cost.

const API_BASE = (window.location.hostname === "localhost" || window.location.hostname === "127.0.0.1")
  ? "http://localhost:8000"
  : `${window.location.protocol}//${window.location.hostname}:8000`;

const CSRF_TOKEN = "test-token"; // dev token; wisp csrf_known_header_protection accepts this

const DEMO_FIELDS = [
  { name: "destination_city", required: true,  label: "Город назначения",       example: "Казань" },
  { name: "purpose",          required: true,  label: "Цель поездки",           example: "конференция" },
  { name: "start_date",       required: true,  label: "Дата начала (ГГГГ-ММ-ДД)", example: "2026-11-12" },
  { name: "end_date",         required: true,  label: "Дата окончания",         example: "2026-11-14" },
  { name: "funding_source",   required: true,  label: "Источник финансирования", example: "budget | grant" },
  { name: "grant_number",     required: false, label: "Номер гранта (если grant)", example: "RSF-24-1-2" },
  { name: "approver_id",      required: true,  label: "ID руководителя",        example: "uuid" },
];

let currentRequestId = null;
let filledFields = {};

function $(id) { return document.getElementById(id); }
function setStatus(el, text, isError) {
  el.textContent = text;
  el.classList.toggle("error", !!isError);
}

function generateIdempotencyKey() {
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  return "idem-" + Date.now() + "-" + Math.floor(Math.random() * 1e9);
}

async function apiFetch(path, opts) {
  const headers = Object.assign({ "X-CSRF-Token": CSRF_TOKEN }, opts.headers || {});
  const res = await fetch(API_BASE + path, Object.assign({}, opts, { headers }));
  const text = await res.text();
  let body = {};
  try { body = text ? JSON.parse(text) : {}; } catch (_) { body = { raw: text }; }
  return { status: res.status, body };
}

document.addEventListener("DOMContentLoaded", () => {
  $("idempotency_key").value = generateIdempotencyKey();

  $("form-create").addEventListener("submit", async (e) => {
    e.preventDefault();
    const text = $("text").value.trim();
    const key = $("idempotency_key").value.trim();
    if (!text || !key) {
      setStatus($("status-1"), "Заполните текст и ключ", true);
      return;
    }
    setStatus($("status-1"), "Отправляем…");
    try {
      const { status, body } = await apiFetch("/api/v1/requests", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, idempotency_key: key }),
      });
      if (status >= 200 && status < 300) {
        currentRequestId = body.request_id;
        setStatus($("status-1"), `Черновик создан (HTTP ${status})`);
        showStep2(body);
      } else {
        setStatus($("status-1"), `Ошибка: ${status} ${JSON.stringify(body)}`, true);
      }
    } catch (err) {
      setStatus($("status-1"), "Сеть недоступна: " + err.message, true);
    }
  });

  $("btn-submit").addEventListener("click", async () => {
    if (!currentRequestId) return;
    setStatus($("status-2"), "Отправляем…");
    try {
      const { status, body } = await apiFetch(
        "/api/v1/requests/" + encodeURIComponent(currentRequestId) + "/submit",
        { method: "POST" }
      );
      if (status === 200) {
        setStatus($("status-2"), "Отправлено (HTTP 200): " + JSON.stringify(body));
        $("btn-submit").disabled = true;
        renderMissing([]);
        await refreshFromServer();
      } else if (status === 422) {
        setStatus($("status-2"), "Неполная заявка (HTTP 422). Дополните поля.", true);
        renderMissing(body.missing || []);
      } else if (status === 409) {
        setStatus($("status-2"), "Конфликт статуса: " + (body.current_status || "?"), true);
        await refreshFromServer();
      } else {
        setStatus($("status-2"), "Ошибка " + status + ": " + JSON.stringify(body), true);
      }
    } catch (err) {
      setStatus($("status-2"), "Сеть недоступна: " + err.message, true);
    }
  });

  renderDemoFields();
});

async function refreshFromServer() {
  if (!currentRequestId) return;
  try {
    const { status, body } = await apiFetch(
      "/api/v1/requests/" + encodeURIComponent(currentRequestId),
      { method: "GET" }
    );
    if (status === 200) {
      $("request-status").textContent = body.status || "—";
      filledFields = Object.assign({}, body.fields || {});
      renderDemoFields();
    }
  } catch (_) { /* swallow */ }
}

function showStep2(createResp) {
  $("step-1").classList.remove("active");
  $("step-2").classList.add("active");
  $("request-id").textContent = createResp.request_id || "—";
  $("request-status").textContent = createResp.status || "—";
}

function renderDemoFields() {
  const ul = $("missing-fields");
  ul.innerHTML = "";
  for (const f of DEMO_FIELDS) {
    const li = document.createElement("li");
    li.className = "missing";
    li.dataset.field = f.name;
    const label = document.createElement("strong");
    label.textContent = (f.required ? "обязательное" : "необязательное") + " — " + f.label;
    li.appendChild(label);
    li.appendChild(document.createElement("br"));
    const input = document.createElement("input");
    input.type = "text";
    input.placeholder = f.example;
    input.value = filledFields[f.name] || "";
    input.addEventListener("input", () => onFieldInput(f.name, input.value));
    li.appendChild(input);
    ul.appendChild(li);
  }
  refreshMissing();
}

function renderMissing(missing) {
  let box = document.getElementById("server-missing");
  if (!box) {
    box = document.createElement("div");
    box.id = "server-missing";
    $("step-2").insertBefore(box, $("step-2").firstChild.nextSibling);
  }
  box.innerHTML = "";
  if (missing.length === 0) return;
  const h = document.createElement("h3");
  h.textContent = "Что требуется по регламенту";
  box.appendChild(h);
  for (const m of missing) {
    const li = document.createElement("li");
    li.className = "missing";
    const label = document.createElement("strong");
    label.textContent = (m.required ? "обязательное" : "необязательное") +
                        (m.conditional ? " (условное)" : "") +
                        " — " + m.field_name;
    li.appendChild(label);
    if (m.clause_id) {
      const meta = document.createElement("div");
      meta.className = "quote";
      meta.textContent = "Пункт " + m.clause_id + ": " + (m.quote || "(цитата не подтверждена)");
      li.appendChild(meta);
    }
    box.appendChild(li);
  }
}

function onFieldInput(name, value) {
  filledFields[name] = value.trim();
  refreshMissing();
}

function refreshMissing() {
  let missing = [];
  let filled = [];
  for (const f of DEMO_FIELDS) {
    const v = filledFields[f.name];
    const has = v && v.length > 0;
    if (f.required && !has) {
      missing.push(f);
    } else if (has) {
      filled.push(f);
    }
    if (f.name === "grant_number" && filledFields["funding_source"] === "grant" && !has) {
      if (!missing.find((x) => x.name === "grant_number")) missing.push(f);
    }
  }
  const filledUl = $("filled-fields");
  filledUl.innerHTML = "";
  for (const f of filled) {
    const li = document.createElement("li");
    li.textContent = `${f.label}: ${filledFields[f.name]}`;
    filledUl.appendChild(li);
  }
  const missUl = $("missing-fields");
  missUl.innerHTML = "";
  for (const f of missing) {
    const li = document.createElement("li");
    li.className = "missing";
    li.dataset.field = f.name;
    const label = document.createElement("strong");
    label.textContent = (f.required ? "обязательное" : "необязательное") + " — " + f.label;
    li.appendChild(label);
    li.appendChild(document.createElement("br"));
    const input = document.createElement("input");
    input.type = "text";
    input.placeholder = f.example;
    input.value = filledFields[f.name] || "";
    input.addEventListener("input", () => onFieldInput(f.name, input.value));
    li.appendChild(input);
    missUl.appendChild(li);
  }
  $("btn-submit").disabled = missing.length > 0;
  $("complete-msg").textContent =
    missing.length === 0
      ? "Все обязательные поля заполнены — можно отправлять."
      : `Не хватает ${missing.length} обязательных полей.`;
}
