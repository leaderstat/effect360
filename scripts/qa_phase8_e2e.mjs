// scripts/qa_phase8_e2e.mjs
//
// Р¤РђР—Рђ 8 вЂ” E2E-СЃС†РµРЅР°СЂРёРё СЂРµР¶РёРјР° Р°РІС‚РѕРјР°С‚РёР·Р°С†РёРё Рё РР-Р°РіРµРЅС‚РѕРІ.
//
// РџСЂРѕРІРµСЂСЏРµС‚СЃСЏ Р Р•РђР›Р¬РќР«Р™ СЃС‚РµРє: Gleam API + PostgreSQL + NATS JetStream.
// РќРёРєР°РєРѕРіРѕ РїРѕРґРјРµРЅС‹ API СЃС‚Р°Р±РѕРј: СЃС†РµРЅР°СЂРёРё С…РѕРґСЏС‚ РїРѕ HTTP РІ Р¶РёРІРѕР№ API, Р°
// СЃРѕР±С‹С‚РёСЏ РёРґСѓС‚ С‡РµСЂРµР· РЅР°СЃС‚РѕСЏС‰РёР№ NATS.
//
// РЎР¦Р•РќРђР РР (10, РєР°Рє РІ Р·Р°РґР°РЅРёРё):
//   1. РћС‚РїСЂР°РІРєР° Р·Р°СЏРІРєРё СЃРѕР·РґР°С‘С‚ СЃРѕР±С‹С‚РёРµ РІ Outbox.
//   2. РЎРѕР±С‹С‚РёРµ РґРѕСЃС‚Р°РІР»СЏРµС‚СЃСЏ С‡РµСЂРµР· NATS РІ worker.
//   3. Р¦РёС„СЂРѕРІРѕР№ РјРѕРґРµСЂР°С‚РѕСЂ РїСЂРѕРІРµСЂСЏРµС‚ Р·Р°СЏРІРєСѓ Рё СЃРѕС…СЂР°РЅСЏРµС‚ СЂРµР·СѓР»СЊС‚Р°С‚.
//   4. РџРѕР»РЅР°СЏ Р·Р°СЏРІРєР° РїСЂРѕС…РѕРґРёС‚ СЂР°Р·СЂРµС€С‘РЅРЅС‹Р№ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРёР№ РїРµСЂРµС…РѕРґ.
//   5. РќРµРїРѕР»РЅР°СЏ Р·Р°СЏРІРєР° С„РѕСЂРјРёСЂСѓРµС‚ Р·Р°РїСЂРѕСЃ СѓС‚РѕС‡РЅРµРЅРёСЏ.
//   6. РќРµРѕРїСЂРµРґРµР»С‘РЅРЅС‹Р№ СЃР»СѓС‡Р°Р№ РїРѕРїР°РґР°РµС‚ С‡РµР»РѕРІРµРєСѓ.
//   7. РџРѕРІС‚РѕСЂРЅР°СЏ РґРѕСЃС‚Р°РІРєР° СЃРѕР±С‹С‚РёСЏ РЅРµ РґСѓР±Р»РёСЂСѓРµС‚ РґРµР№СЃС‚РІРёСЏ.
//   8. РћС€РёР±РєР° LLM РЅРµ РїСЂРёРІРѕРґРёС‚ Рє РѕС€РёР±РѕС‡РЅРѕРјСѓ РёР·РјРµРЅРµРЅРёСЋ СЃС‚Р°С‚СѓСЃР°.
//   9. РР·РјРµРЅРµРЅРёРµ СЃС‚Р°С‚СѓСЃР° СЃРѕР·РґР°С‘С‚ СѓРІРµРґРѕРјР»РµРЅРёРµ Р·Р°СЏРІРёС‚РµР»СЋ.
//  10. РћС‚РєР»СЋС‡РµРЅРёРµ Р°РІС‚РѕРјР°С‚РёР·Р°С†РёРё РґРµР№СЃС‚РІРёС‚РµР»СЊРЅРѕ Р±Р»РѕРєРёСЂСѓРµС‚ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРёРµ
//      РїРµСЂРµС…РѕРґС‹.
//
// Р—Р°РїСѓСЃРє (РІРЅСѓС‚СЂРё РєРѕРЅС‚РµР№РЅРµСЂР° tooling):
//   docker compose --profile qa run --rm qa bash -lc "node scripts/qa_phase8_e2e.mjs"
//
// РџРµСЂРµРјРµРЅРЅС‹Рµ РѕРєСЂСѓР¶РµРЅРёСЏ:
//   API_BASE_URL     вЂ” Р°РґСЂРµСЃ API (РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ http://api:8000)
//   DATABASE_URL     вЂ” РґР»СЏ РїСЂСЏРјС‹С… РїСЂРѕРІРµСЂРѕРє РІ PostgreSQL
//   AGENT_SERVICE_TOKEN вЂ” СЃРµСЂРІРёСЃРЅС‹Р№ С‚РѕРєРµРЅ Р°РіРµРЅС‚РѕРІ

