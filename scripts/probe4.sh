#!/bin/sh
TOKEN=$(curl -s -X POST "http://172.23.0.7:8000/api/v1/session" \
  -H "Content-Type: application/json" \
  --data-binary '{"email":"demo.moderator@example.invalid","password":"demo"}' \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
echo "=== EXCEPTIONS ==="
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://172.23.0.7:8000/api/v1/automation/exceptions" > /tmp/exc.json
node -e 'const j=require("/tmp/exc.json"); console.log("TYPE=", Array.isArray(j)?"array":typeof j); if(Array.isArray(j)){console.log("FIRST_KEYS=", Object.keys(j[0]||{}).join(",")); console.log("FIRST=", JSON.stringify(j[0]||{}).slice(0,400))} else console.log("BODY=",JSON.stringify(j).slice(0,400))'
echo "=== JOURNAL ==="
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://172.23.0.7:8000/api/v1/automation/journal" > /tmp/jrn.json
node -e 'const j=require("/tmp/jrn.json"); console.log("TYPE=", Array.isArray(j)?"array":typeof j); if(Array.isArray(j)){console.log("FIRST_KEYS=", Object.keys(j[0]||{}).join(",")); console.log("FIRST=", JSON.stringify(j[0]||{}).slice(0,400))} else console.log("BODY=",JSON.stringify(j).slice(0,400))'
echo "=== METRICS ==="
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://172.23.0.7:8000/api/v1/automation/metrics" > /tmp/met.json
node -e 'const j=require("/tmp/met.json"); console.log("BODY=",JSON.stringify(j).slice(0,400))'
