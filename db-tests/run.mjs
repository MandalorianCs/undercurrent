#!/usr/bin/env node
// Прогон миграций и сценариев на настоящем Postgres в Docker.
//
// Зачем: «tsc проходит и expo собирается» ничего не говорит о том,
// применятся ли миграции и держится ли изоляция. Здесь база поднимается
// с нуля, на неё накатываются миграции ровно в том же порядке, что в SQL
// Editor, и по ним проезжают сценарии от имени живых ролей.
//
//   node db-tests/run.mjs           обычный прогон, контейнер удаляется
//   node db-tests/run.mjs --keep    оставить базу для ручных запросов
//
// Файлы не монтируются томом, а подаются в psql через stdin: путь к
// проекту содержит кириллицу и пробелы, и docker -v на нём ведёт себя
// непредсказуемо.

import { spawnSync } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const CONTAINER = 'undercurrent-test-db';
const IMAGE = 'postgres:16-alpine';
const KEEP = process.argv.includes('--keep');

// Миграции не перечисляются руками: список читается из папки в том же
// порядке, в каком их применит Supabase — по имени файла. Иначе новая
// миграция молча выпадала бы из прогона, и стенд подтверждал бы схему,
// которой на проекте уже нет.
const migrations = readdirSync(join(ROOT, 'supabase', 'migrations'))
  .filter((f) => f.endsWith('.sql'))
  .sort()
  .map((f) => [
    `миграция — ${f.replace(/^\d+_/, '').replace(/\.sql$/, '')}`,
    `supabase/migrations/${f}`,
  ]);

const STEPS = [
  ['заглушка платформы Supabase', 'db-tests/00_platform_shim.sql'],
  ...migrations,
  ['помощники и посев', 'db-tests/10_helpers.sql'],
  ['сценарий 1 — путь сотрудника', 'db-tests/20_access_flow.sql'],
  ['сценарий 2 — изоляция', 'db-tests/30_isolation.sql'],
  ['сценарий 3 — агрегаты и порог', 'db-tests/40_aggregates.sql'],
];

const docker = (args, opts = {}) => spawnSync('docker', args, { encoding: 'utf8', ...opts });

function die(message, detail) {
  console.error(`\n✗ ${message}`);
  if (detail) console.error(detail.trim());
  process.exit(1);
}

// ── Поднимаем чистую базу ─────────────────────────────────────
// Именно чистую: сценарии опираются на то, что таблицы пустые, а прошлый
// прогон мог оставить билеты и сессии.

if (docker(['version']).status !== 0) {
  die('Docker не отвечает. Запустите Docker Desktop и повторите.');
}

console.log(`Поднимаю ${IMAGE} в контейнере ${CONTAINER}…`);
docker(['rm', '-f', CONTAINER]);

const up = docker([
  'run', '-d', '--name', CONTAINER,
  '-e', 'POSTGRES_PASSWORD=postgres',
  // Supabase держит базу в UTC. От часового пояса зависит issued_on и
  // границы окна агрегатов — расхождение с продакшном недопустимо.
  '-e', 'TZ=UTC',
  '-e', 'PGTZ=UTC',
  IMAGE,
]);
if (up.status !== 0) die('не удалось запустить контейнер', up.stderr);

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

let ready = false;
for (let i = 0; i < 60; i++) {
  if (docker(['exec', CONTAINER, 'pg_isready', '-U', 'postgres', '-q']).status === 0) {
    ready = true;
    break;
  }
  sleep(1000);
}
if (!ready) {
  const logs = docker(['logs', '--tail', '40', CONTAINER]);
  die('Postgres не поднялся за 60 попыток', logs.stdout + logs.stderr);
}

// ── Прогон ────────────────────────────────────────────────────

function psql(sqlPath) {
  return docker(
    [
      'exec', '-i',
      '-e', 'PGPASSWORD=postgres',
      '-e', 'PGCLIENTENCODING=UTF8',
      CONTAINER,
      'psql', '-U', 'postgres', '-d', 'postgres',
      '-v', 'ON_ERROR_STOP=1',
      '--quiet', '--no-psqlrc',
      // Результаты запросов смысла не несут: всё проверяемое приходит
      // через raise notice в stderr. Без этого вывод тонет в таблицах.
      '-o', '/dev/null',
    ],
    { input: readFileSync(join(ROOT, sqlPath)) },
  );
}

const started = Date.now();
let failed = null;

for (const [label, file] of STEPS) {
  process.stdout.write(`\n▸ ${label}\n`);
  const res = psql(file);

  // raise notice уходит в stderr — это наши «ok», а не ошибки.
  const noise = (res.stderr || '')
    .split('\n')
    .filter((line) => line.trim() && !line.startsWith('SET') && !line.includes('NOTICE:  extension'))
    .map((line) => line.replace(/^ПРЕДУПРЕЖДЕНИЕ:|^NOTICE:\s*/, '  '))
    .join('\n');

  if (res.stdout?.trim()) console.log(res.stdout.trim());
  if (noise) console.log(noise);

  if (res.status !== 0) {
    failed = { label, file };
    break;
  }
}

const seconds = ((Date.now() - started) / 1000).toFixed(1);

if (KEEP) {
  console.log(
    `\nКонтейнер ${CONTAINER} оставлен. Подключиться:\n` +
      `  docker exec -it ${CONTAINER} psql -U postgres`,
  );
} else {
  docker(['rm', '-f', CONTAINER]);
}

if (failed) {
  console.error(`\n✗ ПРОВАЛ на шаге «${failed.label}» (${failed.file}), ${seconds} с`);
  process.exit(1);
}

console.log(`\n✓ Миграции применились, изоляция подтверждена, все сценарии прошли. ${seconds} с`);
