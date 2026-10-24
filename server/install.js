// Installs db/ into the schema named in .env (`npm run db:install`; `npm start` runs it first as well).
// Order: schema/*.sql, packages/*.pks, packages/*.pkb, seed/*.sql, each folder sorted by name. Tables and
// config defaults are created only when missing, packages are replaced, and everything compiles NATIVE at
// optimisation level 3 (Section 13.1). Drop a new file into one of those folders and it is picked up.
import path from 'node:path';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import oracledb from 'oracledb';
import { dbSettings } from './oracle.js';

const DB_DIR = fileURLToPath(new URL('../db/', import.meta.url));
const STEPS = [['schema', '.sql'], ['packages', '.pks'], ['packages', '.pkb'], ['seed', '.sql']];

// Statements end with a line holding only "/", as in SQL*Plus, so the files also run there unchanged.
// SQL statements carry no trailing semicolon; PL/SQL keeps its final "end;".
export function statements(text) {
  return text
    .split(/^[ \t]*\/[ \t]*$/m)
    .map(s => s.trim())
    .filter(s => s.replace(/^[ \t]*--.*$/gm, '').trim());
}

// NATIVE needs the database container's /dev/shm mounted with exec; without it every unit fails with
// ORA-06590 (see plcraft-db-session-linux.sh). Probe first so a missing mount means slower, not broken.
async function nativeWorks(conn) {
  await conn.execute('alter session set plsql_code_type = native');
  await conn.execute('create or replace procedure pc_native_probe is begin null; end;');
  const { rows } = await conn.execute(`select count(*) from user_errors where name = 'PC_NATIVE_PROBE'`);
  await conn.execute('drop procedure pc_native_probe');
  return rows[0][0] === 0;
}

// Runs every file. Returns whether it compiled NATIVE, and the compile errors left in USER_ERRORS.
export async function install(conn) {
  const native = await nativeWorks(conn);
  await conn.execute(`alter session set plsql_code_type = ${native ? 'native' : 'interpreted'}`);
  await conn.execute('alter session set plsql_optimize_level = 3');
  for (const [dir, ext] of STEPS) {
    for (const file of readdirSync(path.join(DB_DIR, dir)).filter(f => f.endsWith(ext)).sort()) {
      for (const sql of statements(readFileSync(path.join(DB_DIR, dir, file), 'utf8'))) {
        try {
          await conn.execute(sql); // a package with compile errors still "succeeds"; see below
        } catch (err) {
          err.message = `db/${dir}/${file}: ${err.message}`;
          throw err;
        }
      }
      await conn.commit();
    }
  }
  // ORA-06590 is the missing exec mount, already reported through `native`.
  const { rows } = await conn.execute(
    `select type, name, line, position, text from user_errors
      where attribute = 'ERROR' and text not like 'ORA-06590%' order by name, type, sequence`,
  );
  const errors = rows.map(([type, name, line, col, text]) => `${type} ${name} line ${line}, column ${col}: ${text.trim()}`);
  return { native, errors };
}

export const INTERPRETED_WARNING =
  'Compiled INTERPRETED: the database cannot run native code (ORA-06590, its container mounts /dev/shm noexec). ' +
  'The game works but misses the frame budget. Restart the database with the updated plcraft-db-session-linux.sh.';

export async function installFromEnv() {
  const conn = await oracledb.getConnection(dbSettings());
  try {
    return await install(conn);
  } finally {
    await conn.close();
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (!dbSettings()) {
    console.error('Set PLCRAFT_DB_USER, PLCRAFT_DB_PASSWORD and PLCRAFT_DB_CONNECT_STRING in .env (see .env.example).');
    process.exit(1);
  }
  const { native, errors } = await installFromEnv();
  if (!native) console.warn(INTERPRETED_WARNING);
  if (errors.length) {
    console.error(`Installed, but these did not compile:\n${errors.join('\n')}`);
    process.exitCode = 1;
  } else {
    console.log(`Installed db/ into ${process.env.PLCRAFT_DB_USER}@${process.env.PLCRAFT_DB_CONNECT_STRING}.`);
  }
}
