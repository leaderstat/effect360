// scripts/check-responsive.cjs
//
// Responsive check for the Lustre app.
//
// For every route and every required viewport width (360, 768, 1280, 1920)
// it asserts that the document does not scroll horizontally and that no
// element overflows the viewport width. A failing route/width pair is
// printed with the offending elements.

const { chromium } = require('C:/tmp/shots-runner/node_modules/playwright');

const API = 'http://localhost:8000';
const WEB = 'http://localhost:8050';
const WIDTHS = [360, 768, 1280, 1920];
const ROUTES = [
  '/',
  '/describe',
  '/my/requests',
  '/notifications',
  '/moderation/queue',
  '/moderation/metrics',
  '/automation',
  '/automation/checks',
  '/automation/exceptions',
  '/automation/journal',
  '/automation/settings',
];

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

(async () => {
  const token = await authToken();
  const browser = await chromium.launch();
  const failures = [];

  for (const width of WIDTHS) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 } });
    await ctx.addInitScript((t) => {
      sessionStorage.setItem('e360.session-token', t);
    }, token);
    const page = await ctx.newPage();
    const jsErrors = [];
    page.on('pageerror', (e) => jsErrors.push(e.message));

    for (const route of ROUTES) {
      await page.goto(`${WEB}${route}`, { waitUntil: 'networkidle' });
      await page.waitForTimeout(700);
      const res = await page.evaluate((vw) => {
        const doc = document.documentElement;
        const overflow = doc.scrollWidth - vw;
        const offenders = [];
        if (overflow > 1) {
          for (const el of document.querySelectorAll('body *')) {
            const r = el.getBoundingClientRect();
            if (r.width === 0 || r.height === 0) continue;
            if (r.right > vw + 1 || r.left < -1) {
              const id = el.id ? '#' + el.id : '';
              const cls = el.className && typeof el.className === 'string'
                ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.')
                : '';
              offenders.push(
                `${el.tagName.toLowerCase()}${id}${cls} right=${Math.round(r.right)}`,
              );
              if (offenders.length >= 5) break;
            }
          }
        }
        return { overflow, offenders };
      }, width);

      if (res.overflow > 1) {
        failures.push(
          `${route} @${width}px: overflow=${res.overflow}px | ${res.offenders.join(' ; ')}`,
        );
      }
    }
    if (jsErrors.length) {
      failures.push(`@${width}px js errors: ${jsErrors.join(' | ')}`);
    }
    console.log(`checked ${ROUTES.length} routes @ ${width}px`);
    await ctx.close();
  }

  await browser.close();

  if (failures.length) {
    console.log('\nHORIZONTAL OVERFLOW / JS ERRORS FOUND:');
    for (const f of failures) console.log('  ' + f);
    process.exit(1);
  }
  console.log('\nOK: no horizontal overflow at 360 / 768 / 1280 / 1920 px, no JS errors.');
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
