import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import pg from 'pg';

const connectionString = process.env.DATABASE_URL;
if (!connectionString) throw new Error('Configura DATABASE_URL.');

const directory = new URL('../migrations/', import.meta.url);
const files = (await readdir(directory)).filter((name) => /^\d+_.+\.sql$/.test(name)).sort();
const client = new pg.Client({ connectionString, connectionTimeoutMillis: 5000 });
await client.connect();

try {
  await client.query("select pg_advisory_lock(hashtext('conecta2-schema-migrations'))");
  await client.query(`
    create table if not exists public.schema_migrations (
      name text primary key,
      checksum text not null,
      applied_at timestamptz not null default now()
    )
  `);
  for (const name of files) {
    const sql = (await readFile(new URL(name, directory), 'utf8')).replace(/\r\n/g, '\n');
    const checksum = createHash('sha256').update(sql).digest('hex');
    const { rows: [previous] } = await client.query(
      'select checksum from public.schema_migrations where name = $1', [name],
    );
    if (previous) {
      if (previous.checksum !== checksum) throw new Error(`La migración aplicada ${name} cambió.`);
      console.log(`Ya aplicada: ${name}`);
      continue;
    }

    await client.query('begin');
    try {
      await client.query(sql);
      await client.query('insert into public.schema_migrations (name, checksum) values ($1, $2)', [name, checksum]);
      await client.query('commit');
      console.log(`Aplicada: ${name}`);
    } catch (error) {
      await client.query('rollback');
      throw error;
    }
  }
} finally {
  await client.end();
}
