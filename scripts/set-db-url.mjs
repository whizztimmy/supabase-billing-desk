#!/usr/bin/env node
// Prompts for the Supabase connection string and writes it into .env, so the
// value goes from your clipboard straight to the file without passing through
// the chat.
//
//   node scripts/set-db-url.mjs

import { createInterface } from 'node:readline/promises';
import { readFile, writeFile } from 'node:fs/promises';
import { stdin, stdout } from 'node:process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const envPath = join(dirname(dirname(fileURLToPath(import.meta.url))), '.env');

/** The mistakes that cost the most time, caught before anything tries to connect. */
function problemsWith(url) {
  const problems = [];
  if (!/^postgres(ql)?:\/\//.test(url)) problems.push('does not start with postgresql://');
  if (url.includes('your-project-ref')) {
    problems.push('still contains the placeholder "your-project-ref"');
  }
  if (url.includes('[YOUR-PASSWORD]')) {
    problems.push('still contains the literal [YOUR-PASSWORD]: paste your real password over it');
  }
  if (url.includes(':6543/')) {
    problems.push('uses port 6543 (transaction pooler); the migrations need the session pooler on 5432');
  }
  if (!url.includes('@')) problems.push('has no @ separating the password from the host');
  return problems;
}

const mask = (url) => url.replace(/(:\/\/[^:]*:)[^@]*(@)/, '$1********$2');

async function main() {
  const rl = createInterface({ input: stdin, output: stdout });

  // After a password rotation only the password changed, so offer to keep the
  // host and user we already have: the parts that are easy to get wrong.
  const before = await readFile(envPath, 'utf8');
  const currentLine = before.split(/\r?\n/).find((l) => /^\s*DATABASE_URL\s*=/.test(l));
  const current = currentLine ? currentLine.replace(/^\s*DATABASE_URL\s*=/, '').trim() : '';
  const reusable =
    /^postgres(ql)?:\/\/[^:]+:[^@]*@.+$/.test(current) && !current.includes('your-project-ref');

  if (reusable) {
    console.log(`\nCurrent: ${mask(current)}`);
    console.log('Paste the NEW PASSWORD alone and the rest of the line is kept,');
    console.log('or paste a whole postgresql://... string to replace it outright.\n');
  } else {
    console.log('\nPaste the Supabase connection string (Session pooler, port 5432).');
    console.log('Right-click pastes in this window. Then press Enter.\n');
  }

  const answer = await rl.question(reusable ? 'New password (or full URL): ' : 'DATABASE_URL: ');
  rl.close();

  let url = answer.trim().replace(/^["']|["']$/g, '');

  // A bare password: splice it in, percent-encoding whatever would break the URL.
  if (url && reusable && !/^postgres(ql)?:\/\//.test(url)) {
    const encoded = encodeURIComponent(url);
    if (encoded !== url) console.log('(percent-encoded the special characters in it)');
    url = current.replace(/^(postgres(?:ql)?:\/\/[^:]+:)[^@]*(@)/, `$1${encoded}$2`);
  }

  if (!url) {
    console.error('\nNothing was pasted: the clipboard may be empty. Try copying it again.');
    process.exitCode = 1;
    return;
  }

  const problems = problemsWith(url);
  if (problems.length > 0) {
    console.error('\nThat string looks wrong:');
    for (const problem of problems) console.error(`  - ${problem}`);
    console.error('Nothing was written. Fix it and run this again.');
    process.exitCode = 1;
    return;
  }

  // Replace the DATABASE_URL line in place, leaving every other line untouched.
  const existing = await readFile(envPath, 'utf8');
  const lines = existing.split(/\r?\n/);
  let replaced = false;
  const updated = lines.map((line) => {
    if (/^\s*DATABASE_URL\s*=/.test(line)) {
      replaced = true;
      return `DATABASE_URL=${url}`;
    }
    return line;
  });
  if (!replaced) updated.push(`DATABASE_URL=${url}`);

  await writeFile(envPath, updated.join('\n').replace(/\n+$/, '') + '\n', 'utf8');

  console.log('\nWritten to .env:');
  console.log(`  ${mask(url)}`);
  console.log('\nTell Claude it is done.\n');
}

main().catch((error) => {
  console.error(`\n${error.message}`);
  process.exitCode = 1;
});
