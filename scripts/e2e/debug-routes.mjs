// scripts/e2e/debug-routes.mjs
//
// Diagnostic: open each Phase-8 URL, dump the DOM <h1>, console errors,
// and an `automation-panel` / `agent_checks` count to verify whether the
// route is actually routed by the Lustre app.

import { chromium } from 'playwright';

const WEB = process.env.WEB_BASE_URL || 'http://effectivnost-360-web-1';
const ROUTES = [
  '/',
  '/automation',
  '/automation/checks',
  '/automation/exceptions',
  '/automation/journal',
  '/automation/settings',
  '/account/bell',
];

const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
const page = await ctx.newPage();
const errs = [];
page.on('pageerror', e => errs.push('PAGE: ' + e.message));
page.on('console', m => { if (m.type() === 'error') errs.push('CON: ' + m.text()); });

for (const r of ROUTES) {
  errs.length = 0;
  await page.goto(WEB + r, { waitUntil: 'networkidle', timeout: 20000 });
  await page.waitForTimeout(800);
  const h1 = await page.evaluate(() => {
    const el = document.querySelector('h1, .page-title');
    return el ? el.innerText.trim() : '(no h1)';
  });
  const banner = await page.evaluate(() => {
    const el = document.querySelector('.banner-error, .error, [role="alert"]');
    return el ? el.innerText.trim() : null;
  });
  const path = await page.evaluate(() => window.location.pathname);
  console.log(`URL=${r}  -> path=${path}  h1='${h1}'  err=${errs.length}  banner='${banner ?? ''}'`);
  if (errs.length) console.log('   ', errs.slice(0, 3).join(' | '));
}

await browser.close();