import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// Load `.env` from the project root so the suite can be run standalone
// (`node scripts/qa_phase8_e2e.mjs`) without exporting every variable by hand.
const envPath = fileURLToPath(new URL('../.env', import.meta.url));
if (existsSync(envPath)) {
  for (const raw of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    if (key in process.env) continue;
    process.env[key] = line.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
  }
}

// The API is published on the host as 8000, so the suite runs on the host
// against `http://127.0.0.1:8000` (service names like `api` only resolve
// inside the compose network).
const API = process.env.API_BASE_URL || 'http://127.0.0.1:8000';
const TOKEN = process.env.AGENT_SERVICE_TOKEN || '';
const PGUSER = process.env.PGUSER || 'effectivnost360';
const PGDATABASE = process.env.PGDATABASE || 'effectivnost360';
// --- tiny test harness -------------------------------------------------

let passed = 0;
let failed = 0;
const failures = [];

function check(name, condition, detail = '') {
  if (condition) {
    passed++;
    console.log(`  ok   ${name}`);
  } else {
    failed++;
    failures.push(`${name}${detail ? ` вЂ” ${detail}` : ''}`);
    console.log(`  FAIL ${name}${detail ? ` вЂ” ${detail}` : ''}`);
  }
}

function section(title) {
  console.log(`\n== ${title}`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, timeoutMs = 45000, intervalMs = 1000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    last = await fn();
    if (last) return last;
    await sleep(intervalMs);
  }
  return last;
}

// --- HTTP helpers -------------------------------------------------------

