import { chromium } from "/tmp/node_modules/playwright/index.mjs";
const WEB = process.env.WEB || "http://e360-static";
const OUT = "/tmp/docs/screens";
async function main() {
  const b = await chromium.launch({ headless: true });
  const ctx = await b.newContext({ viewport: { width: 360, height: 720 } });
  const p = await ctx.newPage();
  const errors = [];
  p.on("pageerror", e => errors.push("pe:" + e.message));
  p.on("console", m => { if (m.type() === "error") errors.push("ce:" + m.text()); });
  await p.goto(WEB + "/", { waitUntil: "networkidle", timeout: 20000 });
  await p.waitForTimeout(3000);
  await p.screenshot({ path: OUT + "/08-corporate-hero.png", fullPage: true });
  const hScroll360 = await p.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
  console.log("ERRORS=" + errors.length + " HSCROLL_360=" + hScroll360);
  await ctx.close();
  const ctx2 = await b.newContext({ viewport: { width: 1280, height: 800 } });
  const p2 = await ctx2.newPage();
  await p2.goto(WEB + "/", { waitUntil: "networkidle", timeout: 20000 });
  await p2.waitForTimeout(3000);
  await p2.screenshot({ path: OUT + "/09-corporate-desktop.png", fullPage: true });
  await b.close();
}
main().catch(e => { console.error("FAIL:" + e.message); process.exit(1); });
