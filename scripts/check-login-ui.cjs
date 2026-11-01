// scripts/check-login-ui.cjs
//
// Checks the real sign-in flow of the Lustre UI in a clean browser
// context (no pre-seeded sessionStorage):
//
//   1. open /my/requests  -> the sign-in form must be visible
//   2. fill the DEMO credentials and submit
//   3. the applicant's own requests must be shown (not "Вы не вошли в систему")
//   4. reload the page -> the session must survive (token in sessionStorage)
//   5. no JavaScript errors along the way
//
// Usage: node scripts/check-login-ui.cjs

const { chromium } = require('C:/tmp/shots-runner/node_modules/playwright');

const WEB = 'http://localhost:8050';
const SHOTS = 'C:/home/Agents/effectivnost-360/docs/screens';

const EMAIL = 'demo.applicant@example.invalid';
const PASSWORD = 'demo';

(async () => {
  const browser = await chromium.launch();
  // A clean context: no sessionStorage, no cookies.
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();

  const errors = [];
  // The app probes GET /api/v1/session before the sign-in; the API answers
  // 401 until a token exists. That is the expected behaviour, so the
  // browser logs one 401 for it — it is not an application error.
  let sawExpectedPreLogin401 = false;
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => {
    if (m.type() !== 'error') return;
    const text = m.text();
    if (text.includes('401') && !sawExpectedPreLogin401) {
      sawExpectedPreLogin401 = true;
      return;
    }
    errors.push('console: ' + text);
  });

  // ---- 1. the sign-in form -------------------------------------------
  await page.goto(`${WEB}/my/requests`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1200);

  const formVisible = await page.isVisible('#login-form');
  const emailVisible = await page.isVisible('#login-email');
  const passwordVisible = await page.isVisible('#login-password');
  console.log('login form visible :', formVisible);
  console.log('email field visible:', emailVisible);
  console.log('password visible   :', passwordVisible);
  if (!formVisible || !emailVisible || !passwordVisible) {
    console.log('FAIL: the sign-in form is not shown on /my/requests');
    await page.screenshot({ path: `${SHOTS}/login-form.png` });
    await browser.close();
    process.exit(1);
  }

  await page.screenshot({ path: `${SHOTS}/login-form.png` });

  // ---- 2. sign in ----------------------------------------------------
  await page.fill('#login-email', EMAIL);
  await page.fill('#login-password', PASSWORD);
  await page.click('#login-submit');
  await page.waitForTimeout(2500);

  // ---- 3. the cabinet must show the requests --------------------------
  const afterLogin = (await page.evaluate(() => document.body.innerText))
    .replace(/\s+/g, ' ');

  const stillLoggedOut = afterLogin.includes('Вы не вошли в систему');
  const hasCabinet = afterLogin.includes('Мои заявки');
  console.log('login form gone    :', !(await page.isVisible('#login-form')));
  console.log('still says logged-out:', stillLoggedOut);
  console.log('cabinet shown      :', hasCabinet);

  const requestRows = await page.evaluate(
    () => document.querySelectorAll('.request-list tbody tr').length,
  );
  console.log('request entries rendered:', requestRows);
  if (requestRows < 1) {
    console.log('FAIL: the cabinet lists no requests although the API returns some');
    await browser.close();
    process.exit(1);
  }

  await page.screenshot({ path: `${SHOTS}/login-success.png`, fullPage: false });

  if (stillLoggedOut || !hasCabinet) {
    console.log('FAIL: the cabinet did not open after the sign-in');
    console.log('page text:', afterLogin.slice(0, 300));
    await browser.close();
    process.exit(1);
  }

  // ---- 4. the session must survive a reload ---------------------------
  await page.reload({ waitUntil: 'networkidle' });
  await page.waitForTimeout(2000);
  const afterReload = (await page.evaluate(() => document.body.innerText)).replace(
    /\s+/g,
    ' ',
  );
  const loggedOutAfterReload = afterReload.includes('Вы не вошли в систему');
  console.log('logged out after reload:', loggedOutAfterReload);
  console.log('cabinet after reload   :', afterReload.includes('Мои заявки'));

  await page.screenshot({ path: `${SHOTS}/login-after-reload.png`, fullPage: false });

  console.log('js errors:', errors.length ? errors.join(' | ') : 'none');

  await browser.close();

  if (loggedOutAfterReload) {
    console.log('FAIL: the session did not survive the reload');
    process.exit(1);
  }
  if (errors.length) {
    console.log('FAIL: JavaScript errors were reported');
    process.exit(1);
  }
  console.log('OK: the sign-in works, the cabinet opens and the session survives a reload.');
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
