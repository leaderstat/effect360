// scripts/render_phase8_screens.mjs
//
// Renders the Phase 8 "Эффективность 360" panels as static HTML pages.
// Every panel is fed by a real SQL query against the running PostgreSQL
// container, so the saved HTMLs are snapshots of the live state.
//
// Usage: node scripts/render_phase8_screens.mjs
// Output: docs/screens/{automation,panel,exceptions,journal,bell}.html
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');
const OUT = resolve(ROOT, 'docs', 'screens');
mkdirSync(OUT, { recursive: true });

const PGUSER = process.env.PGUSER || 'effectivnost360';
const PGDATABASE = process.env.PGDATABASE || 'effectivnost360';

function psql(sql) {
  return execFileSync(
    'docker',
    ['compose', '-f', 'compose.yaml', 'exec', '-T', 'postgres',
     'psql', '-U', PGUSER, '-d', PGDATABASE, '-t', '-A', '-F', '|', '-c', sql],
    { encoding: 'utf8', cwd: ROOT },
  ).trim();
}

function psqlRows(sql) {
  const out = psql(sql);
  if (!out) return [];
  return out.split('\n').map((line) => line.split('|'));
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => {
    if (c === '&') return '&';
    if (c === '<') return '<';
    if (c === '>') return '>';
    if (c === '"') return '"';
    return String.fromCharCode(39);
  });
}

function page(title, body) {
  return [
    '<!doctype html>',
    '<html lang="ru">',
    '<head><meta charset="utf-8"><title>',
    esc(title),
    ' — Эффективность 360</title>',
    '<style>',
    'body{background:#0f1117;color:#e7e9ee;font-family:system-ui,sans-serif;margin:0;padding:24px}',
    'h1{font-size:18px;margin:0 0 16px;color:#fff}',
    'h2{font-size:14px;margin:24px 0 8px;color:#b8bcc7}',
    '.meta{font-size:12px;color:#7c8090;margin-bottom:16px}',
    'table{border-collapse:collapse;width:100%;font-size:13px}',
    'th,td{padding:8px 10px;text-align:left;border-bottom:1px solid #232631;vertical-align:top}',
    'th{background:#181b25;color:#b8bcc7;font-weight:500}',
    'tr:hover td{background:#181b25}',
    '.pill{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:500}',
    '.pill-manual{background:#3b2f15;color:#f1c98b}',
    '.pill-confirm{background:#15323b;color:#8bd1f1}',
    '.pill-auto{background:#1b3b1f;color:#8bf19b}',
    '.pill-passed{background:#1b3b1f;color:#8bf19b}',
    '.pill-needs_info{background:#3b2f15;color:#f1c98b}',
    '.pill-ambiguous{background:#3b1f1b;color:#f19b8b}',
    '.pill-propose{background:#2a1f3b;color:#c98bf1}',
    '.pill-transition{background:#1f3b1b;color:#8bf19b}',
    '.empty{color:#7c8090;font-style:italic;padding:12px 0}',
    '</style></head><body>',
    body,
    '</body></html>',
  ].join('');
}

function renderAutomation() {
  const settings = psqlRows(`SELECT mode, rules_version, updated_at FROM automation_settings WHERE id = 1`)[0] || [];
  const counts = psqlRows(
    `SELECT 'checks', count(*) FROM agent_checks UNION ALL
     SELECT 'passed', count(*) FROM agent_checks WHERE result = 'passed' UNION ALL
     SELECT 'needs_info', count(*) FROM agent_checks WHERE result = 'needs_info' UNION ALL
     SELECT 'ambiguous', count(*) FROM agent_checks WHERE result = 'ambiguous' UNION ALL
     SELECT 'actions', count(*) FROM automation_actions UNION ALL
     SELECT 'transitions', count(*) FROM automation_actions WHERE action = 'transition' UNION ALL
     SELECT 'proposals', count(*) FROM automation_actions WHERE action = 'propose' UNION ALL
     SELECT 'exceptions', count(*) FROM agent_exceptions UNION ALL
     SELECT 'drafts', count(*) FROM agent_drafts UNION ALL
     SELECT 'tasks', count(*) FROM agent_tasks`,
  );
  const map = Object.fromEntries(counts);
  return page('Панель автоматизации', [
    '<h1>Панель автоматизации — режим работы системы</h1>',
    '<p class="meta">Снимок сделан ', new Date().toISOString(),
    ' из реального PostgreSQL-стека.</p>',
    '<h2>Текущий режим</h2>',
    '<table><tr><th>Режим</th><th>Версия правил</th><th>Обновлён</th></tr>',
    '<tr>',
    '<td><span class="pill pill-', esc(settings[0] || 'unknown'), '">', esc(settings[0] || 'unknown'), '</span></td>',
    '<td>', esc(settings[1] || ''), '</td>',
    '<td>', esc(settings[2] || ''), '</td>',
    '</tr></table>',
    '<h2>Сводные счётчики «Эффективность 360»</h2>',
    '<table><tr><th>Метрика</th><th>Значение</th></tr>',
    '<tr><td>Проверок агента</td><td>', esc(map.checks || '0'), '</td></tr>',
    '<tr><td>— пройдены автоматически</td><td>', esc(map.passed || '0'), '</td></tr>',
    '<tr><td>— требуют уточнения (needs_info)</td><td>', esc(map.needs_info || '0'), '</td></tr>',
    '<tr><td>— переданы человеку (ambiguous)</td><td>', esc(map.ambiguous || '0'), '</td></tr>',
    '<tr><td>Автоматических действий</td><td>', esc(map.actions || '0'), '</td></tr>',
    '<tr><td>— выполнено переходов</td><td>', esc(map.transitions || '0'), '</td></tr>',
    '<tr><td>— подготовлено предложений</td><td>', esc(map.proposals || '0'), '</td></tr>',
    '<tr><td>Исключений для человека</td><td>', esc(map.exceptions || '0'), '</td></tr>',
    '<tr><td>Черновиков</td><td>', esc(map.drafts || '0'), '</td></tr>',
    '<tr><td>Задач модератору</td><td>', esc(map.tasks || '0'), '</td></tr>',
    '</table>',
  ].join(''));
}

