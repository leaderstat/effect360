// scripts/e2e/debug-render.mjs — just goto a request screen and dump the DOM.
import { chromium } from "playwright";

const b = await chromium.launch({ headless: true });
const p = await b.newPage();
p.on("console", (m) => console.log("CON", m.type(), m.text()));
p.on("pageerror", (e) => console.log("ERR", e.message));
p.on("response", (r) => console.log("NET", r.status(), r.url()));

await p.goto("http://e360-web/request/demo-test", { waitUntil: "networkidle" });
const html = await p.content();
console.log("---DOM---");
console.log(html);
await b.close();
