TOKEN=$(curl -s -X POST http://api:8000/api/v1/session -H "Content-Type: application/json" -d '{"email":"demo.moderator@example.invalid","password":"demo"}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["token"])')
echo "TOKEN_LEN=${#TOKEN}"
echo "=== settings ==="
curl -s -H "Authorization: Bearer $TOKEN" http://api:8000/api/v1/automation/settings
echo ""
echo "=== exceptions ==="
curl -s -H "Authorization: Bearer $TOKEN" http://api:8000/api/v1/automation/exceptions | head -c 400
echo ""
