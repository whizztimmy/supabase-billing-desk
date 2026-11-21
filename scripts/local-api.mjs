// A stand-in for Supabase's REST API, for development without a project.
//
// It loads the migrations and the seed into PGlite (Postgres inside this Node
// process) and answers the small part of the PostgREST protocol the console
// uses: reading a table or view with filters, and calling a function. The Vite
// dev server mounts it at /rest/v1, so supabase-js talks to it exactly as it
// talks to a real project, and `npm run dev` works offline.
//
// Every query runs as the `anon` role, so row level security and grants apply
// here the same way they do in production. It is a development tool only: it
// is not part of the deployed site.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const IDENT = /^[a-z_][a-z0-9_]*$/;
const NUMERIC = 1700;
const DATE = 1082;

async function loadDatabase() {
  const db = new PGlite();
  await db.exec('create role anon nologin; create role authenticated nologin;');
  const dir = path.join(root, 'supabase/migrations');
  for (const f of fs.readdirSync(dir).filter((f) => f.endsWith('.sql') && !f.startsWith('0000_')).sort()) {
    await db.exec(fs.readFileSync(path.join(dir, f), 'utf8'));
  }
  await db.exec(fs.readFileSync(path.join(root, 'supabase/seed.sql'), 'utf8'));
  // Bring the seed's dates up to today, as the nightly job does in production.
  await db.exec('select advance_demo_clock()');
  await db.exec('set role anon');
  return db;
}

// PostgREST sends numerics as JSON numbers and dates as YYYY-MM-DD.
function shape(result) {
  const numeric = result.fields.filter((f) => f.dataTypeID === NUMERIC).map((f) => f.name);
  const dates = result.fields.filter((f) => f.dataTypeID === DATE).map((f) => f.name);
  return result.rows.map((row) => {
    for (const k of numeric) if (row[k] !== null) row[k] = Number(row[k]);
    for (const k of dates) if (row[k] instanceof Date) row[k] = row[k].toISOString().slice(0, 10);
    return row;
  });
}

// col=eq.value, col=in.(a,b), col=is.null and so on, as supabase-js writes them.
function whereClause(params) {
  const clauses = [];
  const values = [];
  const ops = { eq: '=', neq: '<>', gt: '>', gte: '>=', lt: '<', lte: '<=' };
  for (const [column, raw] of params) {
    if (['select', 'order', 'limit', 'offset'].includes(column)) continue;
    if (!IDENT.test(column)) throw new Error(`Unsupported filter column: ${column}`);
    const dot = raw.indexOf('.');
    const op = raw.slice(0, dot);
    const value = raw.slice(dot + 1);
    if (op in ops) {
      values.push(value);
      clauses.push(`${column}::text ${ops[op]} $${values.length}`);
    } else if (op === 'is' && ['null', 'true', 'false'].includes(value)) {
      clauses.push(`${column} is ${value}`);
    } else if (op === 'in') {
      const items = value.replace(/^\(|\)$/g, '').split(',').map((v) => v.replace(/^"|"$/g, ''));
      values.push(items);
      clauses.push(`${column}::text = any($${values.length}::text[])`);
    } else {
      throw new Error(`Unsupported filter: ${column}=${raw}`);
    }
  }
  return { sql: clauses.length ? ` where ${clauses.join(' and ')}` : '', values };
}

function orderClause(order) {
  if (!order) return '';
  const parts = order.split(',').map((part) => {
    const [column, direction] = part.split('.');
    if (!IDENT.test(column)) throw new Error(`Unsupported order column: ${column}`);
    return `${column} ${direction === 'desc' ? 'desc' : 'asc'}`;
  });
  return ` order by ${parts.join(', ')}`;
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const text = Buffer.concat(chunks).toString('utf8');
  return text ? JSON.parse(text) : {};
}

export function createLocalApi() {
  const ready = loadDatabase();

  return async function localApi(req, res, next) {
    const url = new URL(req.url, 'http://localhost');
    const match = url.pathname.match(/^\/rest\/v1\/(rpc\/)?([a-z_][a-z0-9_]*)$/);
    if (!match) return next();

    const send = (status, body) => {
      res.statusCode = status;
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      res.end(JSON.stringify(body));
    };

    try {
      const db = await ready;
      const [, isRpc, name] = match;
      const wantsObject = (req.headers.accept ?? '').includes('vnd.pgrst.object');
      let rows;

      if (isRpc) {
        const args = await readBody(req);
        const keys = Object.keys(args);
        if (!keys.every((k) => IDENT.test(k))) throw new Error('Unsupported argument name');
        const values = keys.map((k) => (args[k] !== null && typeof args[k] === 'object' ? JSON.stringify(args[k]) : args[k]));
        const call = `${name}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')})`;
        const result = await db.query(`select * from ${call}`, values);
        rows = shape(result);
        // A function returning one value comes back as that value, not a row.
        if (result.fields.length === 1 && result.fields[0].name === name) {
          return send(200, rows.length === 1 ? rows[0][name] : rows.map((r) => r[name]));
        }
      } else {
        const where = whereClause(url.searchParams);
        const limit = Number(url.searchParams.get('limit'));
        const sql = `select * from ${name}${where.sql}${orderClause(url.searchParams.get('order'))}`
          + (Number.isInteger(limit) && limit > 0 ? ` limit ${limit}` : '');
        rows = shape(await db.query(sql, where.values));
      }

      if (wantsObject) {
        if (rows.length !== 1) return send(406, { message: `Expected one row, found ${rows.length}`, code: 'PGRST116' });
        return send(200, rows[0]);
      }
      return send(200, rows);
    } catch (error) {
      return send(400, { message: error.message, code: error.code ?? 'LOCAL' });
    }
  };
}
