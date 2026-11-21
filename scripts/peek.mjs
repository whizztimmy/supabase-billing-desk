// Loads the database into PGlite and runs one query, for a quick look at what
// the console will show without needing a Supabase project.
//   node scripts/peek.mjs "select * from ticket_queue"

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const db = new PGlite();
await db.exec(`create role anon nologin; create role authenticated nologin;`);
const dir = path.join(root, 'supabase/migrations');
for (const f of fs.readdirSync(dir).filter((f) => f.endsWith('.sql') && !f.startsWith('0000_')).sort()) {
  await db.exec(fs.readFileSync(path.join(dir, f), 'utf8'));
}
await db.exec(fs.readFileSync(path.join(root, 'supabase/seed.sql'), 'utf8'));

const sql = process.argv[2];
if (!sql) { console.error('Pass a query in quotes.'); process.exit(1); }
try {
  const started = Date.now();
  const { rows } = await db.query(sql);
  for (const r of rows) {
    const keys = Object.keys(r);
    if (keys.length === 1) console.log(typeof r[keys[0]] === 'object' ? JSON.stringify(r[keys[0]], null, 1) : r[keys[0]]);
    else console.log(keys.map((k) => `${k}=${typeof r[k] === 'object' && r[k] !== null && !(r[k] instanceof Date) ? JSON.stringify(r[k]) : r[k] instanceof Date ? r[k].toISOString().slice(0, 16) : r[k]}`).join(' | '));
  }
  console.error(`(${rows.length} rows, ${Date.now() - started} ms)`);
} catch (e) {
  console.error(`Query failed: ${e.message}`);
  process.exit(1);
}
