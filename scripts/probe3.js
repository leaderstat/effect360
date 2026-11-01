const j = require("/tmp/panel.json");
console.log("EXC_KEYS=", Object.keys(j.exceptions[0] || {}).join(","));
console.log("EXC0=", JSON.stringify(j.exceptions[0] || {}, null, 2).slice(0, 800));
