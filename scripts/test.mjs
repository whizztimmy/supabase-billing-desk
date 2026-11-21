// Runs the whole database (migrations, seed, tests) inside PGlite, a build of
// Postgres that runs in this Node process. No network and no Supabase project
// needed, so the billing rules can be tested anywhere, including in CI.
//
// A test is a call to expect_eq(name, got, want) or expect_true(name, condition)
// inside tests/*.sql. Each call writes one row to test_results; this script
// prints them and exits 1 if any failed. `npm test -- --verbose` also prints
// the passing rows' values.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const verbose = process.argv.includes('--verbose');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const sqlFiles = (dir) =>
  fs.readdirSync(path.join(root, dir)).filter((f) => f.endsWith('.sql')).sort().map((f) => `${dir}/${f}`);

const db = new PGlite();

async function run(file) {
  try {
    await db.exec(read(file));
  } catch (e) {
    console.error(`\n${file} failed: ${e.message}`);
    if (e.where) console.error(e.where);
    process.exit(1);
  }
}

// Supabase creates these roles for every project. PGlite starts without them.
await db.exec(`
  do $$ begin
    if not exists (select from pg_roles where rolname = 'anon') then create role anon nologin; end if;
    if not exists (select from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  end $$;
`);

const started = Date.now();
for (const f of sqlFiles('supabase/migrations').filter((f) => !f.includes('0000_'))) await run(f);
await run('supabase/seed.sql');

await db.exec(`
  create table test_results (id serial primary key, file text, name text, ok boolean, got text, want text);
  create function expect_eq(name text, got anyelement, want anyelement) returns void language plpgsql as $$
  begin
    insert into test_results (file, name, ok, got, want)
    values (current_setting('test.file', true), name, got is not distinct from want, got::text, want::text);
  end $$;
  create function expect_true(name text, got boolean) returns void language sql as $$
    select expect_eq(name, coalesce(got, false), true);
  $$;
`);

for (const f of sqlFiles('tests')) {
  await db.exec(`select set_config('test.file', '${path.basename(f)}', false)`);
  await run(f);
}

const { rows } = await db.query('select * from test_results order by id');
let file = '';
for (const r of rows) {
  if (r.file !== file) { file = r.file; console.log(`\n${file}`); }
  if (r.ok) console.log(`  ok    ${r.name}${verbose ? `  (${r.got})` : ''}`);
  else console.log(`  FAIL  ${r.name}\n          got:  ${r.got}\n          want: ${r.want}`);
}
const failed = rows.filter((r) => !r.ok).length;
console.log(`\n${rows.length - failed} passed, ${failed} failed, ${Date.now() - started} ms`);
process.exit(failed ? 1 : 0);
