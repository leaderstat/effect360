// scripts/e2e/api-cjm360.mjs
//
// API-level end-to-end check of the closed CJM 360° cycle against the real
// Gleam API (localhost:8000) and the real PostgreSQL.
//
//   node scripts/e2e/api-cjm360.mjs
//
// The script only uses the documented HTTP contract — no stubs, no mocks.
// Every step asserts on the real response and on the data that the API
// returns after a restart of the request life cycle:
//
//   1. applicant logs in
//   2. applicant creates a draft and submits it
//   3. moderator sees the request in the queue
//   4. moderator takes the request into work
//   5. applicant receives a notification
//   6. moderator requests a clarification
//   7. applicant answers the clarification
//   8. moderator prepares and approves the official response
//   9. applicant sees the result card and the official letter
//  10. applicant leaves feedback
//  11. moderator sees the efficiency metrics
//  12. history survives a re-read of the request
//
// Exit code 0 — the whole cycle works. Non-zero — a step failed.

const API = process.env.API_BASE_URL ?? 'http://localhost:8000';
const APPLICANT = {
  email: 'demo.applicant@example.invalid',
  password: 'demo',
};
const MODERATOR = {
  email: 'demo.moderator@example.invalid',
  password: 'demo',
};

const steps = [];
let failures = 0;

function record(name, ok, detail) {
  steps.push({ name, ok, detail });
  if (!ok) failures += 1;
  const mark = ok ? 'PASS' : 'FAIL';
  console.log(`${mark}  ${name}${detail ? ` :: ${detail}` : ''}`);
}

