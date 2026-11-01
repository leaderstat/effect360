import { chromium } from 'playwright';

const TOKEN = process.argv[2];
const b = await chromium.launch();
const ctx = await b.newContext();
await ctx.addInitScript(t => sessionStorage.setItem('e360.session-token', t), TOKEN);
const p = await ctx.newPage();
p.on('console', m => console.log('CON', m.type(), m.text().slice(0, 200)));
p.on('pageerror', e => console.log('ERR', e.message));
await p.goto('http://effectivnost-360-frontend-1/automation', { waitUntil: 'networkidle' });
await p.waitForTimeout(2500);
const txt = await p.locator('.banner-error').first().textContent().catch(() => '');
console.log('BANNER:', txt);
const h1 = await p.locator('h1').first().textContent().catch(() => '');
console.log('H1:', h1);
await b.close();
