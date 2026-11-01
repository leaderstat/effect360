#!/bin/sh
TOKEN="$1"
[ -z "$TOKEN" ] && { echo "usage: $0 TOKEN"; exit 1; }
echo "== agent/metrics =="
curl -s -w "\nHTTP=%{http_code}\n" -H "Authorization: Bearer $TOKEN" http://api:8000/api/v1/automation/agent/metrics
echo "== panel head =="
curl -s -H "Authorization: Bearer $TOKEN" http://api:8000/api/v1/automation/panel | head -c 400
echo
echo "== exceptions =="
curl -s -w "\nHTTP=%{http_code}\n" -H "Authorization: Bearer $TOKEN" http://api:8000/api/v1/automation/exceptions | head -c 400