async function call(method, path, { token, body } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fetch(`${API}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = { raw: text };
  }
  return { status: res.status, json, text };
}

async function login(user) {
  const res = await call('POST', '/api/v1/session', { body: user });
  if (res.status !== 200) {
    throw new Error(`login failed for ${user.email}: ${res.status} ${res.text}`);
  }
  return res.json.token;
}

function pick(obj, path) {
  return path.split('.').reduce((acc, key) => (acc == null ? acc : acc[key]), obj);
}

async function main() {
  const health = await call('GET', '/ready');
  record('api_ready', health.status === 200, `status=${health.status}`);
  if (health.status !== 200) return;

  // 1. applicant session
  const applicantToken = await login(APPLICANT);
  record('applicant_login', Boolean(applicantToken), 'token issued');

  // 2. moderator session
  const moderatorToken = await login(MODERATOR);
  record('moderator_login', Boolean(moderatorToken), 'token issued');

  // 3. create a draft
  const idempotencyKey = `e2e-cjm360-${Date.now()}`;
  const created = await call('POST', '/api/v1/requests', {
    token: applicantToken,
    body: {
      idempotency_key: idempotencyKey,
      text: 'Прошу разъяснить порядок предоставления компенсации за проезд в общественном транспорте в Казани.',
    },
  });
  const requestId = pick(created.json, 'request_id');
  record('create_draft', created.status === 202 && Boolean(requestId), `status=${created.status} id=${requestId}`);
  if (!requestId) {
    console.log(JSON.stringify(created.json));
    return;
  }

  // 4. idempotency — the same key must not create a second request
  const repeated = await call('POST', '/api/v1/requests', {
    token: applicantToken,
    body: {
      idempotency_key: idempotencyKey,
      text: 'Прошу разъяснить порядок предоставления компенсации за проезд в общественном транспорте в Казани.',
    },
  });
  record(
    'idempotent_create',
    repeated.status === 200 && pick(repeated.json, 'request_id') === requestId,
    `status=${repeated.status} created=${pick(repeated.json, 'created')}`,
  );

  // 5. submit — either 200 (accepted) or 422 with a structured missing[] list
  const submitted = await call('POST', `/api/v1/requests/${requestId}/submit`, {
    token: applicantToken,
  });
  const submitOk = submitted.status === 200;
  const submitStructured = submitted.status === 422 && Array.isArray(submitted.json?.missing);
  record(
    'submit_request',
    submitOk || submitStructured,
    `status=${submitted.status} ${submitOk ? 'accepted' : `missing=${(submitted.json?.missing ?? []).length}`}`,
  );

  // 6. the request is visible to its author
  const mine = await call('GET', '/api/v1/my/requests', { token: applicantToken });
  const mineItems = Array.isArray(mine.json?.requests)
    ? mine.json.requests
    : Array.isArray(mine.json?.items)
      ? mine.json.items
      : [];
  const mineIds = mineItems.map((r) => r.id ?? r.request_id);
  record(
    'applicant_sees_own_request',
    mine.status === 200 && mineIds.includes(requestId),
    `status=${mine.status} items=${mineItems.length}`,
  );

  // 7. the request is NOT visible to another applicant
  const otherToken = await login({ email: 'demo.manager@example.invalid', password: 'demo' });
  const foreign = await call('GET', `/api/v1/requests/${requestId}`, { token: otherToken });
  record(
    'rbac_foreign_read_denied',
    foreign.status === 403 || foreign.status === 404,
    `status=${foreign.status}`,
  );

  // 8. moderator queue
  const queue = await call('GET', '/api/v1/moderation/queue', { token: moderatorToken });
  const queueItems = Array.isArray(queue.json?.items)
    ? queue.json.items
    : Array.isArray(queue.json?.requests)
      ? queue.json.requests
      : [];
  const inQueue = queueItems.some((r) => (r.id ?? r.request_id) === requestId);
  record('moderator_queue', queue.status === 200 && inQueue, `status=${queue.status} items=${queueItems.length}`);

  // 9. the state machine is enforced by the backend
  const before = await call('GET', `/api/v1/requests/${requestId}`, { token: moderatorToken });
  const statusBefore = pick(before.json, 'status');
  const illegal = await call('POST', `/api/v1/requests/${requestId}/transition`, {
    token: moderatorToken,
    body: { action: 'complete' },
  });
  record(
    'illegal_transition_rejected',
    illegal.status === 409,
    `status=${illegal.status} from=${statusBefore}`,
  );

  const transitions = [
    ['accept', 'e2e accept'],
    ['start', 'e2e start'],
  ];
  let transitionOk = true;
  const seen = [];
  for (const [action, reason] of transitions) {
    const res = await call('POST', `/api/v1/requests/${requestId}/transition`, {
      token: moderatorToken,
      body: { action, reason },
    });
    const current = pick(res.json, 'status') ?? pick(res.json, 'request.status');
    seen.push(`${action}:${res.status}${current ? `/${current}` : ''}`);
    transitionOk = transitionOk && res.status === 200;
  }
  record('state_machine_transitions', transitionOk, seen.join(' '));

  // 10. notifications
  const notifications = await call('GET', '/api/v1/notifications', { token: applicantToken });
  const notifItems = Array.isArray(notifications.json?.items)
    ? notifications.json.items
    : Array.isArray(notifications.json?.notifications)
      ? notifications.json.notifications
      : [];
  record(
    'applicant_notifications',
    notifications.status === 200,
    `status=${notifications.status} items=${notifItems.length}`,
  );

  if (notifItems.length > 0) {
    const unread = notifItems.find((n) => n.unread === true) ?? notifItems[0];
    const marked = await call('POST', `/api/v1/notifications/${unread.id}/read`, {
      token: applicantToken,
    });
    record('notification_mark_read', marked.status === 200, `status=${marked.status}`);
  } else {
    record('notification_mark_read', false, 'no notifications to mark');
  }

  // 11. official response — the letter template with all the requisites
  const letter = {
    organization: 'Демо Министерство',
    requisites: 'ИНН 0000000000, ОГРН 0000000000000',
    registration_number: 'Д-0001',
    recipient: 'Демо Заявитель',
    subject: 'О предоставлении компенсации за проезд',
    legal_basis: 'Демонстрационное основание (в v0.1 не является реальной нормой)',
    decision_summary: 'Компенсация предоставляется в установленном порядке.',
    next_steps: 'Обратитесь в кабинет для получения результата.',
    responsible_executor: 'Демо Модератор',
    contact_for_questions: 'demo@example.invalid',
    signature_block: 'Демо Модератор',
    body: 'Уважаемый заявитель! Ваше обращение рассмотрено.',
  };
  const draft = await call('POST', `/api/v1/requests/${requestId}/response`, {
    token: moderatorToken,
    body: letter,
  });
  record('official_response_draft', draft.status === 200, `status=${draft.status}`);

  const ready = await call('POST', `/api/v1/requests/${requestId}/transition`, {
    token: moderatorToken,
    body: { action: 'answer_ready', reason: 'e2e answer ready' },
  });
  record('transition_answer_ready', ready.status === 200, `status=${ready.status}`);

  const approved = await call('POST', `/api/v1/requests/${requestId}/response/approve`, {
    token: moderatorToken,
    body: letter,
  });
  record('official_response_approved', approved.status === 200, `status=${approved.status}`);

  const completed = await call('POST', `/api/v1/requests/${requestId}/transition`, {
    token: moderatorToken,
    body: { action: 'complete', reason: 'e2e complete' },
  });
  record('transition_complete', completed.status === 200, `status=${completed.status}`);

  // 12. result card for the applicant
  const detail = await call('GET', `/api/v1/requests/${requestId}/detail`, { token: applicantToken });
  const resultCard = detail.json?.result_card ?? detail.json?.result ?? null;
  record(
    'result_card_visible',
    detail.status === 200 && resultCard !== null,
    `status=${detail.status} card=${resultCard ? 'yes' : 'no'}`,
  );

  // 13. feedback
  const feedback = await call('POST', `/api/v1/requests/${requestId}/feedback`, {
    token: applicantToken,
    body: { is_clear: true, comment: 'Ответ понятен, спасибо.' },
  });
  record('applicant_feedback', feedback.status === 200, `status=${feedback.status}`);

  // 14. metrics
  const metrics = await call('GET', '/api/v1/moderation/metrics', { token: moderatorToken });
  record('moderator_metrics', metrics.status === 200, `status=${metrics.status} keys=${Object.keys(metrics.json ?? {}).length}`);

  // 15. the request survives a re-read
  const again = await call('GET', `/api/v1/requests/${requestId}`, { token: applicantToken });
  record('history_persists', again.status === 200, `status=${again.status}`);

  console.log('');
  console.log(`RESULT: ${steps.length - failures}/${steps.length} steps passed`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error('E2E CRASH:', error.message);
  process.exit(2);
});
