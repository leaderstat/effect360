import { chromium } from "playwright";
const b = await chromium.launch({ headless: true });
const p = await b.newPage();
p.on("pageerror", (e) => console.log("ERR", e.message));
await p.goto("http://host.docker.internal:8050/describe", { waitUntil: "networkidle", timeout: 10000 });
await p.waitForTimeout(1000);
const ids = await p.$$eval("[id]", (els) => els.map(e => e.id).filter(x => x).slice(0, 20));
console.log("IDS:", JSON.stringify(ids));
await b.close();
