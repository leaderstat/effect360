// scripts/shoot-screens.cjs
//
// Screenshots of the main Lustre screens for manual verification.
//
// Requires the running stack (API on :8000, web on :8050) and the Playwright
// runner at C:/tmp/shots-runner/node_modules/playwright.
//
// The screens are shot for every DEMO role, because the sidebar and the
// available sections depend on the role of the current session.

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

async function authToken(email, password) {
  const r = await fetch(`${API}/api/v1/session`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  if (!r.ok) throw new Error(`session failed for ${email}: ${r.status}`);
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
  return (await r.json()).request_id;
}

function runSql(rid, localPath) {
  const containerPath = '/tmp/' + localPath.split('/').pop();
  sh(`docker cp "${localPath}" ${PG}:${containerPath}`);
  sh(
    `docker exec ${PG} psql -v ON_ERROR_STOP=1 -v rid=${rid} -U effectivnost360 -d effectivnost360 -f ${containerPath}`,
  );
}

const ROLES = [
  {
    email: 'demo.applicant@example.invalid',
    label: 'applicant',
    routes: [
      ['/', 'screen-start'],
      ['/describe', 'screen-describe'],
      ['/my/requests', 'screen-my-requests'],
      ['/notifications', 'screen-notifications'],
    ],
  },
  {
    email: 'demo.moderator@example.invalid',
    label: 'moderator',
    routes: [
      ['/moderation/queue', 'screen-moderation-queue'],
      ['/moderation/metrics', 'screen-moderation-metrics'],
    ],
  },
  {
    email: 'demo.manager@example.invalid',
    label: 'manager',
    routes: [['/', 'screen-manager-start']],
  },
];

(async () => {
  const browser = await chromium.launch();
  const errors = [];

  for (const role of ROLES) {
    const token = await authToken(role.email, 'demo');
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    await ctx.addInitScript((t) => {
      sessionStorage.setItem('e360.session-token', t);
    }, token);
    const page = await ctx.newPage();
    page.on('pageerror', (e) => errors.push(`${role.label}: ${e.message}`));

    for (const [route, name] of role.routes) {
      await page.goto(`${WEB}${route}`, { waitUntil: 'networkidle' });
      await page.waitForTimeout(1500);
      await page.screenshot({ path: `${SHOTS}/${name}.png`, fullPage: true });
      const info = await page.evaluate(() => ({
        screens: Array.from(document.querySelectorAll('.screen')).map((s) => s.id),
        alert: document
          .querySelector('.alert, [class*=alert]')
          ?.innerText?.trim()
          .slice(0, 60),
      }));
      console.log(
        `${role.label} ${route} -> ${name}.png screens=${JSON.stringify(info.screens)}` +
          (info.alert ? ` alert="${info.alert}"` : ''),
      );
    }
    await ctx.close();
  }

  // The request screen needs a real draft (as the applicant).
  const applicantToken = await authToken('demo.applicant@example.invalid', 'demo');
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await ctx.addInitScript((t) => {
    sessionStorage.setItem('e360.session-token', t);
  }, applicantToken);
  const page = await ctx.newPage();
  page.on('pageerror', (e) => errors.push(`request: ${e.message}`));

  const rid = await newDraft(applicantToken);
  runSql(rid, `${TMP}/e2e_hardstop_prep.sql`);
  await page.goto(`${WEB}/request/${rid}`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1500);
  await page.screenshot({ path: `${SHOTS}/screen-request.png`, fullPage: true });
  console.log(`/request/${rid} -> screen-request.png`);

  console.log('page errors:', errors.length ? errors.join(' | ') : 'none');
  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
