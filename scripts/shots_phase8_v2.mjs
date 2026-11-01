// scripts/shots_phase8_v2.mjs — финальный сборник скриншотов Phase 8.
// Использует addInitScript для инъекции Bearer-токена в sessionStorage,
// делает реальные скриншоты Lustre-приложения с работающим CSS и
// корректным декодированным API.
import { chromium } from 'file:///C:/tmp/shots-runner/node_modules/playwright/index.mjs';
import { mkdirSync } from 'node:fs';

const OUT = 'C:/home/Agents/effectivnost-360/docs/screens';
mkdirSync(OUT, { recursive: true });

const MOD = { email: 'demo.moderator@example.invalid', password: 'demo' };
const APP = { email: 'demo.applicant@example.invalid', password: 'demo' };
const WEB = process.env.WEB_URL || 'http://localhost:8050';
const API = process.env.API_URL || 'http://localhost:8000';

const PAGES = [
  { name: 'phase8-dashboard.png', url: '/automation', user: MOD },
  { name: 'phase8-agent-checks.png', url: '/automation/checks', user: MOD },
  { name: 'phase8-exceptions.png', url: '/automation/exceptions', user: MOD },
  { name: 'phase8-journal.png', url: '/automation/journal', user: MOD },
  { name: 'phase8-settings.png', url: '/automation/settings', user: MOD },
  { name: 'phase8-applicant-bell.png', url: '/account/bell', user: MOD },
];

async function login(ctx, user) {
  const r = await ctx.request.post(`${API}/api/v1/session`, {
    headers: { 'content-type': 'application/json' },
    data: { email: user.email, password: user.password },
  });
  if (!r.ok()) throw new Error(`login ${user.email} -> ${r.status()}`);
  const j = await r.json();
  await ctx.addInitScript((t) => {
    try {
      if (window.sessionStorage) sessionStorage.setItem('e360.session-token', t);
      if (window.localStorage) localStorage.setItem('auth_token', t);
    } catch (e) { }
  }, j.token);
  return j.token;
}

async function shoot(browser, user, target) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  // Pre-login to capture token, then re-inject via initScript on the same context.
  const lr = await fetch(`${API}/api/v1/session`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email: user.email, password: user.password }),
  });
  if (!lr.ok) throw new Error(`login ${user.email} -> ${lr.status}`);
  const j = await lr.json();
  await ctx.addInitScript((t) => {
    try {
      if (window.sessionStorage) sessionStorage.setItem('e360.session-token', t);
      if (window.localStorage) localStorage.setItem('auth_token', t);
    } catch (e) { }
  }, j.token);
  const page = await ctx.newPage();
  page.on('pageerror', e => console.log('PAGEERR', target.name, e.message));
  page.on('console', m => {
    if (m.type() === 'error') console.log('CON-ERR', target.name, m.text().slice(0, 200));
  });
  // First load the root to establish origin; initScript already injected token.
  await page.goto(`${WEB}/`, { waitUntil: 'domcontentloaded' });
  // Re-inject into the current page (initScript only fires on future navigations).
  await page.evaluate((t) => {
    sessionStorage.setItem('e360.session-token', t);
    localStorage.setItem('auth_token', t);
  }, j.token);
  await page.goto(`${WEB}${target.url}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(2000);
  await page.screenshot({ path: `${OUT}/${target.name}`, fullPage: true });
  const h1 = await page.locator('h1').first().textContent().catch(() => '');
  const banner = await page.locator('.banner-error').first().textContent().catch(() => '');
  console.log(`OK ${target.name} h1=${(h1 || '').slice(0, 50)} err=${(banner || '').slice(0, 50)}`);
  await ctx.close();
}

async function mobile(browser, token) {
  const ctx = await browser.newContext({ viewport: { width: 360, height: 720 } });
  await ctx.addInitScript((t) => {
    try {
      if (window.sessionStorage) sessionStorage.setItem('e360.session-token', t);
      if (window.localStorage) localStorage.setItem('auth_token', t);
    } catch (e) { }
  }, token);
  const page = await ctx.newPage();
  await page.goto(`${WEB}/`, { waitUntil: 'domcontentloaded' });
  await page.evaluate((t) => {
    sessionStorage.setItem('e360.session-token', t);
    localStorage.setItem('auth_token', t);
  }, token);
  await page.goto(`${WEB}/automation`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(2000);
  await page.screenshot({ path: `${OUT}/phase8-mobile-360.png`, fullPage: true });
  console.log('OK phase8-mobile-360.png');
  await ctx.close();
}

const browser = await chromium.launch();
for (const p of PAGES) {
  try {
    await shoot(browser, p.user, p);
  } catch (e) { console.log(`FAIL ${p.name}: ${e.message}`); }
}
try {
  // Re-login moderator for mobile to ensure fresh token
  const lr = await fetch(`${API}/api/v1/session`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(MOD),
  });
  const j = await lr.json();
  await mobile(browser, j.token);
} catch (e) { console.log(`FAIL mobile: ${e.message}`); }
await browser.close();
console.log('DONE');
