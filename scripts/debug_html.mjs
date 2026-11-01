import { chromium } from 'playwright';
const url = 'http://172.23.0.6:80';
const api = 'http://172.23.0.7:8000';
const browser = await chromium.launch();
const ctx = await browser.newContext({viewport:{width:1280,height:800}});
const page = await ctx.newPage();
page.on('pageerror', e => console.log('PAGEERR', e.message));
page.on('console', m => console.log('CON', m.type(), m.text().slice(0,200)));
const r = await page.request.post(`${api}/api/v1/session`, {headers:{'content-type':'application/json'}, data:{email:'demo.moderator@example.invalid', password:'demo'}});
const j = await r.json();
console.log('STATUS', r.status(), 'TOKEN_LEN', j.token?.length);
await ctx.addInitScript(t => {
  try { sessionStorage.setItem('e360.session-token', t); } catch(e) {}
  try { localStorage.setItem('auth_token', t); } catch(e) {}
}, j.token);
await page.goto(`${url}/automation`, {waitUntil:'networkidle'});
await page.waitForTimeout(1500);
const html = await page.content();
console.log('HTML_LEN', html.length);
console.log('H1:', (await page.locator('h1').first().textContent().catch(()=>'(no h1)')));
console.log('CSS_LOADED:', await page.evaluate(() => !!document.styleSheets[0]));
console.log('FIRST_600:', html.slice(0, 600));
await browser.close();
