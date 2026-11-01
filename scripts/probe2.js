const j = require("/tmp/panel.json");
console.log("ACTION_KEYS=", Object.keys(j.actions[0] || {}).join(","));
console.log("EXC_KEYS=", Object.keys(j.exceptions[0] || {}).join(","));
console.log("TASK_KEYS=", Object.keys(j.tasks[0] || {}).join(","));