function renderPanel() {
  const rows = psqlRows(
    `SELECT request_id, result, rule_code, initiated_by, updated_at FROM agent_checks ORDER BY updated_at DESC LIMIT 10`,
  );
  return page('Цифровой модератор', [
    '<h1>Цифровой модератор — результат проверки</h1>',
    '<p class="meta">Каждая строка — реальная запись таблицы <code>agent_checks</code>.</p>',
    rows.length === 0
      ? '<p class="empty">нет записей</p>'
      : '<table><tr><th>Заявка</th><th>Результат</th><th>Правило</th><th>Инициатор</th><th>Обновлено</th></tr>' +
        rows.map((r) =>
          '<tr>' +
          '<td><code>' + esc(r[0]) + '</code></td>' +
          '<td><span class="pill pill-' + esc(r[1]) + '">' + esc(r[1]) + '</span></td>' +
          '<td>' + esc(r[2]) + '</td>' +
          '<td>' + esc(r[3]) + '</td>' +
          '<td>' + esc(r[4]) + '</td>' +
          '</tr>'
        ).join('') +
        '</table>',
  ].join(''));
}

function renderExceptions() {
  const rows = psqlRows(
    `SELECT request_id, kind, status, reason, created_at FROM agent_exceptions ORDER BY created_at DESC LIMIT 10`,
  );
  return page('Очередь исключений', [
    '<h1>Очередь исключений «Требуется решение человека»</h1>',
    '<p class="meta">Реальные заявки, которые агент не смог обработать автоматически.</p>',
    rows.length === 0
      ? '<p class="empty">нет записей</p>'
      : '<table><tr><th>Заявка</th><th>Тип</th><th>Статус</th><th>Причина</th><th>Создано</th></tr>' +
        rows.map((r) =>
          '<tr>' +
          '<td><code>' + esc(r[0]) + '</code></td>' +
          '<td>' + esc(r[1]) + '</td>' +
          '<td>' + esc(r[2]) + '</td>' +
          '<td>' + esc(r[3]) + '</td>' +
          '<td>' + esc(r[4]) + '</td>' +
          '</tr>'
        ).join('') +
        '</table>',
  ].join(''));
}

function renderJournal() {
  const rows = psqlRows(
    `SELECT request_id, action, automation_mode, initiated_by, from_status, to_status, created_at FROM automation_actions ORDER BY created_at DESC LIMIT 10`,
  );
  return page('Журнал автоматических действий', [
    '<h1>Журнал автоматических действий</h1>',
    '<p class="meta">Все автоматические действия, записанные в <code>automation_actions</code>.</p>',
    rows.length === 0
      ? '<p class="empty">нет записей</p>'
      : '<table><tr><th>Заявка</th><th>Действие</th><th>Режим</th><th>Инициатор</th><th>Из</th><th>В</th><th>Создано</th></tr>' +
        rows.map((r) =>
          '<tr>' +
          '<td><code>' + esc(r[0]) + '</code></td>' +
          '<td><span class="pill pill-' + esc(r[1]) + '">' + esc(r[1]) + '</span></td>' +
          '<td><span class="pill pill-' + esc(r[2] || 'unknown') + '">' + esc(r[2] || 'unknown') + '</span></td>' +
          '<td>' + esc(r[3]) + '</td>' +
          '<td>' + esc(r[4] || '') + '</td>' +
          '<td>' + esc(r[5] || '') + '</td>' +
          '<td>' + esc(r[6]) + '</td>' +
          '</tr>'
        ).join('') +
        '</table>',
  ].join(''));
}

function renderBell() {
  const rows = psqlRows(
    `SELECT request_id, kind, title, created_at FROM notifications ORDER BY created_at DESC LIMIT 10`,
  );
  return page('Колокольчик заявителя', [
    '<h1>Колокольчик заявителя — уведомления</h1>',
    '<p class="meta">Уведомления в кабинете заявителя, записанные реальной системой.</p>',
    rows.length === 0
      ? '<p class="empty">нет записей</p>'
      : '<table><tr><th>Заявка</th><th>Вид</th><th>Заголовок</th><th>Создано</th></tr>' +
        rows.map((r) =>
          '<tr>' +
          '<td><code>' + esc(r[0] || '(без заявки)') + '</code></td>' +
          '<td>' + esc(r[1]) + '</td>' +
          '<td>' + esc(r[2] || '') + '</td>' +
          '<td>' + esc(r[3] || '') + '</td>' +
          '</tr>'
        ).join('') +
        '</table>',
  ].join(''));
}

const files = [
  ['automation.html', renderAutomation()],
  ['panel.html', renderPanel()],
  ['exceptions.html', renderExceptions()],
  ['journal.html', renderJournal()],
  ['bell.html', renderBell()],
];
for (const [name, html] of files) {
  const path = resolve(OUT, name);
  writeFileSync(path, html, 'utf8');
  console.log('wrote ' + path);
}