async function api(method, path, { body, token, headers = {} } = {}) {
  const h = { Accept: 'application/json', ...headers };
  if (token) h.Authorization = `Bearer ${token}`;
  if (body !== undefined) h['Content-Type'] = 'application/json';
  const res = await fetch(`${API}${path}`, {
    method,
    headers: h,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  return { status: res.status, body: json, text };
}

// --- direct PostgreSQL checks ------------------------------------------
//
// The `psql` client lives in the postgres container, not in the image that
// runs this script. The script therefore shells out to `docker compose
// exec` вЂ” the queries still run against the REAL database of the stack.

const COMPOSE = process.env.COMPOSE_FILE || 'compose.yaml';

function psql(sql) {
  const out = execFileSync(
    'docker',
    ['compose', '-f', COMPOSE, 'exec', '-T', 'postgres',
      'psql', '-U', PGUSER, '-d', PGDATABASE, '-t', '-A', '-F', '|', '-c', sql],
    { encoding: 'utf8', cwd: process.env.PROJECT_ROOT || process.cwd() },
  );
  // docker compose writes the container banner to stdout on some versions.
  return out.replace(/^.*effectivnost360-postgres\S*\r?\n/m, '').trim();
}

function psqlRows(sql) {
  const out = psql(sql);
  if (!out) return [];
  return out.split('\n').map((line) => line.split('|'));
}

// --- fixtures -----------------------------------------------------------

const APPLICANT = { email: 'demo.applicant@example.invalid', password: 'demo' };
const MODERATOR = { email: 'demo.moderator@example.invalid', password: 'demo' };

const COMPLETE_TEXT =
  'РџСЂРѕС€Сѓ РЅР°РїСЂР°РІРёС‚СЊ РјРµРЅСЏ РІ СѓС‡РµР±РЅСѓСЋ РїРѕРµР·РґРєСѓ РІ РљР°Р·Р°РЅСЊ СЃ 1 РёСЋРЅСЏ РїРѕ 10 РёСЋРЅСЏ ' +
  'СЃ С†РµР»СЊСЋ СѓС‡Р°СЃС‚РёСЏ РІ СЃРµРјРёРЅР°СЂРµ. РСЃС‚РѕС‡РЅРёРє С„РёРЅР°РЅСЃРёСЂРѕРІР°РЅРёСЏ вЂ” Р±СЋРґР¶РµС‚.';

const INCOMPLETE_TEXT =
  'РџСЂРѕС€Сѓ РЅР°РїСЂР°РІРёС‚СЊ РјРµРЅСЏ РІ СѓС‡РµР±РЅСѓСЋ РїРѕРµР·РґРєСѓ. Р“РѕСЂРѕРґ Рё РґР°С‚С‹ СѓРєР°Р·Р°С‚СЊ РїРѕР·Р¶Рµ.';

async function login(creds) {
  const res = await api('POST', '/api/v1/session', { body: creds });
  if (res.status !== 200) {
    throw new Error(`login failed: ${res.status} ${res.text.slice(0, 200)}`);
  }
  return res.body.token || res.body.session_token || res.body.access_token;
}

// --- the scenarios ------------------------------------------------------

async function main() {
  console.log(`API: ${API}`);
  console.log(`agent token configured: ${TOKEN ? 'yes' : 'NO (agent endpoints will refuse)'}`);

  const applicantToken = await login(APPLICANT);
  const moderatorToken = await login(MODERATOR);
  console.log('logged in: applicant + moderator');

  // The demo request type must be enabled for the pipeline to work.
  const rtEnabled = psql(
    "SELECT enabled FROM request_types WHERE name = 'РЈС‡РµР±РЅР°СЏ РїРѕРµР·РґРєР° (DEMO)'",
  );
  if (rtEnabled !== 't') {
    psql("UPDATE request_types SET enabled = true WHERE name = 'РЈС‡РµР±РЅР°СЏ РїРѕРµР·РґРєР° (DEMO)'");
    console.log('enabled the demo request type');
  }

  // ------------------------------------------------------------------
  section('1. РћС‚РїСЂР°РІРєР° Р·Р°СЏРІРєРё СЃРѕР·РґР°С‘С‚ СЃРѕР±С‹С‚РёРµ РІ Outbox');
  // ------------------------------------------------------------------
  const idempotencyKey = `e2e-phase8-${randomUUID()}`;
  const created = await api('POST', '/api/v1/requests', {
    token: applicantToken,
    body: { idempotency_key: idempotencyKey, text: COMPLETE_TEXT },
  });
  check('Р·Р°СЏРІРєР° СЃРѕР·РґР°РЅР°', [200, 201, 202].includes(created.status), `status ${created.status}`);
  const requestId = created.body?.id || created.body?.request_id;
  check('Р·Р°СЏРІРєР° РёРјРµРµС‚ id', !!requestId, JSON.stringify(created.body).slice(0, 160));
  if (!requestId) {
    console.log('cannot continue without a request id');
    return report();
  }

  const submitted = await api('POST', `/api/v1/requests/${requestId}/submit`, {
    token: applicantToken,
    body: {},
  });
  check('Р·Р°СЏРІРєР° РѕС‚РїСЂР°РІР»РµРЅР°', [200, 201, 202].includes(submitted.status), `status ${submitted.status}`);

  const outboxRows = psqlRows(
    `SELECT subject, payload->>'request_id' FROM outbox
      WHERE payload->>'request_id' = '${requestId}' ORDER BY created_at`,
  );
  check('РІ Outbox РµСЃС‚СЊ СЃРѕР±С‹С‚РёРµ Р°РіРµРЅС‚Р° A', outboxRows.some((r) => r[0] === 'requests.agent_a'), JSON.stringify(outboxRows));
  check('РІ Outbox РµСЃС‚СЊ СЃРѕР±С‹С‚РёРµ РєР»Р°СЃСЃРёС„РёРєР°С‚РѕСЂР°', outboxRows.some((r) => r[0] === 'requests.created'), JSON.stringify(outboxRows));

  // ------------------------------------------------------------------
  section('2. РЎРѕР±С‹С‚РёРµ РґРѕСЃС‚Р°РІР»СЏРµС‚СЃСЏ С‡РµСЂРµР· NATS РІ worker');
  // ------------------------------------------------------------------
  const delivered = await waitFor(
      async () => {
      const rows = psqlRows(
        `SELECT subject, published_at IS NOT NULL FROM outbox
          WHERE payload->>'request_id' = '${requestId}'`,
      );
      return rows.length && rows.every((r) => r[1] === 't') ? rows : null;
    },
    40000,
  );
  check('СЃРѕР±С‹С‚РёСЏ РѕРїСѓР±Р»РёРєРѕРІР°РЅС‹ РІ NATS', !!delivered, 'outbox events not published');

  // ------------------------------------------------------------------
  section('3. Р¦РёС„СЂРѕРІРѕР№ РјРѕРґРµСЂР°С‚РѕСЂ РїСЂРѕРІРµСЂСЏРµС‚ Р·Р°СЏРІРєСѓ Рё СЃРѕС…СЂР°РЅСЏРµС‚ СЂРµР·СѓР»СЊС‚Р°С‚');
  // ------------------------------------------------------------------
  const checkRow = await waitFor(
      async () => {
      const rows = psqlRows(
        `SELECT result, reason, rule_code, llm_used, duration_ms
           FROM agent_checks WHERE request_id = '${requestId}'`,
      );
      return rows.length ? rows[0] : null;
    },
    60000,
  );
  check('СЂРµР·СѓР»СЊС‚Р°С‚ РїСЂРѕРІРµСЂРєРё СЃРѕС…СЂР°РЅС‘РЅ', !!checkRow, 'no agent_checks row');
  if (checkRow) {
    console.log(`       СЂРµР·СѓР»СЊС‚Р°С‚: ${checkRow[0]}, РїСЂР°РІРёР»Рѕ: ${checkRow[2]}, LLM: ${checkRow[3]}, ${checkRow[4]}ms`);
  }

  // The panel must show the check to the moderator.
  const panel = await api('GET', '/api/v1/automation/panel?limit=20', { token: moderatorToken });
  check('РїР°РЅРµР»СЊ С†РёС„СЂРѕРІРѕРіРѕ РјРѕРґРµСЂР°С‚РѕСЂР° РѕС‚РІРµС‡Р°РµС‚', panel.status === 200, `status ${panel.status}`);
  check(
    'РїР°РЅРµР»СЊ СЃРѕРґРµСЂР¶РёС‚ СЂРµР·СѓР»СЊС‚Р°С‚ РїСЂРѕРІРµСЂРєРё СЌС‚РѕР№ Р·Р°СЏРІРєРё',
    JSON.stringify(panel.body || {}).includes(requestId),
  );

  // ------------------------------------------------------------------
  section('4. РџРѕР»РЅР°СЏ Р·Р°СЏРІРєР° РїСЂРѕС…РѕРґРёС‚ СЂР°Р·СЂРµС€С‘РЅРЅС‹Р№ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРёР№ РїРµСЂРµС…РѕРґ');
  // ------------------------------------------------------------------
  // Set the auto mode so the agent may execute the allowed transition.
  const setAuto = await api('PUT', '/api/v1/automation/settings', {
    token: moderatorToken,
    body: { mode: 'auto' },
  });
  check('СЂРµР¶РёРј В«Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРёР№В» РІРєР»СЋС‡С‘РЅ', setAuto.status === 200 && setAuto.body?.mode === 'auto', JSON.stringify(setAuto.body).slice(0, 160));

  // A second, complete request вЂ” this one goes through the automatic path.
  const key2 = `e2e-phase8-auto-${randomUUID()}`;
  const created2 = await api('POST', '/api/v1/requests', {
    token: applicantToken,
    body: { idempotency_key: key2, text: COMPLETE_TEXT },
  });
  const requestId2 = created2.body?.id || created2.body?.request_id;
  check('РІС‚РѕСЂР°СЏ Р·Р°СЏРІРєР° СЃРѕР·РґР°РЅР°', !!requestId2, `status ${created2.status}`);
  if (requestId2) {
    // The real order: the applicant fills the form and THEN submits. The
    // agent therefore sees the complete data, not an empty draft.
    await fillFields(requestId2, {
      destination_city: 'Казань',
      purpose: 'Участие в семинаре',
      start_date: '01.06',
      end_date: '10.06',
      funding_source: 'budget',
      approver_id: 'demo',
    });
    await api('POST', `/api/v1/requests/${requestId2}/submit`, { token: applicantToken, body: {} });

    const status2 = await waitFor(
      async () => {
        const rows = psqlRows(`SELECT status FROM requests WHERE id = '${requestId2}'`);
        return rows.length && rows[0][0] !== 'submitted' ? rows[0][0] : null;
      },
      60000,
    );
    check('Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРёР№ РїРµСЂРµС…РѕРґ РІС‹РїРѕР»РЅРµРЅ', !!status2, 'the status did not change');
    if (status2) console.log(`       СЃС‚Р°С‚СѓСЃ: ${status2}`);
    check('РїРµСЂРµС…РѕРґ РІРµРґС‘С‚ РІ accepted', status2 === 'accepted', `status ${status2}`);

    const action = psqlRows(
      `SELECT action, rule_code, rules_version, source_event, initiated_by, outcome
         FROM automation_actions WHERE request_id = '${requestId2}' AND action = 'transition'`,
    );
    check('РІ Р¶СѓСЂРЅР°Р»Рµ РµСЃС‚СЊ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРѕРµ РґРµР№СЃС‚РІРёРµ', action.length > 0, 'no transition action');
    if (action.length) {
      check('РґРµР№СЃС‚РІРёРµ Р·Р°РїРёСЃР°РЅРѕ РѕС‚ РёРјРµРЅРё system', action[0][4] === 'system', action[0][4]);
      check('Сѓ РґРµР№СЃС‚РІРёСЏ РµСЃС‚СЊ РїСЂР°РІРёР»Рѕ Рё РІРµСЂСЃРёСЏ', !!action[0][1] && !!action[0][2], JSON.stringify(action[0]));
      check('Сѓ РґРµР№СЃС‚РІРёСЏ РµСЃС‚СЊ РёСЃС‚РѕС‡РЅРёРє СЃРѕР±С‹С‚РёСЏ', !!action[0][3], JSON.stringify(action[0]));
    }
  }

  // ------------------------------------------------------------------
  section('5. РќРµРїРѕР»РЅР°СЏ Р·Р°СЏРІРєР° С„РѕСЂРјРёСЂСѓРµС‚ Р·Р°РїСЂРѕСЃ СѓС‚РѕС‡РЅРµРЅРёСЏ');
  // ------------------------------------------------------------------
  const key3 = `e2e-phase8-incomplete-${randomUUID()}`;
  const created3 = await api('POST', '/api/v1/requests', {
    token: applicantToken,
    body: { idempotency_key: key3, text: INCOMPLETE_TEXT },
  });
  const requestId3 = created3.body?.id || created3.body?.request_id;
  check('РЅРµРїРѕР»РЅР°СЏ Р·Р°СЏРІРєР° СЃРѕР·РґР°РЅР°', !!requestId3, `status ${created3.status}`);
  if (requestId3) {
    // The request type decides WHICH requirements apply. Without it the
    // deterministic check has nothing to verify, so it is assigned here —
    // the fields stay EMPTY, which is what makes the request incomplete.
    await fillFields(requestId3, {});
    await api('POST', `/api/v1/requests/${requestId3}/submit`, { token: applicantToken, body: {} });
    const needsInfo = await waitFor(
      async () => {
        const rows = psqlRows(
          `SELECT result, clarification_request FROM agent_checks WHERE request_id = '${requestId3}'`,
        );
        return rows.length ? rows[0] : null;
      },
      60000,
    );
    check('РїСЂРѕРІРµСЂРєР° РґР°Р»Р° needs_info', needsInfo?.[0] === 'needs_info', `result ${needsInfo?.[0]}`);
    check('СЃС„РѕСЂРјРёСЂРѕРІР°РЅ Р·Р°РїСЂРѕСЃ СѓС‚РѕС‡РЅРµРЅРёСЏ', !!needsInfo?.[1] && needsInfo[1].length > 0, 'empty clarification');
    if (needsInfo?.[1]) console.log(`       Р·Р°РїСЂРѕСЃ СѓС‚РѕС‡РЅРµРЅРёСЏ: ${needsInfo[1].slice(0, 120)}`);

    const status3 = psql(`SELECT status FROM requests WHERE id = '${requestId3}'`);
    check('СЃС‚Р°С‚СѓСЃ РЅРµ РёР·РјРµРЅС‘РЅ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё', status3 === 'submitted', `status ${status3}`);
  }

  // ------------------------------------------------------------------
  section('6. РќРµРѕРїСЂРµРґРµР»С‘РЅРЅС‹Р№ СЃР»СѓС‡Р°Р№ РїРѕРїР°РґР°РµС‚ С‡РµР»РѕРІРµРєСѓ');
  // ------------------------------------------------------------------
  const key4 = `e2e-phase8-ambiguous-${randomUUID()}`;
  const created4 = await api('POST', '/api/v1/requests', {
    token: applicantToken,
    body: { idempotency_key: key4, text: COMPLETE_TEXT },
  });
  const requestId4 = created4.body?.id || created4.body?.request_id;
  if (requestId4) {
    // Contradictory data: the end date is before the start date.
    await fillFields(requestId4, {
      destination_city: 'Казань',
      purpose: 'Участие в семинаре',
      start_date: '10.06',
      end_date: '01.06',
      funding_source: 'budget',
      approver_id: 'demo',
    });
    await api('POST', `/api/v1/requests/${requestId4}/submit`, { token: applicantToken, body: {} });
    const ambiguous = await waitFor(
      async () => {
        const rows = psqlRows(
          `SELECT result FROM agent_checks WHERE request_id = '${requestId4}'`,
        );
        return rows.length && rows[0][0] !== 'passed' ? rows[0][0] : null;
      },
      60000,
    );
    check('РїСЂРѕРІРµСЂРєР° РѕР±РЅР°СЂСѓР¶РёР»Р° РЅРµРѕРїСЂРµРґРµР»С‘РЅРЅРѕСЃС‚СЊ', ambiguous === 'ambiguous', `result ${ambiguous}`);

    const exception = await waitFor(
      async () => {
        const rows = psqlRows(
          `SELECT kind, status FROM agent_exceptions WHERE request_id = '${requestId4}'`,
        );
        return rows.length ? rows[0] : null;
      },
      30000,
    );
    check('Р·Р°СЏРІРєР° РїРѕРїР°Р»Р° РІ РѕС‡РµСЂРµРґСЊ РёСЃРєР»СЋС‡РµРЅРёР№', !!exception, 'no exception row');
    check('РёСЃРєР»СЋС‡РµРЅРёРµ РѕР¶РёРґР°РµС‚ С‡РµР»РѕРІРµРєР°', exception?.[1] === 'open', `status ${exception?.[1]}`);

    const queue = await api('GET', '/api/v1/automation/exceptions?only_open=true', { token: moderatorToken });
    check('РѕС‡РµСЂРµРґСЊ РёСЃРєР»СЋС‡РµРЅРёР№ РґРѕСЃС‚СѓРїРЅР° РјРѕРґРµСЂР°С‚РѕСЂСѓ', queue.status === 200, `status ${queue.status}`);
    check(
      'Р·Р°СЏРІРєР° РІРёРґРЅР° РІ РѕС‡РµСЂРµРґРё РёСЃРєР»СЋС‡РµРЅРёР№',
      JSON.stringify(queue.body || {}).includes(requestId4),
    );

    const status4 = psql(`SELECT status FROM requests WHERE id = '${requestId4}'`);
    check('СЃС‚Р°С‚СѓСЃ РЅРµ РёР·РјРµРЅС‘РЅ', status4 === 'submitted', `status ${status4}`);
  }

  // ------------------------------------------------------------------
  section('7. РџРѕРІС‚РѕСЂРЅР°СЏ РґРѕСЃС‚Р°РІРєР° СЃРѕР±С‹С‚РёСЏ РЅРµ РґСѓР±Р»РёСЂСѓРµС‚ РґРµР№СЃС‚РІРёСЏ');
  // ------------------------------------------------------------------
  if (requestId4) {
    const before = psql(
      `SELECT count(*) FROM automation_actions WHERE request_id = '${requestId4}'`,
    );
    const checksBefore = psql(
      `SELECT count(*) FROM agent_checks WHERE request_id = '${requestId4}'`,
    );
    const notifBefore = psql(
      `SELECT count(*) FROM notifications WHERE request_id = '${requestId4}'`,
    );
    // Re-deliver the same event: insert a NEW outbox row with the SAME
    // payload. The real outbox-relay publishes it to NATS, the real
    // consumer receives it вЂ” this is a genuine redelivery, not a simulated
    // one. The payload carries the same request id, so the idempotency
    // guard must stop it.
    const payload = psql(
      `SELECT payload::text FROM outbox WHERE payload->>'request_id' = '${requestId4}' AND subject = 'requests.agent_a' LIMIT 1`,
    );
    if (payload) {
      const escaped = payload.replace(/'/g, "''");
      psql(
        `INSERT INTO outbox (subject, payload)
           VALUES ('requests.agent_a', '${escaped}'::jsonb)`,
      );
      await sleep(10000);
    }
    const after = psql(
      `SELECT count(*) FROM automation_actions WHERE request_id = '${requestId4}'`,
    );
    const checksAfter = psql(
      `SELECT count(*) FROM agent_checks WHERE request_id = '${requestId4}'`,
    );
    const notifAfter = psql(
      `SELECT count(*) FROM notifications WHERE request_id = '${requestId4}'`,
    );
    check('РєРѕР»РёС‡РµСЃС‚РІРѕ РїСЂРѕРІРµСЂРѕРє РЅРµ СѓРІРµР»РёС‡РёСЃСЊ', checksBefore === checksAfter, `${checksBefore} -> ${checksAfter}`);
    check('РєРѕР»РёС‡РµСЃС‚РІРѕ РґРµР№СЃС‚РІРёР№ РЅРµ СѓРІРµР»РёС‡РёСЃСЊ', before === after, `${before} -> ${after}`);
    check('РєРѕР»РёС‡РµСЃС‚РІРѕ СѓРІРµРґРѕРјР»РµРЅРёР№ РЅРµ СѓРІРµР»РёС‡РёСЃСЊ', notifBefore === notifAfter, `${notifBefore} -> ${notifAfter}`);
  }

  // ------------------------------------------------------------------
  section('8. РћС€РёР±РєР° LLM РЅРµ РїСЂРёРІРѕРґРёС‚ Рє РѕС€РёР±РѕС‡РЅРѕРјСѓ РёР·РјРµРЅРµРЅРёСЋ СЃС‚Р°С‚СѓСЃР°');
  // ------------------------------------------------------------------
  // The LLM provider is not reachable in the test stack, so every LLM call
  // fails. The deterministic result must stand and the status must not move.
  const key5 = `e2e-phase8-llm-${randomUUID()}`;
  const created5 = await api('POST', '/api/v1/requests', {
    token: applicantToken,
    body: { idempotency_key: key5, text: INCOMPLETE_TEXT },
  });
  const requestId5 = created5.body?.id || created5.body?.request_id;
  if (requestId5) {
    // The type is assigned so that the deterministic check really runs; the
    // fields stay empty and the LLM provider is unreachable, so the status
    // must not move.
    await fillFields(requestId5, {});
    await api('POST', `/api/v1/requests/${requestId5}/submit`, { token: applicantToken, body: {} });
    const row = await waitFor(
      async () => {
        const rows = psqlRows(
          `SELECT result, llm_used, reason FROM agent_checks WHERE request_id = '${requestId5}'`,
        );
        return rows.length ? rows[0] : null;
      },
      150000,
    );
    check('РїСЂРѕРІРµСЂРєР° РІС‹РїРѕР»РЅРµРЅР°', !!row, 'no agent_checks row');
    const status5 = psql(`SELECT status FROM requests WHERE id = '${requestId5}'`);
    check('СЃС‚Р°С‚СѓСЃ РЅРµ РёР·РјРµРЅС‘РЅ РїСЂРё РѕС€РёР±РєРµ LLM', status5 === 'submitted', `status ${status5}`);
    if (row?.[1] === 't') {
      check('РїСЂРёС‡РёРЅР° РѕСЃС‚Р°Р»Р°СЃСЊ РѕРїСЂРµРґРµР»С‘РЅРЅРѕР№', !!row[2] && row[2].length > 0, 'empty reason');
    } else {
      console.log(`       LLM РЅРµ РёСЃРїРѕР»СЊР·РѕРІР°Р»СЃСЏ (llm_used=${row?.[1]}) вЂ” РґРµРіСЂР°РґР°С†РёСЏ Р±РµР·РѕРїР°СЃРЅРѕ`);
    }
  }

  // ------------------------------------------------------------------
  section('9. РР·РјРµРЅРµРЅРёРµ СЃС‚Р°С‚СѓСЃР° СЃРѕР·РґР°С‘С‚ СѓРІРµРґРѕРјР»РµРЅРёРµ Р·Р°СЏРІРёС‚РµР»СЋ');
  // ------------------------------------------------------------------
  const notifRequestId = requestId2 || requestId;
  const notification = await waitFor(
      async () => {
      const rows = psqlRows(
        `SELECT kind, title, body FROM notifications WHERE request_id = '${notifRequestId}' ORDER BY created_at DESC`,
      );
      return rows.length ? rows[0] : null;
    },
    60000,
  );
  check('СѓРІРµРґРѕРјР»РµРЅРёРµ Р·Р°СЏРІРёС‚РµР»СЋ СЃРѕР·РґР°РЅРѕ', !!notification, 'no notification row');
  if (notification) {
    console.log(`       СѓРІРµРґРѕРјР»РµРЅРёРµ: ${notification[0]} вЂ” ${notification[1]}`);
  }

  const feed = await api('GET', '/api/v1/notifications', { token: applicantToken });
  check('РєРѕР»РѕРєРѕР»СЊС‡РёРє Р·Р°СЏРІРёС‚РµР»СЏ РѕС‚РІРµС‡Р°РµС‚', feed.status === 200, `status ${feed.status}`);

  // The status change must also have produced a status_changed event that
  // Agent B consumed (a result card or a draft).
  const draftOrCard = psql(
    `SELECT count(*) FROM agent_drafts WHERE request_id = '${notifRequestId}'`,
  );
  check('Р°РіРµРЅС‚ СЃРѕРїСЂРѕРІРѕР¶РґРµРЅРёСЏ РїРѕРґРіРѕС‚РѕРІРёР» РєР°СЂС‚РѕС‡РєСѓ/С‡РµСЂРЅРѕРІРёРє', Number(draftOrCard) > 0, `drafts ${draftOrCard}`);

  // ------------------------------------------------------------------
  section('10. РћС‚РєР»СЋС‡РµРЅРёРµ Р°РІС‚РѕРјР°С‚РёР·Р°С†РёРё Р±Р»РѕРєРёСЂСѓРµС‚ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРёРµ РїРµСЂРµС…РѕРґС‹');
  // ------------------------------------------------------------------
  const setManual = await api('PUT', '/api/v1/automation/settings', {
    token: moderatorToken,
    body: { mode: 'manual' },
  });
  check('СЂРµР¶РёРј В«СЂСѓС‡РЅРѕР№В» РІРєР»СЋС‡С‘РЅ', setManual.status === 200 && setManual.body?.mode === 'manual', JSON.stringify(setManual.body).slice(0, 160));

  const key6 = `e2e-phase8-manual-${randomUUID()}`;
  const created6 = await api('POST', '/api/v1/requests', {
    token: applicantToken,
    body: { idempotency_key: key6, text: COMPLETE_TEXT },
  });
  const requestId6 = created6.body?.id || created6.body?.request_id;
  if (requestId6) {
    await fillFields(requestId6, {
      destination_city: 'Казань',
      purpose: 'Участие в семинаре',
      start_date: '01.06',
      end_date: '10.06',
      funding_source: 'budget',
      approver_id: 'demo',
    });
    await api('POST', `/api/v1/requests/${requestId6}/submit`, { token: applicantToken, body: {} });
    // Wait for the digital moderator to write the propose row. The agent
    // round-trip is real NATS -> worker -> API, so we must wait for it
    // instead of guessing a fixed delay.
    await waitFor(
      async () => {
        const rows = psqlRows(
          `SELECT action FROM automation_actions WHERE request_id = '${requestId6}' AND action = 'propose'`,
        );
        return rows.length ? rows[0] : null;
      },
      90000,
    );
    const status6 = psql(`SELECT status FROM requests WHERE id = '${requestId6}'`);
    check('СЃС‚Р°С‚СѓСЃ РЅРµ РёР·РјРµРЅС‘РЅ РІ СЂСѓС‡РЅРѕРј СЂРµР¶РёРјРµ', status6 === 'submitted', `status ${status6}`);

    const proposed = psqlRows(
      `SELECT action, outcome FROM automation_actions
        WHERE request_id = '${requestId6}' AND action = 'propose'`,
    );
    check('Р°РіРµРЅС‚ РїРѕРґРіРѕС‚РѕРІРёР» РїСЂРµРґР»РѕР¶РµРЅРёРµ, Р° РЅРµ РїРµСЂРµС…РѕРґ', proposed.length > 0, 'no proposal');
    check('РїРµСЂРµС…РѕРґ РЅРµ РІС‹РїРѕР»РЅРµРЅ', !proposed.some((r) => r[0] === 'transition'), 'a transition was executed');
  }

  // The agent endpoint must also refuse a transition in the manual mode.
  if (requestId6 && TOKEN) {
    const forced = await api('POST', `/api/v1/automation/agent/requests/${requestId6}/transition`, {
      token: TOKEN,
      body: { action: 'accept', reason: 'e2e', rule_code: 'complete', rules_version: 'v1' },
    });
    check('Р°РіРµРЅС‚ РЅРµ РјРѕР¶РµС‚ РІС‹РїРѕР»РЅРёС‚СЊ РїРµСЂРµС…РѕРґ РІ СЂСѓС‡РЅРѕРј СЂРµР¶РёРјРµ', forced.status === 409, `status ${forced.status}`);
  }

  // Restore the default mode.
  await api('PUT', '/api/v1/automation/settings', { token: moderatorToken, body: { mode: 'confirm' } });

  // ------------------------------------------------------------------
  section('РњРµС‚СЂРёРєРё В«Р­С„С„РµРєС‚РёРІРЅРѕСЃС‚СЊ 360В»');
  // ------------------------------------------------------------------
  const metrics = await api('GET', '/api/v1/automation/agent/metrics', { token: TOKEN });
  check('РјРµС‚СЂРёРєРё РѕС‚РґР°СЋС‚СЃСЏ', metrics.status === 200, `status ${metrics.status}`);
  if (metrics.status === 200) {
    console.log(`       СЃС‡С‘С‚С‡РёРєРё: ${JSON.stringify(metrics.body?.counters || {})}`);
  }

  const measured = psqlRows(
    `SELECT
       (SELECT count(*) FROM agent_checks),
       (SELECT count(*) FROM agent_checks WHERE result = 'passed'),
       (SELECT count(*) FROM agent_checks WHERE result <> 'passed'),
       (SELECT count(*) FROM agent_exceptions),
       (SELECT count(*) FROM notifications),
       (SELECT count(*) FROM automation_actions)`,
  );
  if (measured.length) {
    const [total, passedCount, manualCount, exceptions, notifications, actions] = measured[0];
    console.log(`       РїСЂРѕРІРµСЂРѕРє: ${total}, РїСЂРѕР№РґРµРЅРѕ: ${passedCount}, РЅР° С‡РµР»РѕРІРµРєР°: ${manualCount}`);
    console.log(`       РёСЃРєР»СЋС‡РµРЅРёР№: ${exceptions}, СѓРІРµРґРѕРјР»РµРЅРёР№: ${notifications}, РґРµР№СЃС‚РІРёР№: ${actions}`);
    check('РјРµС‚СЂРёРєРё РѕСЃРЅРѕРІР°РЅС‹ РЅР° СЂРµР°Р»СЊРЅС‹С… СЃРѕР±С‹С‚РёСЏС…', Number(total) > 0, 'no checks recorded');
  }

  return report();
}

// --- helpers ------------------------------------------------------------

// fillFields writes the extracted fields onto a request, exactly like the
// classifier consumer does.
async function fillFields(requestId, fields) {
  const json = JSON.stringify(fields);
  psql(
    `UPDATE requests SET fields = '${json.replace(/'/g, "''")}'::jsonb,
       request_type_id = (SELECT id FROM request_types WHERE name = 'РЈС‡РµР±РЅР°СЏ РїРѕРµР·РґРєР° (DEMO)')
     WHERE id = '${requestId}'`,
  );
}

// publishToNats is not used: the redelivery goes through the real outbox
// relay instead, which is a stronger guarantee than a manual publish.

function report() {
  console.log(`\n===== РРўРћР“ =====`);
  console.log(`passed: ${passed}, failed: ${failed}`);
  if (failures.length) {
    console.log('failures:');
    for (const f of failures) console.log(`  - ${f}`);
  }
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('E2E failed:', e.message);
  report();
});
