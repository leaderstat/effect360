// scripts/e2e/shots_phase8.mjs
//
// Phase-8 Playwright screenshots for the Эффективность 360 project.
// Requires an already-running Compose stack (web on :8050, api proxied).
//
// Usage:
//   docker compose run --rm tooling node /work/scripts/e2e/shots_phase8.mjs
//
// Output: /tmp/shots/phase8-*.png (mounted back via docker cp).

import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

const WEB = process.env.WEB_BASE_URL || 'http://effectivnost-360-web-1';
const OUT = process.env.SHOTS_DIR || '/tmp/shots';
mkdirSync(OUT, { recursive: true });

const MOD = { email: 'demo.moderator@example.invalid', password: 'demo' };
const APP = { email: 'demo.applicant@example.invalid', password: 'demo' };

async function login(page, who) {
  await page.goto(WEB + '/', { waitUntil: 'networkidle', timeout: 20000 });
  // Lustre app exposes email + password inputs on the auth screen.
  await page.fill('input[name="email"], input[type="email"], #email', who.email);
  await page.fill('input[name="password"], input[type="password"], #password', who.password);
  await Promise.all([
    page.waitForResponse(r => r.url().includes('/api/v1/session') && r.status() < 500, { timeout: 15000 }),
    page.click('button[type="submit"], #btn-submit, button:has-text("Войти")'),
  ]);
  await page.waitForLoadState('networkidle');
}

async function shot(page, route, file, opts = {}) {
  const url = WEB + route;
  console.log('--->', url);
  const errs = [];
  page.on('pageerror', e => errs.push('PAGE: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errs.push('CON: ' + m.text()); });
  await page.goto(url, { waitUntil: 'networkidle', timeout: 20000 });
  await page.waitForTimeout(800);
  const path = resolve(OUT, file);
  await page.screenshot({ path, fullPage: true });
  const title = await page.title();
  const h1 = await page.evaluate(() => {
    const el = document.querySelector('h1, .page-title');
    return el ? el.innerText.trim() : null;
  });
  console.log('   title:', title);
  console.log('   h1   :', h1);
  console.log('   saved:', path);
  console.log('   errs :', errs.length);
  if (errs.length) console.log('   ', errs.slice(0, 3).join(' | '));
  page.removeAllListeners('pageerror');
  page.removeAllListeners('console');
  return { path, h1, errs };
}

const browser = await chromium.launch();
try {
  // Mobile-360 first, no auth (SPA fallback expected for some screens).
  {
    const ctx = await browser.newContext({ viewport: { width: 360, height: 640 } });
    const p = await ctx.newPage();
    await p.goto(WEB + '/', { waitUntil: 'networkidle', timeout: 15000 });
    await p.screenshot({ path: resolve(OUT, 'phase8-mobile-360.png'), fullPage: true });
    console.log('mobile-360 saved');
    await ctx.close();
  }

  // Moderator session for /automation/*
  const mctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const mp = await mctx.newPage();
  try {
    await login(mp, MOD);
  } catch (e) {
    console.log('moderator login failed:', e.message);
  }
  await shot(mp, '/automation',                'phase8-dashboard.png');
  await shot(mp, '/automation/checks',         'phase8-agent-checks.png');
  await shot(mp, '/automation/exceptions',     'phase8-exceptions.png');
  await shot(mp, '/automation/journal',        'phase8-journal.png');
  await shot(mp, '/automation/settings',       'phase8-settings.png');
  await mctx.close();

  // Applicant session for /account/notifications + bell.
  const actx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const ap = await actx.newPage();
  try {
    await login(ap, APP);
  } catch (e) {
    console.log('applicant login failed:', e.message);
  }
  await shot(ap, '/account/notifications',     'phase8-applicant-bell.png');
  await actx.close();
} finally {
  await browser.close();
}
console.log('done');
