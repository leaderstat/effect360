// Minimal screenshot script — saves real Lustre screens without blocking
// on POST (POST is currently blocked by an unrelated backend SQL bug,
// see Backlog §13.7).

import { chromium } from "playwright";
import { writeFileSync, statSync, mkdirSync } from "fs";

const BASE = "http://host.docker.internal:8050";
const OUT = "/work/screens";
mkdirSync(OUT, { recursive: true });

async function snap(page, name) {
  await page.waitForTimeout(300);
  const buf = await page.screenshot();
  const path = `${OUT}/${name}.png`;
  writeFileSync(path, buf);
  console.log(`PNG ${name}.png: ${statSync(path).size} bytes`);
}

const b = await chromium.launch({ headless: true });

async function shot(url, name, vp = { width: 360, height: 800 }) {
  const ctx = await b.newContext({ viewport: vp });
  const p = await ctx.newPage();
  await p.goto(`${BASE}${url}`, { waitUntil: "networkidle", timeout: 15000 });
  await p.waitForTimeout(800);
  await snap(p, name);
  await ctx.close();
}

await shot("/", "01-start");
await shot("/", "02-start-desktop", { width: 1280, height: 900 });
await shot("/describe", "03-describe");
await shot("/describe", "04-describe-desktop", { width: 1280, height: 900 });
await shot("/request/nonexistent", "05-not-found");
await shot("/request/nonexistent", "06-not-found-desktop", { width: 1280, height: 900 });

await b.close();
console.log("DONE");
