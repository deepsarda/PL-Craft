// Runs the PL/SQL tests in db/tests/ (`npm run db:test`), after installing db/ so they test what is in the
// files. Each block is one test, named by the comment line just above its code. A test fails by raising an
// error, and every test is rolled back, so tests leave no data behind. Section 15 plans utPLSQL; this runner
// stands in until it is installed on the database.
import path from 'node:path';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import oracledb from 'oracledb';
import { dbSettings } from './oracle.js';
import { INTERPRETED_WARNING, install, statements } from './install.js';

const TESTS_DIR = fileURLToPath(new URL('../db/tests/', import.meta.url));

export function testName(block) {
  const lines = block.split('\n');
  const code = lines.findIndex(line => line.trim() && !line.trim().startsWith('--'));
  const comments = lines.slice(0, code).filter(line => line.trim().startsWith('--'));
  return comments.at(-1)?.replace(/^\s*--\s*/, '') ?? lines[code]?.trim();
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (!dbSettings()) {
    console.error('Set PLCRAFT_DB_USER, PLCRAFT_DB_PASSWORD and PLCRAFT_DB_CONNECT_STRING in .env (see .env.example).');
    process.exit(1);
  }
  const conn = await oracledb.getConnection(dbSettings());
  try {
    const { native, errors } = await install(conn);
    if (!native) console.warn(`${INTERPRETED_WARNING}\n`);
    if (errors.length) {
      console.error(`These did not compile, so nothing was tested:\n${errors.join('\n')}`);
      process.exitCode = 1;
    } else {
      let failed = 0;
      for (const file of readdirSync(TESTS_DIR).filter(f => f.endsWith('.sql')).sort()) {
        for (const block of statements(readFileSync(path.join(TESTS_DIR, file), 'utf8'))) {
          const began = performance.now();
          try {
            await conn.execute(block);
            console.log(`ok   ${testName(block)} (${Math.round(performance.now() - began)} ms)`);
          } catch (err) {
            failed += 1;
            console.log(`FAIL ${testName(block)}\n     ${err.message.split('\n')[0]}`);
          } finally {
            await conn.rollback();
          }
        }
      }
      console.log(failed ? `\n${failed} failed.` : '\nAll passed.');
      process.exitCode = failed ? 1 : 0;
    }
  } finally {
    await conn.close();
  }
}
