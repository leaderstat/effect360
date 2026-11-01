// scripts/e2e/screenshot.mjs — capture CJM screens via real Gleam API.
import { chromium } from "/tmp/node_modules/playwright/index.mjs";

const WEB = process.env.WEB || "http://e360-web";
const SHOT_DIR = "docs/screens";

async function main() {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ viewport: { width: 360, height: 720 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push("console: " + m.text()); });

  // 01: S0 Start
  await page.goto(WEB + "/", { waitUntil: "networkidle", timeout: 20000 });
  await page.waitForTimeout(2000);
  await page.screenshot({ path: SHOT_DIR + "/01-start.png", fullPage: true });

  // 02: S1 Describe
  const describeLink = await page.$('a:has-text("Описать"), button:has-text("Описать"), a[href="/describe"]');
  if (describeLink) {
    await Promise.all([
      page.waitForLoadState("networkidle", { timeout: 15000 }),
      describeLink.click(),
    ]);
  } else {
    await page.goto(WEB + "/describe", { waitUntil: "networkidle", timeout: 15000 });
  }
  await page.waitForTimeout(2000);
  await page.screenshot({ path: SHOT_DIR + "/02-describe.png", fullPage: true });

  // Fill and submit
  const ta = await page.$('textarea');
  if (ta) {
    await ta.fill("Прошу учебную поездку в Казань на конференцию 12-14 ноября 2026");
  }
  const submitBtn = await page.$('button[type=submit], button:has-text("Создать")');
  if (submitBtn) {
    await Promise.all([
      page.waitForLoadState("networkidle", { timeout: 15000 }).catch(() => {}),
      submitBtn.click(),
    ]);
  }
  await page.waitForTimeout(3000);
  await page.screenshot({ path: SHOT_DIR + "/03-clarify.png", fullPage: true });

  // 04: Submit
  const submitAll = await page.$('button:has-text("Отправить заявку"), button:has-text("Отправить")');
  if (submitAll) {
    await submitAll.click();
    await page.waitForTimeout(3000);
  }
  await page.screenshot({ path: SHOT_DIR + "/04-result.png", fullPage: true });

  // 05: 422
  const url5 = page.url();
  if (url5.includes("/request/")) {
    const id5 = url5.split("/request/")[1].split(/[?#/]/)[0];
    const resp = await page.evaluate(async (id) => {
      const r = await fetch("/api/v1/requests/" + id + "/submit", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
      return { status: r.status, body: (await r.text()).slice(0, 250) };
    }, id5);
    console.log("422_test:", JSON.stringify(resp));
  }
  await page.screenshot({ path: SHOT_DIR + "/05-422.png", fullPage: true });

  // 06: 404
  await page.goto(WEB + "/request/non-existent-id-xyz", { waitUntil: "networkidle", timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(2000);
  await page.screenshot({ path: SHOT_DIR + "/06-404.png", fullPage: true });

  // 07: 360px
  const hScroll = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);
  await page.screenshot({ path: SHOT_DIR + "/07-360px.png", fullPage: true });

  await browser.close();
  console.log("ERRORS=" + errors.length + " HSCROLL=" + hScroll);
}

main().catch((e) => { console.error("FAIL:", e.message); process.exit(1); });
