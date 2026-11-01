// scripts/shoot-hard-stop.cjs
//
// Playwright screenshots of the regulatory hard-stop banner.
//
// Requires the running stack (PostgreSQL, API on :8000, web on :8050) and the
// Playwright runner at C:/tmp/shots-runner/node_modules/playwright.
//
// Pre-conditions:
//   - The demo applicant session is available (POST /api/v1/session).
//   - The .tmp/e2e_hardstop_prep.sql and .tmp/e2e_review_prep.sql files exist;
//     they attach a draft to the business-trip request type and set the fields
//     that trigger the hard-stop / employer-review rules.

const { chromium } = require('C:/tmp/shots-runner/node_modules/playwright');
const { execSync } = require('node:child_process');

const API = 'http://localhost:8000';
const WEB = 'http://localhost:8050';
const PG = 'effectivnost-360-postgres-1';
const SHOTS = 'C:/home/Agents/effectivnost-360/docs/screens';
const TMP = 'C:/home/Agents/effectivnost-360/.tmp';

function sh(cmd) {
  return execSync(cmd, { encoding: 'utf8', stdio: 'pipe' }).trim();
}

async function authToken() {
  const r = await fetch(`${API}/api/v1/session`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      email: 'demo.applicant@example.invalid',
      password: 'demo',
    }),
  });
  if (!r.ok) throw new Error(`session failed: ${r.status}`);
  return (await r.json()).token;
}

async function newDraft(token) {
  const r = await fetch(`${API}/api/v1/requests`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json; charset=utf-8',
      authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      idempotency_key: crypto.randomUUID(),
      text: 'Прошу оформить командировку в Казань с 12 по 14 ноября 2026 на конференцию',
    }),
  });
  if (!r.ok) throw new Error(`create_request failed: ${r.status} ${await r.text()}`);
  return (await r.json()).request_id;
}

function runSql(rid, localPath) {
  const containerPath = '/tmp/' + localPath.split('/').pop();
  sh(`docker cp "${localPath}" ${PG}:${containerPath}`);
  sh(`docker exec ${PG} psql -v ON_ERROR_STOP=1 -v rid=${rid} -U effectivnost360 -d effectivnost360 -f ${containerPath}`);
}

async function shoot(page, rid, sqlFile, shotName) {
  runSql(rid, `${TMP}/${sqlFile}`);

  await page.goto(`${WEB}/request/${rid}`, { waitUntil: 'networkidle' });
  await page.waitForSelector('#screen-clarify', { timeout: 15000 });
  await page.waitForSelector('#btn-submit', { timeout: 15000 });
  await page.waitForTimeout(1500);

  await page.click('#btn-submit');
  // The submit is answered by the API; wait for the banner / status update.
  await page.waitForTimeout(3000);

  const state = await page.evaluate(() => ({
    hardStopVisible: !document
      .querySelector('#server-hard-stops')
      ?.classList.contains('hidden'),
    hardStopText: document
      .querySelector('#server-hard-stops')
      ?.innerText?.trim()
      .slice(0, 160),
    statusText: document.querySelector('#status-2')?.innerText?.trim().slice(0, 160),
  }));

  await page.screenshot({ path: `${SHOTS}/${shotName}.png`, fullPage: true });
  console.log(`saved ${shotName}.png`, JSON.stringify(state));
  return state;
}

(async () => {
  const token = await authToken();
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await ctx.addInitScript((t) => {
    sessionStorage.setItem('e360.session-token', t);
  }, token);
  const page = await ctx.newPage();

  // --- 1. block_submit: is_pregnant = true ------------------------------
  const rid1 = await newDraft(token);
  console.log('draft block_submit:', rid1);
  await shoot(page, rid1, 'e2e_hardstop_prep.sql', 'hard-stop-banner');

  // --- 2. needs_employer_review: has_apprentice_contract = true --------
  const rid2 = await newDraft(token);
  console.log('draft employer_review:', rid2);
  await shoot(page, rid2, 'e2e_review_prep.sql', 'hard-stop-employer-review');

  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
