fetch('http://api:8000/api/v1/session', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ email: 'demo.moderator@example.invalid', password: 'demo' }),
}).then(r => r.text()).then(t => console.log('OK', t.slice(0, 80))).catch(e => console.log('ERR', e.message));
